import Darwin
import Foundation
import Network
import UniformTypeIdentifiers

/// Open every component relative to a pinned directory FD. A renamed directory or a
/// symlink inserted between two requests must never turn into access to another tree.
private final class PublicFiles {
    private let rootFD: Int32
    private var allowed: Set<String>?
    private static let extensions: Set<String> = [
        "html", "htm", "css", "js", "mjs", "json", "svg", "png", "jpg", "jpeg", "webp", "gif",
        "avif", "ico", "woff", "woff2", "ttf", "otf", "mp3", "mp4", "webm", "webmanifest", "wasm"
    ]
    init(root: URL, directory: String) throws {
        guard let publicRoot = ProjectTools.directory(in: root, relative: directory) else {
            throw ProjectToolsError.invalid("配置的静态资源目录不可用。")
        }
        let components = directory.split(separator: "/").filter { $0 != "." }
        guard !directory.hasPrefix("/"), !components.contains("..") else {
            throw ProjectToolsError.invalid("静态资源目录必须位于任务工作区内。")
        }
        var fd = open(root.standardizedFileURL.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        for component in components where fd >= 0 {
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            close(fd)
            fd = next
        }
        guard fd >= 0 else { throw ProjectToolsError.invalid("无法打开静态资源目录。") }
        self.rootFD = fd
        guard let index = read("index.html", limit: 8_388_608), !index.isEmpty else {
            throw ProjectToolsError.invalid("静态预览需要可读取的 index.html 文件。")
        }
        if ProjectTools.relative(publicRoot, under: root) == "." {
            self.allowed = references(from: index)
        }
    }
    deinit { close(rootFD) }

    private func read(_ path: String, limit: Int) -> Data? {
        let components = path.components(separatedBy: "/")
        guard components.count <= 48,
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") &&
                  !$0.utf8.contains(0) && $0 != "node_modules" }),
              Self.extensions.contains((path as NSString).pathExtension.lowercased()),
              allowed?.contains(path) ?? true else { return nil }
        var fd = fcntl(rootFD, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        for (index, name) in components.enumerated() {
            let directoryFlag: Int32 = index < components.count - 1 ? O_DIRECTORY : 0
            let next = openat(fd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | directoryFlag)
            guard next >= 0 else { return nil }
            close(fd)
            fd = next
        }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { return nil }
        if info.st_size == 0 { return Data() }
        guard let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1),
              data.count <= limit else { return nil }
        return data
    }

    /// A bare repository has no public-directory boundary. Expose only index.html and
    /// local assets reachable through HTML references, CSS URLs, and ES module imports.
    private func references(from index: Data) -> Set<String> {
        let pattern = #"(?i)(?:\b(?:src|href|poster)\s*=\s*["']([^"']+)["']|\burl\(\s*["']?([^"'\)]+)["']?\s*\)|(?:@import|\bfrom|\bimport)\s*["']([^"']+)["'])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ["index.html"] }
        let base = URL(string: "http://127.0.0.1/")!
        var known: Set<String> = ["index.html"]
        var queue: [(String, Data)] = [("index.html", index)]
        var remainingBytes = 16_777_216 - index.count
        while let (parent, data) = queue.popLast(), remainingBytes > 0, known.count < 2_048 {
            let text = String(decoding: data, as: UTF8.self) as NSString
            let parentURL = base.appendingPathComponent(parent)
            regex.enumerateMatches(in: text as String, range: NSRange(location: 0, length: text.length)) { match, _, stop in
                guard let match else { return }
                if known.count >= 2_048 { stop.pointee = true; return }
                guard let capture = (1..<match.numberOfRanges).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return }
                let ref = text.substring(with: capture).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.hasPrefix("//"), !ref.hasPrefix("#"), URLComponents(string: ref)?.scheme == nil,
                      let url = URL(string: ref, relativeTo: parentURL)?.standardized,
                      url.host == base.host else { return }
                let path = String(url.path.dropFirst())
                let ext = (path as NSString).pathExtension.lowercased()
                guard Self.extensions.contains(ext), known.insert(path).inserted else { return }
                if ["html", "htm", "css", "js", "mjs"].contains(ext),
                   let contents = self.read(path, limit: min(remainingBytes > 0 ? remainingBytes : 0, 2_097_152)) {
                    queue.append((path, contents))
                    remainingBytes -= contents.count
                }
            }
        }
        return known
    }

    func response(path: String) -> (Data, String)? {
        guard let data = read(path, limit: 32 * 1024 * 1024) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "js", "mjs": mime = "text/javascript"
        case "css": mime = "text/css"
        case "html", "htm": mime = "text/html; charset=utf-8"
        case "wasm": mime = "application/wasm"
        default: mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
        return (data, mime)
    }
}

final class StaticPreviewServer: @unchecked Sendable {
    private let files: PublicFiles
    private let listener: NWListener
    private let queue = DispatchQueue(label: "agent-hub.static-preview")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var pendingBytes = 0
    private var readyURL: URL?
    private var failure: String?

    init(root: URL, directory: String) throws {
        files = try PublicFiles(root: root, directory: directory)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.allowLocalEndpointReuse = false
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port {
                    self.readyURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")
                }
            case .failed(let error):
                self.readyURL = nil
                self.failure = error.localizedDescription
                self.listener.cancel()
            case .cancelled: self.readyURL = nil
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func status() -> (URL?, String?) { queue.sync { (readyURL, failure) } }
    func stop() {
        queue.sync {
            listener.cancel()
            readyURL = nil
            for connection in connections.values { connection.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.connections.removeValue(forKey: key)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, previous: Data())
        queue.asyncAfter(deadline: .now() + 10) { [weak connection] in connection?.cancel() }
    }

    private func receive(on connection: NWConnection, previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
            guard let self, let bytes, error == nil else { connection.cancel(); return }
            var buffer = previous
            buffer.append(bytes)
            guard buffer.count <= 16_384 else { connection.cancel(); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(to: connection, header: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if done {
                connection.cancel()
            } else { self.receive(on: connection, previous: buffer) }
        }
    }

    private func respond(to connection: NWConnection, header: String) {
        let lines = header.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").components(separatedBy: " ")
        let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
        var status = "404 Not Found"
        var mime = "text/plain"
        var data = Data()
        if first.count == 3, ["HEAD", "GET"].contains(first[0]), first[1].hasPrefix("/"),
           !first[1].hasPrefix("//"), hosts.count == 1, let port = listener.port,
           String(hosts[0].dropFirst(5)).trimmingCharacters(in: .whitespaces) == "127.0.0.1:\(port.rawValue)",
           let encoded = first[1].components(separatedBy: "?").first,
           let decoded = encoded.removingPercentEncoding, !decoded.contains("%"),
           pendingBytes < 32 * 1024 * 1024 {
            var path = String(decoded.dropFirst())
            if path.isEmpty || path.hasSuffix("/") { path += "index.html" }
            if let file = files.response(path: path) {
                (data, mime) = file
                status = "200 OK"
            }
        }
        let count = data.count
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(count)\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-store\r\nContent-Security-Policy: worker-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n".utf8)
        if first.first != "HEAD" { response.append(data) }
        pendingBytes += count
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.pendingBytes -= count
            connection.cancel()
        })
    }
}
