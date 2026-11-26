import Darwin
import Foundation

public enum ProcessStream: String, Codable, Sendable { case stdout, stderr }
public enum ProcessPresence: String, Codable, Sendable { case matching, gone, unverified }

public struct ProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let processGroup: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let executablePath: String
    public let kernelExecutablePath: String
    public let workingDirectory: String
    public let userID: UInt32
    public let bootSession: String
}

public struct ProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]
    public var stdin: Data
    public var timeout: TimeInterval
    public var terminationGrace: TimeInterval
    public var captureLimit: Int
    public var startupTimeout: TimeInterval
    /// Reports a quiet period once until output resumes. Silence alone does not terminate a job.
    public var inactivityWarningAfter: TimeInterval?

    public init(executable: URL, arguments: [String] = [], workingDirectory: URL,
                environment: [String: String] = ProcessEnvironment.clean(),
                stdin: Data = Data(), timeout: TimeInterval = 300,
                terminationGrace: TimeInterval = 1, captureLimit: Int = 262144,
                startupTimeout: TimeInterval = 10, inactivityWarningAfter: TimeInterval? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdin = stdin
        self.timeout = timeout
        self.terminationGrace = terminationGrace
        self.captureLimit = captureLimit
        self.startupTimeout = startupTimeout
        self.inactivityWarningAfter = inactivityWarningAfter
    }
}

public struct ProcessResult: Sendable {
    public let identity: ProcessIdentity
    /// Bounded tails. onOutput receives every observed byte, including those discarded here.
    public let stdout: Data
    public let stderr: Data
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool
    public let stdoutByteCount: UInt64
    public let stderrByteCount: UInt64
    public let exitCode: Int32?
    public let terminationSignal: Int32?
    public let timedOut: Bool
    public let cancelled: Bool
    /// A writer outside the process group retained a descriptor after group cleanup.
    public let outputDrainIncomplete: Bool
}

public enum ProcessRunError: LocalizedError, Sendable {
    case invalidRequest(String)
    case missingGuard
    case system(operation: String, errno: Int32)
    case startupTimedOut

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let field): return "启动进程的参数无效（\(field)）。"
        case .missingGuard: return "应用缺少 HubProcessGuard 可执行文件。请使用完整的 Agent Hub 应用包。"
        case .system(let operation, let number):
            return "\(operation)失败（errno \(number)：\(String(cString: strerror(number)))）。"
        case .startupTimedOut: return "进程未能在规定时间内启动。"
        }
    }
}

public enum ProcessEnvironment {
    /// Fresh allowlist for application-launched tools. Provider credentials may be
    /// added to a single provider request after this call.
    public static func clean(inheriting source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var output: [String: String] = [:]
        let keys = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                    "LC_MESSAGES", "LC_NUMERIC", "TZ", "SHELL"]
        for key in keys {
            if let value = source[key], !value.contains("\0") { output[key] = value }
        }
        let home = output["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        output["HOME"] = home
        let inherited = (source["PATH"] ?? "").split(separator: ":").map(String.init)
        let defaults = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin",
                        "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        output["PATH"] = (inherited + defaults)
            .filter { $0.hasPrefix("/") && !$0.contains("\0") && seen.insert($0).inserted }
            .joined(separator: ":")
        return output
    }

    public static func resolve(_ executable: String, environment: [String: String] = clean()) -> URL? {
        guard !executable.isEmpty, !executable.contains("\0") else { return nil }
        let candidates: [String]
        if executable.hasPrefix("/") {
            candidates = [executable]
        } else {
            guard !executable.contains("/") else { return nil }
            candidates = (environment["PATH"] ?? "").split(separator: ":")
                .filter { $0.hasPrefix("/") }.map { String($0) + "/" + executable }
        }
        let fs = FileManager.default
        for path in candidates {
            var directory: ObjCBool = false
            if fs.fileExists(atPath: path, isDirectory: &directory),
               !directory.boolValue, fs.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
