import Foundation

/// Development servers can emit generated source as well as caches. Run them on a private
/// working copy so opening a preview can never modify the code snapshot accepted by a task.
struct PreviewWorkspace {
    let path: URL

    init(copying source: URL) throws {
        guard let root = ProjectTools.directory(in: source, relative: ".") else {
            throw ProjectToolsError.invalid("预览工作区不存在。")
        }
        let fs = FileManager.default
        let copy = fs.temporaryDirectory.appendingPathComponent("agent-hub-preview-" + UUID().uuidString, isDirectory: true)
        guard ProjectTools.relative(copy, under: root) == nil else {
            throw ProjectToolsError.invalid("无法在项目内部创建预览副本。")
        }
        try fs.createDirectory(at: copy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var enumerationError: Error?
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            guard let files = fs.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
                throw ProjectToolsError.invalid("无法读取预览工作区。")
            }
            for case let file as URL in files {
                try Task.checkCancellation()
                if file.lastPathComponent == ".git" { files.skipDescendants(); continue }
                // The enumerator may spell /var as /private/var; normalize its parent
                // only, preserving the identity of a symbolic-link leaf.
                guard let parent = ProjectTools.relative(file.deletingLastPathComponent(), under: root) else {
                    throw ProjectToolsError.invalid("预览文件超出任务目录。")
                }
                let relativePath = parent == "." ? file.lastPathComponent : parent + "/" + file.lastPathComponent
                let target = copy.appendingPathComponent(relativePath)
                let attributes = try file.resourceValues(forKeys: keys)
                if attributes.isSymbolicLink == true {
                    files.skipDescendants()
                    var link = try fs.destinationOfSymbolicLink(atPath: file.path)
                    if link.hasPrefix("/"), let relative = ProjectTools.relative(URL(fileURLWithPath: link), under: root) {
                        link = copy.appendingPathComponent(relative).path
                    }
                    try fs.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                } else if attributes.isDirectory == true {
                    try fs.createDirectory(at: target, withIntermediateDirectories: false)
                } else if attributes.isRegularFile == true {
                    try fs.copyItem(at: file, to: target)
                }
            }
            if let enumerationError { throw enumerationError }
            try Task.checkCancellation()
            self.path = copy
        } catch {
            try? fs.removeItem(at: copy)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: path) }
}
