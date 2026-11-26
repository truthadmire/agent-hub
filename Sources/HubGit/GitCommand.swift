import Foundation
import Darwin

extension GitWorkspaceError {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw GitWorkspaceError.operation(message) }
    }
}

struct GitOutput {
    let data: Data
    let error: String
    let status: Int32

    func checked() throws -> GitOutput {
        guard status == 0 else {
            throw GitWorkspaceError.operation("Git 退出码 \(status)：\(error)")
        }
        return self
    }

    func line() throws -> String {
        var bytes = data
        if bytes.last == 10 { bytes.removeLast() }
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw GitWorkspaceError.operation("Git 返回的路径无法用 UTF-8 表示。")
        }
        return value
    }

    func fields() throws -> [String] {
        try data.split(separator: 0).map {
            guard let field = String(data: Data($0), encoding: .utf8) else {
                throw GitWorkspaceError.operation("仓库中有路径未使用 UTF-8 编码。")
            }
            return field
        }
    }
}

/// File-backed output avoids pipe deadlocks. Git receives an argv array, a fixed
/// executable and a fresh environment. No shell, editor or credential prompt is involved.
struct GitCommand {
    let git = URL(fileURLWithPath: "/usr/bin/git")
    let fm = FileManager.default
    let scratch: URL
    let outputLimit = 32 * 1024 * 1024

    func run(_ cwd: URL, _ args: [String], index: URL? = nil, check: Bool = true,
             exportTo: URL? = nil, input: Data? = nil, readUserExcludes: Bool = false) throws -> GitOutput {
        let temp = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let stdout = try newFile(exportTo ?? temp.appendingPathComponent("stdout"))
        defer { try? stdout.close() }
        let stderr = try newFile(temp.appendingPathComponent("stderr"))
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = git
        process.currentDirectoryURL = cwd
        var ignoreOverride = [String]()
        // Read only the effective global/local ignore-file location. Do not load
        // arbitrary global drivers, hooks or helpers for commands touching files.
        if ["status", "add", "merge"].contains(args.first ?? "") {
            let ignore = try run(cwd, ["config","--path","--get","core.excludesFile"],
                                 check: false, readUserExcludes: true)
            if ignore.status == 0 {
                ignoreOverride = ["-c", "core.excludesFile=" + (try ignore.line())]
            } else if ignore.status != 1 {
                _ = try ignore.checked()
            }
        }
        process.arguments = ["--no-pager", "--no-replace-objects", "-c", "core.hooksPath=/dev/null",
                             "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
                             "-c", "core.splitIndex=false", "-c", "core.preloadIndex=false",
                             "-c", "core.ignoreStat=false", "-c", "core.trustctime=true",
                             "-c", "core.quotePath=false", "-c", "commit.gpgSign=false",
                             "-c", "tag.gpgSign=false", "-c", "protocol.allow=never",
                             "-c", "maintenance.auto=false", "-c", "gc.auto=0",
                             "-c", "rerere.enabled=false", "-c", "submodule.recurse=false",
                             "-c", "merge.autoStash=false", "-c", "merge.verifySignatures=false",
                             "-c", "user.name=Agent Hub", "-c", "user.email=agent-hub@localhost"] + ignoreOverride + args
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C",
                               "HOME": NSHomeDirectory(), "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1",
                               "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
                               "GIT_ALLOW_PROTOCOL": "", "GIT_NO_LAZY_FETCH": "1",
                               "GIT_EDITOR": "/usr/bin/false", "GIT_MERGE_AUTOEDIT": "no"]
        if readUserExcludes { process.environment?.removeValue(forKey: "GIT_CONFIG_GLOBAL") }
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            process.environment?["XDG_CONFIG_HOME"] = xdg
        }
        if let index { process.environment?["GIT_INDEX_FILE"] = index.path }
        process.standardOutput = stdout
        process.standardError = stderr
        var stdin: FileHandle?
        if let input {
            let f = try newFile(temp.appendingPathComponent("stdin"))
            try f.write(contentsOf: input)
            try f.seek(toOffset: 0)
            stdin = f
        }
        defer { try? stdin?.close() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        exited.wait()
        try stderr.seek(toOffset: 0)
        let diagnostic = String(decoding: try stderr.read(upToCount: 4_096) ?? Data(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var data = Data()
        if exportTo == nil {
            try GitWorkspaceError.require(try stdout.offset() <= UInt64(outputLimit),
                "Git 输出超过 32 MiB。请导出补丁以查看完整差异。")
            try stdout.seek(toOffset: 0)
            data = try stdout.readToEnd() ?? Data()
        }
        let result = GitOutput(data: data, error: diagnostic, status: process.terminationStatus)
        return try check ? result.checked() : result
    }

    private func newFile(_ path: URL) throws -> FileHandle {
        let fd = open(path.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
