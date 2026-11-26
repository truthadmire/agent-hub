import Darwin
import Foundation
import HubProcess

private final class PreviewProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: ProcessIdentity?
    private var failure: String?
    func started(_ identity: ProcessIdentity) { lock.withLock { owner = identity } }
    func ended(_ reason: String) { lock.withLock { failure = reason } }
    func snapshot() -> (ProcessIdentity?, String?) { lock.withLock { (owner, failure) } }
}

private final class PreviewSession {
    let token = UUID()
    var server: StaticPreviewServer?
    var process: Task<Void, Never>?
    let state = PreviewProcessState()
    var url: URL?
    func cancel() { server?.stop(); process?.cancel() }
}

/// A URL is usable only while its current task session still owns the listening endpoint.
/// Project scripts run in the same cancellable process supervisor as verification.
public actor PreviewManager {
    public static let shared = PreviewManager()
    private var sessions: [String: PreviewSession] = [:]
    public init() {}

    public func start(taskID: String, root: URL, configuration: PreviewConfiguration,
                      environment: [String: String] = [:], readinessTimeout: TimeInterval = 25) async throws -> URL {
        let slot = PreviewSession()
        let previous = sessions.updateValue(slot, forKey: taskID)
        previous?.cancel()
        await previous?.process?.value
        do {
            try Task.checkCancellation()
            guard sessions[taskID]?.token == slot.token else { throw CancellationError() }
            guard readinessTimeout.isFinite && readinessTimeout > 0 else {
                throw ProjectToolsError.invalid("预览启动超时时间必须大于零。")
            }
            switch configuration {
            case .staticSite(let directory):
                slot.server = try StaticPreviewServer(root: root, directory: directory)
            case .command(let template, let relativeDirectory):
                let port = try Self.availablePort()
                let argv = template.map { $0.replacingOccurrences(of: "{port}", with: String(port)) }
                let state = slot.state
                slot.process = Task.detached {
                    do {
                        let preview = try PreviewWorkspace(copying: root)
                        defer { preview.remove() }
                        let context = try await ProjectCommandContext.prepare(argv: argv, root: preview.path,
                                                    relativeDirectory: relativeDirectory,
                                                    environmentOverrides: environment, port: port)
                        defer { context.cleanUp() }
                        let result = try await ProcessRunner.run(context.request(timeout: 86_400, captureLimit: 4096),
                                                                 onStart: { state.started($0) })
                        let error = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        let summary = error.isEmpty ? "预览进程已退出（退出码 \(result.exitCode ?? -1)）。" : String(error.suffix(800))
                        state.ended(summary)
                    } catch { state.ended(error.localizedDescription) }
                }
                slot.url = URL(string: "http://127.0.0.1:\(port)/")
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(readinessTimeout))
            repeat {
                try Task.checkCancellation()
                guard sessions[taskID]?.token == slot.token else { throw CancellationError() }
                let listener = slot.server?.status()
                if let error = listener?.1 ?? slot.state.snapshot().1 { throw ProjectToolsError.invalid(error) }
                if let staticURL = listener?.0 { slot.url = staticURL }
                if let url = await verifiedURL(slot), sessions[taskID]?.token == slot.token {
                    try Task.checkCancellation()
                    return url
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            } while ContinuousClock.now < deadline
            throw ProjectToolsError.invalid("本地预览服务未响应 HTTP 请求。请让预览命令监听 127.0.0.1，并使用 {port} 占位符或 PORT 环境变量指定端口。")
        } catch {
            if sessions[taskID]?.token == slot.token { await stop(taskID: taskID) }
            throw error
        }
    }

    public func url(for taskID: String) async -> URL? {
        guard let slot = sessions[taskID], let url = await verifiedURL(slot),
              sessions[taskID]?.token == slot.token else { return nil }
        return url
    }

    public func stop(taskID: String) async {
        guard let slot = sessions.removeValue(forKey: taskID) else { return }
        slot.cancel()
        await slot.process?.value
    }

    public func stopAll() async {
        let active = Array(sessions.values)
        sessions.removeAll()
        for slot in active { slot.cancel() }
        for slot in active { await slot.process?.value }
    }

    private func verifiedURL(_ slot: PreviewSession) async -> URL? {
        guard let url = slot.url else { return nil }
        if let server = slot.server {
            guard server.status().0 == url, await Self.responds(url), server.status().0 == url else { return nil }
        } else {
            let (identity, failure) = slot.state.snapshot()
            guard failure == nil, let identity, let port = url.port,
                  await Self.ownsListener(port: port, identity: identity), await Self.responds(url),
                  slot.state.snapshot().1 == nil,
                  await Self.ownsListener(port: port, identity: identity) else { return nil }
        }
        return url
    }

    private static func availablePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProjectToolsError.invalid("无法创建预览服务的网络套接字。") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(address.sin_len)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                guard bind(fd, $0, size) == 0 else { return Int32(-1) }
                return getsockname(fd, $0, &size)
            }
        }
        guard result == 0 else { throw ProjectToolsError.invalid("无法为本地预览预留端口。") }
        return UInt16(bigEndian: address.sin_port)
    }

    static func ownsListener(port: Int, identity: ProcessIdentity) async -> Bool {
        let request = ProcessRequest(executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
                                     arguments: ["-nP", "-a", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpn"],
                                     workingDirectory: URL(fileURLWithPath: "/"), timeout: 3, captureLimit: 8192)
        guard let result = try? await ProcessRunner.run(request), result.exitCode == 0,
              !result.stdoutTruncated, !result.timedOut else { return false }
        var owner: Int32?
        var matched = false
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n") {
            if line.first == "p" { owner = Int32(line.dropFirst()) }
            if line.first == "n" {
                guard let pid = owner, getpgid(pid) == identity.processGroup,
                      line.dropFirst() == "127.0.0.1:\(port)" else { return false }
                matched = true
            }
        }
        return matched
    }

    private static func responds(_ url: URL) async -> Bool {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: PreviewRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else { return false }
            if (200..<300).contains(http.statusCode) { return true }
            if (300..<400).contains(http.statusCode), let location = http.value(forHTTPHeaderField: "Location"),
               let target = URL(string: location, relativeTo: url)?.absoluteURL {
                return target.host == url.host && target.port == url.port && target.scheme == url.scheme
            }
        } catch { return false }
        return false
    }
}

private final class PreviewRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
