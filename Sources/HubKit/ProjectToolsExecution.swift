import Darwin
import Foundation
import HubProcess

public struct ProjectCheckResult: Sendable {
    public var command: ProjectCheckCommand
    public var directory: String
    public var status: VerificationState
    public var stdout = ""
    public var stderr = ""
    public var reason: String?
    public var exitCode: Int?
    public var toolVersion = ""
    public var startedAt = Date()
    public var finishedAt = Date()
}

/// A new writable HOME per invocation keeps unrelated tool configuration and model credentials
/// out of project commands. Absolute toolkit paths are readable, while source writes are
/// limited to the managed checkout. sandbox-exec failures are surfaced to the caller.
struct ProjectCommandContext {
    let executable: URL
    let arguments: [String]
    let directory: URL
    let scratch: URL
    let environment: [String: String]
    let profile: String

    static func prepare(argv: [String], root: URL, relativeDirectory: String,
                        environmentOverrides: [String: String] = [:], port: UInt16? = nil) async throws -> Self {
        var resolved = argv
        var swiftSDK: String?
        // Apple's /usr/bin/swift is an xcrun shim which writes a global cache.
        // Resolve its selected toolchain outside the project sandbox using fixed arguments.
        if argv.first == "swift", ProcessEnvironment.resolve("swift")?.path == "/usr/bin/swift" {
            func xcrun(_ arguments: [String]) async -> String? {
                let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                                             arguments: arguments, workingDirectory: URL(fileURLWithPath: "/"),
                                             timeout: 8, captureLimit: 4096)
                guard let child = try? await ProcessRunner.run(request), child.exitCode == 0 else { return nil }
                let path = String(decoding: child.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.hasPrefix("/") ? path : nil
            }
            if let tool = await xcrun(["--find", "swift"]) {
                resolved[0] = tool
                swiftSDK = await xcrun(["--sdk", "macosx", "--show-sdk-path"])
            }
        }
        try Task.checkCancellation()
        return try Self(argv: resolved, root: root, relativeDirectory: relativeDirectory,
                        environmentOverrides: environmentOverrides, port: port, swiftSDK: swiftSDK)
    }

    private init(argv: [String], root: URL, relativeDirectory: String, environmentOverrides: [String: String] = [:], port: UInt16?, swiftSDK: String?) throws {
        guard let first = argv.first, !first.isEmpty, argv.allSatisfy({ !$0.utf8.contains(0) }),
              argv.reduce(0, { $0 + $1.utf8.count }) < 131_072 else {
            throw ProjectToolsError.invalid("请指定可执行文件，并检查命令参数是否有效。")
        }
        guard let directory = ProjectTools.directory(in: root, relative: relativeDirectory) else {
            throw ProjectToolsError.invalid("运行目录不存在或位于任务工作区之外：" + relativeDirectory)
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw ProjectToolsError.invalid("macOS 的 sandbox-exec 不可用，无法运行项目命令。")
        }
        guard environmentOverrides.allSatisfy({ ProjectTools.allowedEnvironmentNames.contains($0.key) &&
            !$0.value.utf8.contains(0) && $0.value.utf8.count <= 1024 }) else {
            throw ProjectToolsError.invalid("项目环境变量不受支持。可用名称：" +
                                            ProjectTools.allowedEnvironmentNames.joined(separator: ", "))
        }
        var environment = ProcessEnvironment.clean()
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        let extraToolDirectories = [".cargo/bin", ".volta/bin", ".local/share/pnpm"]
            .map { realHome.appendingPathComponent($0).path }
        environment["PATH"] = ([environment["PATH"] ?? ""] + extraToolDirectories).joined(separator: ":")
        let executable: URL?
        if first.contains("/") {
            let path = first.hasPrefix("/") ? URL(fileURLWithPath: first) : directory.appendingPathComponent(first)
            executable = FileManager.default.isExecutableFile(atPath: path.path) ? path.standardizedFileURL : nil
        } else {
            executable = ProcessEnvironment.resolve(first, environment: environment)
        }
        guard let executable else { throw ProjectToolsError.invalid("找不到可用的可执行文件：" + first) }
        self.executable = executable
        self.arguments = Array(argv.dropFirst())
        if let swiftSDK {
            environment["SDKROOT"] = swiftSDK
            let bin = executable.deletingLastPathComponent()
            environment["PATH"] = bin.path + ":" + (environment["PATH"] ?? "")
            environment["SWIFT_EXEC"] = bin.appendingPathComponent("swiftc").path
        }
        self.directory = directory
        var tempPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &tempPath, tempPath.count)
        let tempRoot = count > 0 && count <= tempPath.count
            ? URL(fileURLWithPath: String(cString: tempPath), isDirectory: true)
            : FileManager.default.temporaryDirectory
        let scratch = tempRoot
            .appendingPathComponent("agent-hub-check-" + UUID().uuidString, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        self.scratch = scratch
        // Cocoa atomic writes use the per-user TemporaryItems directory independent
        // of TMPDIR. Select this job's private subdirectory for those writes too.
        environment["DIRHELPER_USER_DIR_SUFFIX"] = scratch.lastPathComponent
        for name in ["HOME", "CFFIXED_USER_HOME", "TMPDIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME",
                     "GIT_CONFIG_GLOBAL", "SWIFTPM_MODULECACHE_OVERRIDE", "CLANG_MODULE_CACHE_PATH"] {
            switch name {
            case "GIT_CONFIG_GLOBAL": environment[name] = "/dev/null"
            case "SWIFTPM_MODULECACHE_OVERRIDE", "CLANG_MODULE_CACHE_PATH":
                environment[name] = scratch.appendingPathComponent("module-cache").path
            default: environment[name] = scratch.path
            }
        }
        environment["CI"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        let rustup = realHome.appendingPathComponent(".rustup")
        if FileManager.default.fileExists(atPath: rustup.path) { environment["RUSTUP_HOME"] = rustup.path }
        if let port {
            environment["HOST"] = "127.0.0.1"
            environment["PORT"] = String(port)
            environment["BROWSER"] = "none"
        }
        environment.merge(environmentOverrides) { _, configured in configured }
        self.environment = environment

        // Foundation deliberately shortens /private/var and /private/tmp to their
        // symlink spellings; the kernel's seatbelt filter uses physical paths.
        func physical(_ url: URL) -> String {
            guard let buffer = realpath(url.path, nil) else { return url.path }
            defer { free(buffer) }
            return String(cString: buffer)
        }
        let writePaths = [physical(root), physical(scratch)]
        let toolchainRelativePaths = [".rustup", ".cargo/bin", ".nvm/versions/node", ".volta/tools",
                                      ".local/share/mise/installs", ".local/bin", ".volta/bin", ".local/share/pnpm", ".pyenv/versions", ".asdf/installs"]
        let readPaths = ["/bin", "/sbin", "/usr", "/opt", "/Applications", "/Library/Developer",
                         "/Library/Java", "/Library/Frameworks", "/Library/Preferences/com.apple.dt.Xcode.plist", "/private/etc", "/private/var/db/xcode_select_link",
                         "/private/var/db/xcode_select_link.lock", "/dev", physical(executable)] + writePaths
            + toolchainRelativePaths.map { realHome.appendingPathComponent($0).path }
        func filters(_ paths: [String]) -> String {
            paths.map { path in
                let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "(subpath \"\(escaped)\")"
            }.joined(separator: " ")
        }
        var policy = """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process-exec* process-fork sysctl-read file-read-metadata)
        (allow signal (target same-sandbox))
        (allow file-read* file-map-executable \(filters(readPaths)))
        (allow file-write* \(filters(writePaths)))
        (deny file-write* \(filters([writePaths[0] + "/.git"])))
        """
        if let port {
            policy += "\n(allow network-bind network-inbound (local tcp \"localhost:\(port)\"))"
        }
        self.profile = policy
    }

    func request(timeout: TimeInterval, arguments replacement: [String]? = nil, captureLimit: Int = 131_072) -> ProcessRequest {
        ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                       arguments: ["-p", profile, executable.path] + (replacement ?? arguments),
                       workingDirectory: directory, environment: environment, timeout: timeout, captureLimit: captureLimit)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }
}

extension ProjectTools {
    public static func run(_ command: ProjectCheckCommand, in root: URL,
                           onStart: @escaping @Sendable (ProcessIdentity) throws -> Void = { _ in },
                           onOutput: @escaping @Sendable (ProcessStream, Data) -> Void = { _, _ in }) async throws -> ProjectCheckResult {
        try Task.checkCancellation()
        var result = ProjectCheckResult(command: command, directory: root.path, status: .blocked)
        do {
            guard command.timeout.isFinite && command.timeout > 0 else {
                throw ProjectToolsError.invalid("验证超时时间必须大于零。")
            }
            let context = try await ProjectCommandContext.prepare(argv: command.argv, root: root, relativeDirectory: command.workingDirectory,
                                                    environmentOverrides: command.environment)
            defer { context.cleanUp() }
            result.directory = context.directory.path
            result.toolVersion = ProcessInfo.processInfo.operatingSystemVersionString + " · " + context.executable.path
            // Never invoke arbitrary project executables twice to obtain a version.
            let conventionalTools = ["python3", "node", "npm", "pnpm", "yarn", "swift", "cargo"]
            if conventionalTools.contains(context.executable.lastPathComponent),
               relative(context.executable, under: root) == nil {
                if let version = try? await ProcessRunner.run(context.request(timeout: min(5, command.timeout),
                                                                              arguments: ["--version"], captureLimit: 2048)),
                   version.exitCode == 0, !version.timedOut,
                   let firstLine = String(decoding: version.stdout, as: UTF8.self).split(separator: "\n").first {
                    result.toolVersion += " · " + String(firstLine.prefix(200))
                }
            }
            try Task.checkCancellation()
            let child = try await ProcessRunner.run(context.request(timeout: command.timeout),
                                                    onStart: onStart, onOutput: onOutput)
            try Task.checkCancellation()
            if child.cancelled { throw CancellationError() }
            result.exitCode = child.exitCode.map(Int.init)
            result.stdout = String(decoding: child.stdout, as: UTF8.self)
            result.stderr = String(decoding: child.stderr, as: UTF8.self)
            if child.stdoutTruncated { result.stdout += "\n[标准输出已截断]" }
            if child.stderrTruncated { result.stderr += "\n[标准错误输出已截断]" }
            if child.timedOut {
                result.status = .blocked
                result.reason = "验证超时（\(command.timeout) 秒）。"
            } else if child.outputDrainIncomplete {
                result.status = .blocked
                result.reason = "进程退出后，其子进程仍占用输出通道，本次验证未完成。"
            } else if child.exitCode == 0 && child.terminationSignal == nil {
                result.status = .passed
            } else if let blocker = environmentBlocker(result.stdout + "\n" + result.stderr, exitCode: result.exitCode) {
                result.status = .blocked
                result.reason = blocker
            } else {
                result.status = .failed
                result.reason = child.terminationSignal.map { "进程被信号 \($0) 终止。" } ?? "命令退出码为 \(child.exitCode ?? -1)。"
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            result.status = .blocked
            result.reason = error.localizedDescription
        }
        result.finishedAt = Date()
        return result
    }

    static func environmentBlocker(_ text: String, exitCode: Int?) -> String? {
        let lines = text.split(separator: "\n")
        let markers = ["sandbox-exec:", "no module named ", "cannot find module ", "command not found",
                       "could not resolve host", "could not resolve hostname", "no matching package named",
                       "failed to download", "developer tools are required", "operation not permitted",
                       "cannot find package "]
        if let line = lines.first(where: { line in markers.contains { line.lowercased().contains($0) } }) {
            return String(line.prefix(500))
        }
        if exitCode == 126 || exitCode == 127 { return "命令或其依赖的可执行文件不可用。" }
        return nil
    }
}
