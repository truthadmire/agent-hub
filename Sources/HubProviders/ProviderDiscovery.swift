import Foundation
import HubProcess

public enum ProviderAuth: String, Codable, Sendable {
    case unknown, signedOut, subscription, apiKeySaved, externalAPIKey
}
public struct ProviderConnection: Sendable, Identifiable {
    public let id: ProviderID
    public let executable: URL?
    public let version: String?
    public let auth: ProviderAuth
    public let compatible: Bool
    public let detail: String
    public let models: [String]
    public let checkedAt: Date
    public var configured: Bool { compatible && (auth == .subscription || auth == .apiKeySaved) }
}
public struct ProviderProbeError: LocalizedError {
    public let kind: ProviderFailureKind
    public let description: String
    public var errorDescription: String? { description }
}

public enum ProviderDiscovery {
    static var searchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userBins = [".local/bin", ".npm-global/bin", ".local/share/pnpm", "Library/pnpm", ".volta/bin",
                        ".bun/bin",".asdf/shims",".local/share/mise/shims"].map { home.appendingPathComponent($0) }
        var nodeBins: [URL] = []
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let installs = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            nodeBins = installs.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options:.numeric) == .orderedDescending }
                .prefix(8).map { $0.appendingPathComponent("bin") }
        }
        return ["/opt/homebrew/bin","/usr/local/bin"].map { URL(fileURLWithPath:$0) } + userBins + nodeBins
    }

    public static func executable(_ id: ProviderID, override: URL? = nil) -> URL? {
        let check: (URL) -> Bool = { path in
            var directory: ObjCBool = false
            return path.isFileURL && FileManager.default.fileExists(atPath: path.path, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path.path)
        }
        if let override { return check(override) ? override : nil }
        var paths = searchDirectories.map { $0.appendingPathComponent(id.executableName) }
        let env = ProcessEnvironment.clean()
        paths += (env["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath:String($0)).appendingPathComponent(id.executableName)
        }
        if id == .codex {
            paths += ["/Applications/Codex.app/Contents/Resources/codex",
                      "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"].map { URL(fileURLWithPath:$0) }
        }
        return paths.first(where:check)
    }

    private struct Output {
        var ok: Bool
        var stdout: String
        var stderr: String
        var both: String { stdout + "\n" + stderr }
    }
    private static func run(_ path: URL, _ args: [String], cwd: URL, env: [String:String], timeout: TimeInterval = 8) async throws -> Output {
        let request = ProcessRequest(executable:path, arguments:args, workingDirectory:cwd, environment:env, timeout:timeout, captureLimit:131072)
        let result = try await ProcessRunner.run(request)
        if result.timedOut { throw ProviderProbeError(kind:.network,description:"CLI 检测超时。") }
        return Output(ok:result.exitCode == 0, stdout:String(decoding:result.stdout, as:UTF8.self),
                      stderr:String(decoding:result.stderr, as:UTF8.self))
    }

    public static func detect(_ id: ProviderID, override: URL? = nil) async -> ProviderConnection {
        let path = executable(id, override:override)
        var version: String?
        var compatible = false
        func connection(_ auth: ProviderAuth, _ detail: String, _ models: [String] = []) -> ProviderConnection {
            ProviderConnection(id:id, executable:path, version:version, auth:auth, compatible:compatible,
                               detail:detail, models:models, checkedAt:Date())
        }
        guard let path else { return connection(.unknown, override == nil ? "未找到可执行文件。" : "手选 CLI 路径不存在或不可执行。") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agenthub-check-\(UUID().uuidString)", isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:temp, withIntermediateDirectories:false, attributes:[.posixPermissions:0o700])
            defer { try? FileManager.default.removeItem(at:temp) }
            var env = ProviderAdapter.environment(for:path)
            // Some DSH versions initialize their profile even on --help.
            if id == .dsh { env["DSH_HOME"] = temp.appendingPathComponent("dsh").path }
            let report = try await run(path, ["--version"], cwd:temp, env:env)
            version = report.ok ? semanticVersion(report.stdout) : nil
            guard let version else { return connection(.unknown, "未识别 CLI 版本，请检查所选程序。") }
            let args = id == .codex ? ["exec","--help"] : id == .dsh ? ["--profile","headless","--help"] : ["--help"]
            let help = try await run(path, args, cwd:temp, env:env)
            let flags: [String]
            switch id {
            case .codex: flags = ["--json","--sandbox","--ignore-user-config","resume"]
            case .antigravity: flags = ["--output-format","--input-format","--conversation","--sandbox","--disable-slash-commands"]
            case .dsh: flags = ["--json","--session-id"]
            }
            compatible = help.ok && flags.allSatisfy { help.both.contains($0) }
                && (id != .dsh || version == "0.2.0-rc.2")
            guard compatible else { return connection(.unknown, "版本或参数与已验证协议不兼容。") }
            switch id {
            case .codex:
                let status = try await run(path, ["login","status"], cwd:temp, env:env)
                let statusText = status.both.lowercased()
                if status.ok && statusText.contains("chatgpt") {
                    return connection(.subscription, "CLI 报告已通过 ChatGPT 账号登录。模型来自本机 CLI 缓存。", codexModels())
                }
                if statusText.contains("api key") || statusText.contains("api_key") {
                    return connection(.externalAPIKey, "Codex 正使用 API key，请切换到 ChatGPT 登录。")
                }
                if statusText.contains("not logged in") || statusText.contains("not signed in") {
                    return connection(.signedOut, "请通过官方 Codex CLI 登录。")
                }
                return connection(.unknown, "无法从官方 CLI 核实账号登录状态。")
            case .antigravity:
                if agyUsesAlternateBilling() { return connection(.externalAPIKey, "Antigravity 配置了其他计费通道，请在官方 CLI 切换账号。") }
                let list = try await run(path, ["models"], cwd:temp, env:env, timeout:15)
                let models = list.stdout.components(separatedBy:.newlines).compactMap { line -> String? in
                    let fields = line.split(separator:"\t",maxSplits:1)
                    guard fields.count == 2, ProviderAdapter.validModel(String(fields[0])) else { return nil }
                    return String(fields[0])
                }
                if list.ok && !models.isEmpty {
                    return connection(.subscription, "官方账号通道已返回模型目录。具体套餐和余额未知。", models)
                }
                let kind = ProviderStreamDecoder.classify(list.both)
                return connection(kind == .authentication ? .signedOut : .unknown,
                                  kind == .authentication ? "请通过官方 Antigravity CLI 登录。" : "CLI 未能列出模型，请检查登录和网络。")
            case .dsh:
                let available = try DeepSeekKeychain.hasKey()
                return connection(available ? .apiKeySaved : .signedOut, available ? "钥匙串中已有 key。可运行短请求验证。" : "需要保存 DeepSeek API key。",
                                  ProviderAdapter.deepSeekModels)
            }
        } catch let error as ProviderProbeError { return connection(.unknown, error.description) }
        catch { return connection(.unknown, "无法完成本机检测，请检查可执行程序、钥匙串和 CLI 权限。") }
    }

    static var agySettings: [String:Any] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        return jsonFile(url) ?? [:]
    }
    static func agyUsesAlternateBilling() -> Bool {
        let settings = agySettings
        let selected = (settings["modelProvider"] as? String)?.lowercased()
        let auth = (settings["auth"] as? [String:Any])?["type"] as? String
        return selected == "gemini" || ["gemini-api-key","agent-platform","oauth-business"].contains(auth ?? "")
    }

    private static func jsonFile(_ url: URL) -> [String:Any]? {
        guard let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size < 16 * 1024 * 1024,
              let data = try? Data(contentsOf:url), let json = try? JSONSerialization.jsonObject(with:data) else { return nil }
        return json as? [String:Any]
    }
    private static func codexModels() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        return ((jsonFile(home)?["models"] as? [[String:Any]]) ?? []).compactMap {
            guard let name = $0["slug"] as? String, $0["visibility"] as? String == "list", ProviderAdapter.validModel(name) else { return nil }
            return name
        }
    }
    private static func semanticVersion(_ input: String) -> String? {
        let text = input.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let match = text.range(of:#"(?m)^(?:codex-cli |agy |dsh )?([0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?)$"#,options:.regularExpression) else { return nil }
        return text[match].split(separator:" ").last.map(String.init)
    }

    /// This method makes a real provider call. Only wire it to an explicitly confirmed user action.
    public static func testConnection(_ id: ProviderID, executable: URL, model: String? = nil) async throws -> String {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agenthub-connection-\(UUID().uuidString)", isDirectory:true)
        try FileManager.default.createDirectory(at:temp, withIntermediateDirectories:false, attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:temp) }
        let cmd: ProviderCommand
        do {
            cmd = try ProviderAdapter(id).command(executable:executable,workspace:temp,
                     prompt:"Reply with exactly HUB_OK. Do not use any tools.",model:model,readOnly:true)
        } catch { throw ProviderProbeError(kind:.authentication,description:error.localizedDescription) }
        let run = try await ProcessRunner.run(ProcessRequest(executable:cmd.executable,arguments:cmd.arguments,
                workingDirectory:cmd.workingDirectory,environment:cmd.environment,stdin:cmd.stdin,timeout:30,captureLimit:1024 * 1024))
        if run.cancelled { throw ProviderProbeError(kind:.cancelled,description:"短请求已取消。") }
        if run.timedOut { throw ProviderProbeError(kind:.network,description:"短请求在 30 秒后超时。") }
        if run.outputDrainIncomplete || run.stdoutTruncated || run.stderrTruncated { throw ProviderProbeError(kind:.protocolError,description:"短请求输出超过限制。") }
        var parser = ProviderStreamDecoder(id,sensitiveValues:[cmd.environment["DEEPSEEK_API_KEY"]].compactMap { $0 })
        let events = parser.feed(run.stdout) + parser.feed(run.stderr,stderr:true) + parser.finish(exitCode:run.exitCode ?? -1)
        guard parser.succeeded else {
            let error = events.first { $0.failure != nil }
            throw ProviderProbeError(kind:parser.failure ?? .execution,description:error?.text ?? "CLI 未完成短请求。")
        }
        guard parser.finalText.trimmingCharacters(in:.whitespacesAndNewlines) == "HUB_OK" else {
            throw ProviderProbeError(kind:.protocolError,description:"CLI 已完成，但回答与短请求的预期值不一致。")
        }
        return "CLI 已完成短请求，回答校验通过。"
    }
}
