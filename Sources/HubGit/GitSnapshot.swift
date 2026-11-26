import Foundation

extension GitWorkspaceService {
    public func head(of workspace: GitWorkspace) throws -> String {
        try locked { try check(workspace); return try oid(workspace.path) }
    }

    public func status(of workspace: GitWorkspace) throws -> [GitChange] {
        try locked { try check(workspace); return try changes(workspace.path) }
    }

    public func previewUncommitted(in supplied: GitProject) throws -> GitSnapshotPreview {
        try locked {
            let current = try project(at: supplied.path)
            try GitWorkspaceError.require(current.id == supplied.id && current.head == supplied.head && current.branch == supplied.branch,
                                          "原项目已变化。请刷新项目，再预览快照。")
            try checkIdle(current.path)
            try checkIndexFlags(current.path)
            let snapshot = try workingTree(in: current.path, head: current.head)
            let patch = try runner.run(current.path, patchArguments(current.head, snapshot.tree)).data
            return GitSnapshotPreview(tree: snapshot.tree, patch: patch, excludedPaths: snapshot.excluded)
        }
    }

    public func snapshotID(of workspace: GitWorkspace) throws -> String {
        try locked {
            try check(workspace)
            try checkIdle(workspace.path)
            try checkIndexFlags(workspace.path)
            let snapshot = try workingTree(in: workspace.path, head: oid(workspace.path))
            try GitWorkspaceError.require(snapshot.excluded.isEmpty, "请先处理受保护的文件，或为它们明确设置忽略规则，再进行验证。")
            return snapshot.tree
        }
    }

    func workingTree(in cwd: URL, head: String) throws -> (tree: String, excluded: [String]) {
        let edits = try changes(cwd)
        let excluded = Set(edits.flatMap { [$0.path, $0.originalPath].compactMap { $0 } }.filter(protectedPath))
        guard !edits.isEmpty else {
            return (try runner.run(cwd, ["rev-parse",head + "^{tree}"]).line(), [])
        }
        let tempIndex = scratch.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tempIndex) }
        _ = try runner.run(cwd, ["read-tree", head], index: tempIndex)
        let exclusions = excluded.sorted().map { ":(top,literal,exclude)" + $0 }
        _ = try runner.run(cwd, ["add","--all","--","."] + exclusions, index: tempIndex)
        // A force-added, otherwise ignored file is already part of the source
        // index. Include its working copy when the user opts into a snapshot.
        let forced = edits.filter { change in
            guard let first = change.code.first, "ARC".contains(first), !excluded.contains(change.path) else { return false }
            var info = stat()
            return lstat(cwd.appendingPathComponent(change.path).path, &info) == 0
        }.map(\.path)
        if !forced.isEmpty {
            var list = Data()
            for path in forced { list.append(contentsOf: path.utf8); list.append(0) }
            _ = try runner.run(cwd, ["--literal-pathspecs","add","-f","--pathspec-from-file=-","--pathspec-file-nul"],
                               index: tempIndex, input: list)
        }
        let tree = try runner.run(cwd, ["write-tree"], index: tempIndex).line()
        try ensureSafeTree(tree, in: cwd)
        return (tree, excluded.sorted())
    }

    func protectedPath(_ path: String) -> Bool {
        let parts = path.lowercased().split(separator: "/").map(String.init)
        let protectedDirs = [".ssh",".aws",".gnupg",".secrets",".azure",".kube",".docker","gcloud"]
        if parts.contains(where: protectedDirs.contains) { return true }
        guard let file = parts.last else { return false }
        if file == ".env" || file.hasPrefix(".env.") {
            return ![".env.example",".env.sample",".env.template"].contains(file)
        }
        if [".npmrc",".pypirc",".netrc","_netrc",".git-credentials",".gitcredentials",
            "id_rsa","id_ecdsa","id_ed25519","auth.json","application_default_credentials.json",
            "keychain.json","secrets.json","secrets.yaml","secrets.yml"].contains(file) { return true }
        return file.hasSuffix(".pem") || file.hasSuffix(".p12") || file.hasSuffix(".pfx")
            || file.hasSuffix(".key") || file.hasSuffix(".mobileprovision") || file.hasPrefix("credentials.")
    }

    func ensureSafeTree(_ object: String, in cwd: URL) throws {
        let entries = try runner.run(cwd, ["ls-tree","-r","-z",try validatedOID(object)]).fields()
        for entry in entries {
            guard let tab = entry.firstIndex(of: "\t") else { throw GitWorkspaceError.operation("Git 树条目无效。") }
            let path = String(entry[entry.index(after: tab)...])
            let meta = entry[..<tab].split(separator: " ")
            try GitWorkspaceError.require(meta.count == 3 && meta[0] != "160000",
                                          "项目含有子模块或嵌套仓库。请准备独立、完整的检出副本后再导入。")
            try GitWorkspaceError.require(!protectedPath(path),
                                          "基线跟踪了受保护的配置文件或密钥文件（\(path)）。请改用已移除这些文件的基线。")
            if path == ".gitattributes" || path.hasSuffix("/.gitattributes") {
                let attributes = try runner.run(cwd, ["cat-file","blob",String(meta[2])]).data
                let requiresFilters = String(decoding: attributes, as: UTF8.self).split(separator: "\n").contains {
                    !$0.hasPrefix("#") && $0.split(whereSeparator: { $0.isWhitespace }).dropFirst().contains { $0.hasPrefix("filter=") }
                }
                try GitWorkspaceError.require(!requiresFilters,
                    "项目使用了 Git LFS 或自定义检出过滤器。请准备包含实际文件且不依赖外部驱动的项目副本。")
            }
        }
    }

    public func checkpoint(_ workspace: GitWorkspace, message: String) throws -> String {
        try locked {
            try check(workspace)
            let path = workspace.path
            try checkIdle(path)
            try checkIndexFlags(path)
            let previous = try oid(path)
            try ensureAncestry(workspace.baseline, previous, in: path)
            let edits = try changes(path)
            guard !edits.isEmpty else { return previous }
            let snapshot = try workingTree(in: path, head: previous)
            try GitWorkspaceError.require(snapshot.excluded.isEmpty, "检查点无法包含受保护的文件。请将这些文件移出工作区，或配置忽略规则。")
            _ = try runner.run(path, ["add","--all","--","."])
            let staged = try runner.run(path, ["write-tree"]).line()
            try GitWorkspaceError.require(staged == snapshot.tree && (try oid(path)) == previous,
                                         "保存检查点时工作区文件发生了变化。请检查暂存的更改后重试。")
            let original = try runner.run(path, ["rev-parse",previous + "^{tree}"]).line()
            if original != staged {
                _ = try runner.run(path, ["commit","--no-gpg-sign","-m",message])
            }
            return try oid(path)
        }
    }

    func patchArguments(_ old: String, _ new: String) -> [String] {
        ["diff","--binary","--full-index","--find-renames","--no-ext-diff","--no-textconv",
         "--no-color","--src-prefix=a/","--dst-prefix=b/",old,new,"--"]
    }

    func reviewHead(of workspace: GitWorkspace, expected: String?) throws -> String {
        let actual = try oid(workspace.path)
        if let expected {
            try GitWorkspaceError.require(actual == expected, "结果在审查后发生了变化。请刷新差异。")
        }
        try ensureAncestry(workspace.baseline, actual, in: workspace.path)
        return actual
    }

    public func changedPaths(of workspace: GitWorkspace, expectedHead: String? = nil) throws -> [String] {
        try locked {
            try check(workspace)
            return try runner.run(workspace.path, ["diff","--no-ext-diff","--no-textconv","--no-renames",
                                                   "--name-only","-z",workspace.baseline,reviewHead(of: workspace, expected: expectedHead),"--"]).fields()
        }
    }

    public func diff(of workspace: GitWorkspace, expectedHead: String? = nil) throws -> Data {
        try locked {
            try check(workspace)
            return try runner.run(workspace.path, patchArguments(workspace.baseline, reviewHead(of: workspace, expected: expectedHead))).data
        }
    }

    public func exportPatch(of workspace: GitWorkspace, to destination: URL, expectedHead: String? = nil) throws {
        try locked {
            try check(workspace)
            try GitWorkspaceError.require(destination.isFileURL, "请选择本地补丁导出位置。")
            // Publish the completed file using an exclusive link. Neither an
            // existing file nor a destination symlink can be overwritten.
            let temp = destination.deletingLastPathComponent().appendingPathComponent(".agent-hub-" + UUID().uuidString)
            defer { try? fm.removeItem(at: temp) }
            _ = try runner.run(workspace.path, patchArguments(workspace.baseline, reviewHead(of: workspace, expected: expectedHead)), exportTo: temp)
            guard link(temp.path, destination.path) == 0 else {
                throw GitWorkspaceError.operation("无法导出补丁。请在可写入的磁盘上选择新的文件名。")
            }
        }
    }
}
