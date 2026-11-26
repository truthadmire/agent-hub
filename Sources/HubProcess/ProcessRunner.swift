import CProcessSupport
import Darwin
import Foundation

private final class BundleMarker: NSObject {}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
}

private struct OutputTail {
    var data = Data()
    var count: UInt64 = 0

    mutating func append(_ chunk: Data, limit: Int) {
        count += UInt64(chunk.count)
        guard limit > 0 else { return }
        if chunk.count >= limit {
            data = Data(chunk.suffix(limit))
        } else {
            let overflow = data.count - (limit - chunk.count)
            if overflow > 0 { data.removeFirst(overflow) }
            data.append(chunk)
        }
    }

    var truncated: Bool { count > UInt64(data.count) }
}

public enum ProcessRunner {
    /// onStart runs on the job's background queue with the worker still suspended.
    /// Throwing rolls back the process launch. Output callbacks are synchronous and
    /// serialized per job to preserve ordering and apply bounded pipe backpressure.
    public static func run(
        _ request: ProcessRequest,
        onStart: @escaping @Sendable (ProcessIdentity) throws -> Void = { _ in },
        onInactivity: @escaping @Sendable (TimeInterval) -> Void = { _ in },
        onOutput: @escaping @Sendable (ProcessStream, Data) -> Void = { _, _ in }
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        try validate(request)
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try execute(request, flag: flag, onStart: onStart, onInactivity: onInactivity, onOutput: onOutput)
                    })
                }
            }
        } onCancel: { flag.cancel() }
    }

    /// Recovery inspection is observational. A recorded numeric PID or PGID is
    /// never used as authority to signal a process after the application restarts.
    public static func inspect(_ identity: ProcessIdentity) -> ProcessPresence {
        guard identity.pid > 1, identity.processGroup > 1, identity.startSeconds > 0,
              let boot = bootSession(), UUID(uuidString: identity.bootSession) != nil else { return .unverified }
        guard boot == identity.bootSession else { return .gone }
        let (error, stamp, path) = kernelStamp(identity.pid)
        if error == ESRCH { return .gone }
        if stamp.seconds > 0 && (stamp.seconds != identity.startSeconds || stamp.microseconds != identity.startMicroseconds) {
            // A birth time cannot change. This PID now belongs to a different process.
            return .gone
        }
        guard error == 0, stamp.uid == identity.userID, stamp.group == identity.processGroup,
              path == identity.kernelExecutablePath else { return .unverified }
        return .matching
    }

    static func guardExecutable() throws -> URL {
        let app = Bundle.main
        if app.bundleURL.pathExtension == "app" {
            let helper = app.bundleURL.appendingPathComponent("Contents/Helpers/HubProcessGuard")
            if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
            throw ProcessRunError.missingGuard
        }
        let directories: [URL?] = [app.executableURL?.deletingLastPathComponent(), app.bundleURL,
            Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()]
        for case let directory? in directories {
            let helper = directory.appendingPathComponent("HubProcessGuard")
            if FileManager.default.isExecutableFile(atPath: helper.path) { return helper }
        }
        throw ProcessRunError.missingGuard
    }

    private static func validate(_ request: ProcessRequest) throws {
        for url in [request.executable, request.workingDirectory] {
            guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
                throw ProcessRunError.invalidRequest("path")
            }
        }
        guard !request.arguments.contains(where: { $0.contains("\0") }) else {
            throw ProcessRunError.invalidRequest("argv")
        }
        for (key, value) in request.environment {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !value.contains("\0") else {
                throw ProcessRunError.invalidRequest("environment")
            }
        }
        guard request.timeout.isFinite, request.timeout > 0, request.terminationGrace.isFinite,
              request.terminationGrace >= 0, request.captureLimit >= 0, request.startupTimeout.isFinite,
              request.startupTimeout > 0 else { throw ProcessRunError.invalidRequest("limits") }
        if let idle = request.inactivityWarningAfter, !idle.isFinite || idle <= 0 {
            throw ProcessRunError.invalidRequest("inactivity")
        }
    }

    private static func withVector<T>(_ strings: [String],
                                      _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> T) throws -> T {
        var vector: [UnsafeMutablePointer<CChar>?] = []
        defer { vector.forEach { free($0) } }
        for string in strings {
            guard let pointer = strdup(string) else { throw ProcessRunError.system(operation: "分配进程参数", errno: ENOMEM) }
            vector.append(pointer)
        }
        vector.append(nil)
        return try vector.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    private static func bootSession() -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        return hub_boot_session(&buffer, buffer.count) == 0 ? String(cString: buffer) : nil
    }

    private static func kernelStamp(_ pid: Int32) -> (Int32, hub_process_stamp, String) {
        var stamp = hub_process_stamp()
        var path = [CChar](repeating: 0, count: 4096)
        let error = hub_stamp(pid, &stamp, &path, Int32(path.count))
        return (error, stamp, String(cString: path))
    }

    /// Monotonic awake-time budgets pause while the Mac sleeps.
    private static var now: TimeInterval { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

    private static func execute(
        _ request: ProcessRequest, flag: CancellationFlag,
        onStart: (ProcessIdentity) throws -> Void, onInactivity: (TimeInterval) -> Void,
        onOutput: (ProcessStream, Data) -> Void
    ) throws -> ProcessResult {
        if flag.isCancelled { throw CancellationError() }
        let helper = try guardExecutable()
        let launched = now
        var job = hub_job()
        let launchError = try withVector([request.executable.path] + request.arguments) { argv in
            try withVector(request.environment.map { "\($0.key)=\($0.value)" }) { env in
                hub_spawn(&job, helper.path, request.executable.path, argv, request.workingDirectory.path, env,
                          Int32(min(Double(Int32.max), ceil(request.startupTimeout * 1000))))
            }
        }
        if launchError == ETIMEDOUT { throw ProcessRunError.startupTimedOut }
        guard launchError == 0 else { throw ProcessRunError.system(operation: "启动进程", errno: launchError) }
        defer { hub_dispose(&job) }
        let (stampError, stamp, path) = kernelStamp(job.pid)
        guard stampError == 0, stamp.group == job.group else {
            throw ProcessRunError.system(operation: "识别挂起的进程", errno: stampError == 0 ? EINVAL : stampError)
        }
        let identity = ProcessIdentity(pid: job.pid, processGroup: job.group, startSeconds: stamp.seconds,
            startMicroseconds: stamp.microseconds, executablePath: request.executable.path, kernelExecutablePath: path,
            workingDirectory: request.workingDirectory.path, userID: stamp.uid, bootSession: bootSession() ?? "")
        try onStart(identity)
        guard now - launched < request.startupTimeout else { throw ProcessRunError.startupTimedOut }
        let cancelledBeforeResume = flag.isCancelled
        if cancelledBeforeResume {
            hub_kill_group(&job)
        } else {
            let error = hub_resume(&job)
            guard error == 0 else { throw ProcessRunError.system(operation: "恢复进程", errno: error) }
        }
        return try supervise(&job, request: request, identity: identity, flag: flag, cancelledBeforeResume: cancelledBeforeResume,
                             onInactivity: onInactivity, onOutput: onOutput)
    }

    private static func closeFD(_ fd: inout Int32) {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    private static func readOutput(_ fd: inout Int32, into tail: inout OutputTail, limit: Int,
                                   buffer: inout [UInt8], publish: (Data) -> Void) throws -> Bool {
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count == 0 { closeFD(&fd); return false }
        if count < 0 {
            if errno == EINTR || errno == EAGAIN { return false }
            throw ProcessRunError.system(operation: "读取进程输出", errno: errno)
        }
        let chunk = Data(buffer.prefix(count))
        tail.append(chunk, limit: limit)
        publish(chunk)
        return true
    }

    private static func writeInput(_ fd: inout Int32, data: Data, offset: inout Int) throws {
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), min(bytes.count - offset, 32 * 1024))
        }
        if written > 0 { offset += written }
        if written < 0 {
            if errno == EPIPE || errno == ECONNRESET { closeFD(&fd); return }
            if errno == EINTR || errno == EAGAIN { return }
            throw ProcessRunError.system(operation: "写入进程输入", errno: errno)
        }
        if offset == data.count { closeFD(&fd) }
    }

    private static func supervise(
        _ job: inout hub_job, request: ProcessRequest, identity: ProcessIdentity, flag: CancellationFlag, cancelledBeforeResume: Bool,
        onInactivity: (TimeInterval) -> Void, onOutput: (ProcessStream, Data) -> Void
    ) throws -> ProcessResult {
        var output = OutputTail(), errors = OutputTail()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var offset = 0
        var code: Int32 = -1, signal: Int32 = -1
        var cancelled = cancelledBeforeResume, timedOut = false, warned = false, incomplete = false
        let began = now
        var lastOutput = began
        var terminationStarted: TimeInterval? = cancelledBeforeResume ? began : nil
        var exited: TimeInterval?
        if request.stdin.isEmpty { closeFD(&job.input) }

        while true {
            let tick = now
            if exited == nil {
                let state = hub_check_exit(&job, &code, &signal)
                if state < 0 { throw ProcessRunError.system(operation: "等待进程结束", errno: -state) }
                if state == 1 {
                    exited = tick
                    closeFD(&job.input)
                    hub_kill_group(&job)
                } else if terminationStarted == nil {
                    if flag.isCancelled || tick - began >= request.timeout {
                        cancelled = flag.isCancelled
                        timedOut = !cancelled
                        terminationStarted = tick
                        if hub_term(&job) != 0 { hub_kill_group(&job) }
                    } else if let limit = request.inactivityWarningAfter, !warned, tick - lastOutput >= limit {
                        warned = true
                        onInactivity(tick - lastOutput)
                    }
                }
            }
            if let started = terminationStarted, job.group > 0, tick - started >= request.terminationGrace {
                hub_kill_group(&job)
            }
            if let ended = exited {
                if job.output < 0 && job.error_output < 0 { break }
                // A detached descendant could hold an unrelated writer open forever.
                if tick - ended >= 2 { incomplete = true; break }
            }

            var fds = [pollfd(fd: job.output, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: job.error_output, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: job.input, events: Int16(POLLOUT), revents: 0)]
            let ready = Darwin.poll(&fds, nfds_t(fds.count), 20)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ProcessRunError.system(operation: "轮询进程输入输出", errno: errno)
            }
            var activity = false
            if fds[0].revents != 0 {
                activity = try readOutput(&job.output, into: &output, limit: request.captureLimit, buffer: &buffer) {
                    onOutput(.stdout, $0)
                }
            }
            if fds[1].revents != 0 {
                let received = try readOutput(&job.error_output, into: &errors, limit: request.captureLimit, buffer: &buffer) {
                    onOutput(.stderr, $0)
                }
                activity = activity || received
            }
            if fds[2].revents != 0 { try writeInput(&job.input, data: request.stdin, offset: &offset) }
            if activity { lastOutput = now; warned = false }
        }
        return ProcessResult(identity: identity, stdout: output.data, stderr: errors.data,
            stdoutTruncated: output.truncated, stderrTruncated: errors.truncated,
            stdoutByteCount: output.count, stderrByteCount: errors.count,
            exitCode: code >= 0 ? code : nil, terminationSignal: signal >= 0 ? signal : nil,
            timedOut: timedOut, cancelled: cancelled, outputDrainIncomplete: incomplete)
    }
}
