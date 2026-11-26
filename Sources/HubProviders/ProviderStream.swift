import Foundation

public enum ProviderFailureKind: String, Sendable, Codable {
    case authentication, quota, network, permission, protocolError, incompatible, execution, cancelled, waiting
}

public struct ProviderEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case session, text, tool, file, usage, permission, diagnostic, failure, completed }
    public let kind: Kind
    public let text: String
    public let itemID: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let failure: ProviderFailureKind?
    public internal(set) var rawType: String? = nil
    init(_ kind: Kind, _ text: String, id: String? = nil, input: Int? = nil, output: Int? = nil,
         failure: ProviderFailureKind? = nil) {
        self.kind = kind
        self.text = text
        self.itemID = id
        self.inputTokens = input
        self.outputTokens = output
        self.failure = failure
    }
}

/// Chunks remain bytes until the full NDJSON record is available. Each stream has its own budget.
private struct Lines: Sendable {
    var pending = Data()
    var skipping = false
    enum Frame { case line(Data), oversized }
    mutating func append(_ data: Data, limit: Int) -> [Frame] {
        var frames: [Frame] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data[index...].firstIndex(of: 10) ?? data.endIndex
            if !skipping {
                if end - index > limit - pending.count {
                    pending.removeAll()
                    skipping = true
                    frames.append(.oversized)
                } else { pending.append(contentsOf: data[index..<end]) }
            }
            guard end < data.endIndex else { break }
            if !skipping && !pending.isEmpty { frames.append(.line(pending)) }
            pending.removeAll()
            skipping = false
            index = data.index(after: end)
        }
        return frames
    }
}

public struct ProviderStreamDecoder: Sendable {
    let id: ProviderID
    let limit: Int
    let sensitiveValues: [String]
    private var output = Lines(), errors = Lines()
    private var terminal = false, finished = false
    private var lastMessageID: String?
    private var stepText = "", stepID = "step-0"
    private var dshTurnReason: String?
    private var dshUsage: [String:[Int]] = [:]
    private var dshUsageIncomplete = false
    private var openDSHSteps = Set<String>()
    private var lastUsage: [Int?]?
    private var lastStderr = ""
    public private(set) var sessionID: String?
    public private(set) var finalText = ""
    public private(set) var failure: ProviderFailureKind?
    public private(set) var succeeded = false

    public init(_ id: ProviderID, sensitiveValues: [String] = [], maxLineBytes: Int = 1024 * 1024) {
        self.id = id
        self.limit = max(16, maxLineBytes)
        self.sensitiveValues = sensitiveValues.filter { !$0.isEmpty }
    }

    public mutating func feed(_ bytes: Data, stderr: Bool = false) -> [ProviderEvent] {
        guard !finished else { return [] }
        let frames = stderr ? errors.append(bytes, limit: limit) : output.append(bytes, limit: limit)
        return frames.flatMap { frame -> [ProviderEvent] in
            switch frame {
            case .oversized:
                return stderr ? [ProviderEvent(.diagnostic, "已截断超长的 CLI 诊断行。")] : fail(.protocolError, "CLI 事件超过单行大小上限。")
            case .line(let data):
                return parse(data, stderr: stderr)
            }
        }
    }

    public mutating func finish(exitCode: Int32) -> [ProviderEvent] {
        guard !finished else { return [] }
        var result = feed(Data([10])) + feed(Data([10]), stderr: true)
        finished = true
        if id == .dsh { result += dshUsageSnapshot() }
        if failure != nil { return result }
        if exitCode != 0 {
            result += fail(Self.classify(lastStderr), lastStderr.isEmpty ? "CLI 退出 (\(exitCode))。" : lastStderr)
        } else if !terminal {
            result += fail(.protocolError, "CLI 已退出，但缺少成功终止事件。")
        } else {
            succeeded = true
            result.append(ProviderEvent(.completed, "CLI 已完成本轮。"))
        }
        return result
    }

    private mutating func parse(_ data: Data, stderr: Bool) -> [ProviderEvent] {
        guard let line = String(data: data, encoding: .utf8) else {
            return stderr ? [] : fail(.protocolError, "CLI 事件含无效 UTF-8。")
        }
        let clean = Self.cleanANSI(line).trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return [] }
        if stderr {
            lastStderr = redact(String(clean.prefix(2048)))
            if id == .antigravity && Self.denied(clean) {
                return fail(.permission, lastStderr)
            }
            return [ProviderEvent(.diagnostic, lastStderr)]
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(clean.utf8))) as? [String:Any] else {
            return fail(.protocolError, "CLI 返回了无效 JSON。")
        }
        let field = id == .antigravity ? "event" : "type"
        guard let type = object[field] as? String, !type.isEmpty else { return fail(.protocolError, "CLI 事件缺少类型。") }
        let events: [ProviderEvent]
        switch id {
        case .codex: events = codex(type, object)
        case .antigravity: events = agy(type, object)
        case .dsh: events = dsh(type, object)
        }
        let source = redact(String(type.prefix(100)))
        return events.map { event in
            var tagged = event
            tagged.rawType = source
            return tagged
        }
    }

    private mutating func codex(_ type: String, _ object: [String:Any]) -> [ProviderEvent] {
        switch type {
        case "thread.started":
            return session(object["thread_id"])
        case "turn.started":
            return []
        case "turn.completed":
            terminal = true
            return usage(object["usage"], inputKey: "input_tokens", outputKey: "output_tokens")
        case "error", "turn.failed":
            let message = (object["error"] as? [String:Any])?["message"] as? String ?? object["message"] as? String ?? "Codex 执行失败。"
            return fail(Self.classify(message), message)
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String:Any], let itemType = item["type"] as? String,
                  let key = item["id"] as? String else { return fail(.protocolError, "Codex 项目事件缺少标识。") }
            switch itemType {
            case "agent_message":
                guard let text = item["text"] as? String else { return fail(.protocolError, "Codex 消息缺少文本。") }
                return message(text, key: key)
            case "file_change":
                return ((item["changes"] as? [[String:Any]]) ?? []).compactMap { change in
                    (change["path"] as? String).map { ProviderEvent(.file, redact($0), id:key) }
                }
            case "command_execution", "mcp_tool_call", "web_search", "collab_tool_call":
                let name = item["tool"] as? String ?? item["command"] as? String ?? itemType
                return [ProviderEvent(.tool, redact("\(name) · \(item["status"] as? String ?? type)"), id:key)]
            case "error":
                let reason = item["message"] as? String ?? "Codex 工具返回错误。"
                return Self.denied(reason) ? fail(.permission, reason) : [ProviderEvent(.diagnostic, redact(reason), id:key)]
            case "reasoning": return []
            default: return unknown(itemType)
            }
        default: return unknown(type)
        }
    }

    private mutating func agy(_ type: String, _ object: [String:Any]) -> [ProviderEvent] {
        switch type {
        case "init":
            return session(object["conversation_id"])
        case "step_update":
            guard let step = object[type] as? [String:Any], let category = step["step_type"] as? String,
                  let index = step["step_index"] as? Int else { return fail(.protocolError, "Antigravity 步骤缺少元数据。") }
            var events = session(step["conversation_id"])
            let key = "step-\(index)"
            if category == "agent_response", let delta = step["text_delta"] as? String {
                if key != stepID { stepID = key; stepText = "" }
                guard stepText.utf8.count <= limit - delta.utf8.count else { return events + fail(.protocolError, "流式回答超过大小上限。") }
                stepText += delta
                events += message(stepText, key:key)
            } else if category == "tool" {
                let info = step["tool_info"] as? [String:Any]
                let name = step["tool_name"] as? String ?? info?["name"] as? String ?? "tool"
                events.append(ProviderEvent(.tool, redact("\(name) · \(step["state"] as? String ?? "")"), id:key))
                let error = info?["error"] as? [String:Any]
                let reason = [error?["type"] as? String, error?["message"] as? String].compactMap { $0 }.joined(separator: " ")
                if Self.denied(reason) || Self.denied(info?["output"] as? String ?? "") {
                    events += fail(.permission, "\(name) 需要权限。\(reason)")
                } else if !reason.isEmpty {
                    events.append(ProviderEvent(.diagnostic, redact(reason), id:key))
                }
            }
            return events
        case "result":
            guard let payload = object[type] as? [String:Any], let status = payload["status"] as? String else {
                return fail(.protocolError, "Antigravity 结果缺少状态。")
            }
            var events = session(payload["conversation_id"])
            events += usage(payload["usage"], inputKey:"input_tokens", outputKey:"output_tokens")
            switch status {
            case "SUCCESS":
                guard let answer = payload["response"] as? String else { return events + fail(.protocolError, "Antigravity 结果缺少回答。") }
                terminal = true
                events += message(answer, key:lastMessageID ?? "response")
            case "CANCELED", "CANCELLED", "INTERRUPTED": events += fail(.cancelled, status)
            case "WAITING": events += fail(.waiting, "Antigravity 在等待输入。")
            default:
                let reason = payload["error"] as? String ?? status
                events += fail(Self.classify(reason), reason)
            }
            return events
        default: return unknown(type)
        }
    }

    private mutating func dsh(_ type: String, _ object: [String:Any]) -> [ProviderEvent] {
        switch type {
        case "session": return session(object["sessionId"])
        case "status":
            let phase = object["phase"] as? String
            let key = "step-\(object["turn"] as? Int ?? 0)-\(object["step"] as? Int ?? 0)"
            switch phase {
            case "step_start":
                openDSHSteps.insert(key)
                stepID = key
                stepText = ""
            case "step_end":
                openDSHSteps.remove(key)
                guard let bucket = object["usage"] as? [String:Any],
                      let input = token(bucket["inputTokens"]), let output = token(bucket["outputTokens"]) else {
                    dshUsageIncomplete = true
                    return []
                }
                if !dshUsageIncomplete { dshUsage[key] = [input,output] }
            case "turn_end":
                let reason = object["reason"] as? [String:Any]
                dshTurnReason = reason?["kind"] as? String
                if let kind = dshTurnReason, kind != "completed" {
                    let error = reason?["error"] as? [String:Any]
                    let detail = [error?["code"] as? String, error?["message"] as? String].compactMap { $0 }.joined(separator: " ")
                    return fail(kind == "aborted" ? .cancelled : Self.classify(detail), detail.isEmpty ? kind : detail)
                }
            default: break
            }
            return []
        case "text":
            guard let text = object["text"] as? String else { return fail(.protocolError, "DSH 文本缺少内容。") }
            guard stepText.utf8.count <= limit - text.utf8.count else { return fail(.protocolError, "DSH 步骤超过大小上限。") }
            stepText += text
            return message(stepText, key:stepID)
        case "thinking": return []
        case "tool_call", "tool_result":
            let name = object["tool"] as? String ?? type
            let key = object["callId"] as? String
            if type == "tool_result", object["status"] as? String == "error",
               let result = object["result"] as? String, Self.denied(result) { return fail(.permission, result) }
            return [ProviderEvent(.tool, redact("\(name) · \(object["status"] as? String ?? type)"), id:key)]
        case "final":
            guard let text = object["text"] as? String else { return fail(.protocolError, "DSH 结果缺少文本。") }
            let finalReason = (object["reason"] as? [String:Any])?["kind"] as? String ?? dshTurnReason
            guard finalReason == "completed" else { return fail(.protocolError, "DSH 未确认回合已完成。") }
            terminal = true
            var events = message(text, key:lastMessageID ?? "response")
            events += dshUsageSnapshot()
            return events
        case "error":
            let reason = object["message"] as? String ?? "DSH 报告执行错误。"
            return fail(Self.classify(reason), reason)
        default: return unknown(type)
        }
    }

    private static let ansiPattern = #"\u001B\[[0-?]*[ -/]*[@-~]"#
    private static func cleanANSI(_ value: String) -> String {
        value.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
    }

    private static func denied(_ value: String) -> Bool {
        let v = value.lowercased()
        return ["permission denied","permission_denied","permission required","requires approval","requires permission",
                "needs approval", "requires user approval", "soft-denied","in headless mode, cannot",
                "not allowed by", "denied by", "approval is required", "user denied", "request was denied",
                "not authorized to run", "cannot be approved in headless", "permission was denied"].contains(where: v.contains)
    }
    static func classify(_ reason: String) -> ProviderFailureKind {
        let v = reason.lowercased()
        if ["unauthenticated","authentication","unauthorized","not logged in","not signed in","please log in",
            "please sign in","invalid api key","invalid_api_key","invalid_credential","missing_credential","401"].contains(where: v.contains) { return .authentication }
        if ["quota","rate limit","rate_limit","resource_exhausted","429","insufficient balance","credit balance"].contains(where:v.contains) { return .quota }
        if denied(v) || v.contains("forbidden") || v.contains("403") { return .permission }
        if ["timeout","timed out","network","connection reset","connection refused","connection failed","dns","transport"].contains(where:v.contains) { return .network }
        if ["unknown option","unknown argument","unrecognized option","unexpected argument","unknown model","invalid model selection"].contains(where:v.contains) { return .incompatible }
        return .execution
    }
    private func redact(_ value: String) -> String {
        var value = value
        for secret in sensitiveValues { value = value.replacingOccurrences(of:secret, with:"[REDACTED]") }
        return value.replacingOccurrences(of: #"(?i)\b(?:sk-[A-Za-z0-9_-]{8,}|(?:Bearer\s+)[A-Za-z0-9_.\-+/=]{8,}|(?:[A-Z_]*(?:API_KEY|ACCESS_TOKEN|AUTH_TOKEN)|token)\s*[:=]\s*["']?[^\s"'&,}]+)"#, with:"[REDACTED]", options:.regularExpression)
    }
    private mutating func fail(_ kind: ProviderFailureKind, _ detail: String) -> [ProviderEvent] {
        guard failure == nil else { return [] }
        failure = kind
        return [ProviderEvent(kind == .permission ? .permission : .failure, redact(String(detail.prefix(2048))), failure:kind)]
    }
    private func unknown(_ type: String) -> [ProviderEvent] {
        [ProviderEvent(.diagnostic, "未识别的 CLI 事件 \(redact(String(type.prefix(100))))")]
    }
    private mutating func session(_ raw: Any?) -> [ProviderEvent] {
        guard let id = raw as? String, !id.isEmpty else { return [] }
        if let sessionID {
            return id == sessionID ? [] : fail(.protocolError, "CLI 在同一轮内更换了会话。")
        }
        guard id.utf8.count <= 256 else { return fail(.protocolError, "CLI 会话标识过长。") }
        sessionID = id
        return [ProviderEvent(.session, id)]
    }
    private mutating func message(_ text: String, key: String) -> [ProviderEvent] {
        let text = redact(text)
        guard text != finalText || key != lastMessageID else { return [] }
        lastMessageID = key
        finalText = text
        return [ProviderEvent(.text, text, id:key)]
    }
    private func token(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let value = Int(number.stringValue), value >= 0 else { return nil }
        return value
    }
    private mutating func dshUsageSnapshot() -> [ProviderEvent] {
        guard !dshUsageIncomplete, openDSHSteps.isEmpty, !dshUsage.isEmpty else { return [] }
        let input = boundedSum(dshUsage.values.map { $0[0] })
        let output = boundedSum(dshUsage.values.map { $0[1] })
        return usageSnapshot(input:input, output:output)
    }
    private func boundedSum(_ values: [Int]) -> Int? {
        var result = 0
        for value in values {
            let (next, overflow) = result.addingReportingOverflow(value)
            if overflow { return nil }
            result = next
        }
        return result
    }
    private mutating func usage(_ raw: Any?, inputKey: String, outputKey: String) -> [ProviderEvent] {
        guard let fields = raw as? [String:Any] else { return [] }
        return usageSnapshot(input:token(fields[inputKey]), output:token(fields[outputKey]))
    }
    private mutating func usageSnapshot(input: Int?, output: Int?) -> [ProviderEvent] {
        guard input != nil || output != nil, lastUsage != [input,output] else { return [] }
        lastUsage = [input,output]
        return [ProviderEvent(.usage, id == .antigravity ? "CLI 会话累计" : "CLI 本次执行", input:input, output:output)]
    }
}
