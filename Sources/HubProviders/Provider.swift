import Foundation
import HubProcess

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex, antigravity, dsh
    public var id: Self { self }
    public var executableName: String { self == .antigravity ? "agy" : rawValue }
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .dsh: "DeepSeek Harness"
        }
    }
    public var installURL: URL {
        switch self {
        case .codex: URL(string: "https://developers.openai.com/codex/cli/")!
        case .antigravity: URL(string: "https://antigravity.google/docs/getting-started")!
        case .dsh: URL(string: "https://github.com/deepseek-ai/deepseek-harness/tree/master/apps/cli")!
        }
    }
    public var loginInstructions: String {
        switch self {
        case .codex: "在终端运行 codex login，选择 ChatGPT 账号登录，然后重新检测。"
        case .antigravity: "在终端运行 agy，按官方浏览器流程登录 Google 账号，然后重新检测。"
        case .dsh: "在此处保存 DeepSeek API key。使用此连接会从对应的 API 账户计费。"
        }
    }
}

public enum Capability: String, Sendable, Codable { case supported, unsupported, unknown }

public struct ProviderCapabilities: Sendable {
    public let structuredEvents: Capability = .supported
    public let persistentSession: Capability = .supported
    public let resumeSession: Capability = .supported
    public let inputDuringRun: Capability = .unsupported
    public let permissionBridge: Capability = .unsupported
    public let cancellation: Capability = .supported
    public let nativePause: Capability = .unsupported
    public let usageTokens: Capability = .supported
    public let costReporting: Capability = .unsupported
    public let quotaReporting: Capability = .unsupported
    public let modelDiscovery: Capability
    public let scopeEnforcement: Capability
}

public struct ProviderCommand: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let stdin: Data
    public let environment: [String:String]
    public var description: String { "\(executable.lastPathComponent) · \(arguments.count) arguments" }
    public var debugDescription: String { description }
}

public enum ProviderError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

public struct ProviderAdapter: Sendable {
    public let id: ProviderID
    private let key: @Sendable () throws -> String?
    private let stateDirectory: URL

    public init(_ id: ProviderID, stateDirectory: URL? = nil,
                deepSeekKey: @escaping @Sendable () throws -> String? = { try DeepSeekKeychain.read() }) {
        self.id = id
        self.key = deepSeekKey
        self.stateDirectory = stateDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agent Hub/Providers", isDirectory: true)
    }

    public var capabilities: ProviderCapabilities {
        ProviderCapabilities(modelDiscovery: id == .dsh ? .unsupported : .supported,
                             scopeEnforcement: id == .antigravity ? .unknown : .supported)
    }

    public func command(executable: URL, workspace: URL, prompt: String, model: String? = nil,
                        sessionID: String? = nil, readOnly: Bool = false) throws -> ProviderCommand {
        guard executable.isFileURL, workspace.isFileURL, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.message("需要有效的 CLI 路径、工作区和任务内容。")
        }
        if let sessionID {
            let bare = id == .dsh && sessionID.hasPrefix("session-") ? String(sessionID.dropFirst(8)) : sessionID
            guard UUID(uuidString: bare) != nil else { throw ProviderError.message("会话 ID 格式无效。") }
        }
        if let model, !Self.validModel(model) { throw ProviderError.message("模型标识格式无效。") }
        var env = Self.environment(for: executable)
        var arguments: [String]
        var input = Data(prompt.utf8)
        let sandbox = readOnly ? "read-only" : "workspace-write"
        switch id {
        case .codex:
            // Ignore endpoint/provider customization while keeping official login and session storage.
            arguments = ["exec", "--ignore-user-config", "--sandbox", sandbox, "-c", "approval_policy=\"never\"",
                         "-c", "model_provider=\"openai\"", "-c", "forced_login_method=\"chatgpt\""]
            if let sessionID { arguments += ["resume", sessionID] }
            arguments += ["--json", "--skip-git-repo-check"]
            if let model { arguments += ["--model", model] }
            arguments += ["-"]
        case .antigravity:
            guard !ProviderDiscovery.agyUsesAlternateBilling() else { throw ProviderError.message("请通过官方 CLI 选择 Google 账号通道。") }
            let overrides = try Self.antigravityOverrides(workspace: workspace, readOnly: readOnly)
            arguments = ["--input-format", "stream-json", "--output-format", "stream-json",
                         "--sandbox", "--mode", readOnly ? "plan" : "accept-edits",
                         "--settings", overrides, "--disable-slash-commands"]
            if let model { arguments += ["--model", model] }
            if let sessionID { arguments += ["--conversation", sessionID] }
            input = try JSONSerialization.data(withJSONObject: ["event":"user","message":["content":prompt]])
            input.append(0x0A)
        case .dsh:
            guard let secret = try key(), !secret.isEmpty else { throw ProviderError.message("请先在连接设置中保存 DeepSeek API key。") }
            let selected = model ?? "deepseek-flash"
            guard Self.deepSeekModels.contains(selected) else { throw ProviderError.message("此版本的 DSH 未列出所选模型。") }
            let home = stateDirectory.appendingPathComponent("DSH-\(sandbox)-\(selected)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let patch = home.appendingPathComponent("agent-hub.patch.yml")
            let policy = Data("""
            - id: credentials
              disabled: true
            - id: authorization
              disabled: true
            - id: deepseek-account
              disabled: true
            - id: llm-deepseek-account
              disabled: true
            - id: agent-default-model
              config:
                provider: deepseek-official
                model: \(selected)
            - id: llm-deepseek
              config:
                baseURL: https://api.deepseek.com/anthropic
            - id: sandbox-policy
              config:
                mode: \(sandbox)
            - id: session-telemetry-otel
              disabled: true

            """.utf8)
            try policy.write(to: patch, options: .atomic)
            env["DSH_HOME"] = home.path
            env["DEEPSEEK_API_KEY"] = secret
            env["DEEPSEEK_BASE_URL"] = "https://api.deepseek.com/anthropic"
            env["DSH_PERMISSION_MODE"] = sandbox
            arguments = ["--profile","headless","--patch",patch.path,"--json"]
            if let sessionID { arguments += ["--session-id",sessionID] }
            arguments += ["-"]
        }
        return ProviderCommand(executable: executable, arguments: arguments, workingDirectory: workspace,
                               stdin: input, environment: env)
    }

    private static func antigravityOverrides(workspace: URL, readOnly: Bool) throws -> String {
        let saved = ProviderDiscovery.agySettings
        let permissions = saved["permissions"] as? [String:Any]
        var denied = Set(permissions?["deny"] as? [String] ?? [])
        denied.insert("mcp(*)")
        if readOnly {
            denied.formUnion(["command(*)", "write_file(*)", "execute_url(*)", "download_url(*)"])
        }
        let captured = saved["toolPermission"] as? String
        let policy = captured == "strict" ? "strict" : (readOnly ? "request-review" : "proceed-in-sandbox")
        let settings: [String:Any] = [
            "modelProvider": "", "toolPermission": policy, "trustedWorkspaces": [workspace.path],
            "permissions": ["allow": [String](), "ask": permissions?["ask"] as? [String] ?? [], "deny": denied.sorted()]
        ]
        let json = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        return String(decoding: json, as: UTF8.self)
    }

    static let deepSeekModels = ["deepseek-flash", "deepseek-v4-pro"]
    static func validModel(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,126}$"#, options: .regularExpression) != nil
    }
    static func environment(for executable: URL) -> [String:String] {
        var env = ProcessEnvironment.clean()
        // GUI processes may lack PATH entries necessary for a CLI's /usr/bin/env node shebang.
        let bins = [executable.deletingLastPathComponent().path] + ProviderDiscovery.searchDirectories.map(\.path)
        let existing = (env["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":")
        var seen = Set<String>()
        env["PATH"] = (bins + existing).filter { $0.hasPrefix("/") && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }
}
