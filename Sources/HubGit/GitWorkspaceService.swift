import Foundation
import CryptoKit
import Darwin

struct DirectoryIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw GitWorkspaceError.operation("在 \(url.path) 找不到原目录。")
        }
        device = UInt64(UInt32(bitPattern: info.st_dev))
        inode = UInt64(info.st_ino)
    }
}

struct GitRegistration: Codable {
    let workspace: GitWorkspace
    let source: DirectoryIdentity
    let common: DirectoryIdentity
    var directory: DirectoryIdentity?
    var removed = false
    var removalHead: String? = nil
}

/// Calls perform disk I/O and should run off the main actor. The process file
/// lock also serializes integrations across multiple windows/service instances.
public final class GitWorkspaceService: @unchecked Sendable {
    public let managedRoot: URL
    let fm = FileManager.default
    let runner: GitCommand
    let trees: URL
    let records: URL
    let scratch: URL
    let rootIdentity: DirectoryIdentity
    let treesIdentity: DirectoryIdentity
    let recordsIdentity: DirectoryIdentity
    let scratchIdentity: DirectoryIdentity

    public init(managedRoot: URL) throws {
        try GitWorkspaceError.require(managedRoot.isFileURL && managedRoot.path != "/",
                                      "请选择专用于存放任务工作树的本地目录。")
        let fm = FileManager.default
        if fm.fileExists(atPath: managedRoot.path) { _ = try DirectoryIdentity(managedRoot) }
        let root = managedRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.managedRoot = root
        trees = root.appendingPathComponent("worktrees", isDirectory: true)
        records = root.appendingPathComponent("registrations", isDirectory: true)
        scratch = root.appendingPathComponent("temporary", isDirectory: true)
        for dir in [root, trees, records, scratch] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = try DirectoryIdentity(dir)
        }
        rootIdentity = try DirectoryIdentity(root)
        treesIdentity = try DirectoryIdentity(trees)
        recordsIdentity = try DirectoryIdentity(records)
        scratchIdentity = try DirectoryIdentity(scratch)
        runner = GitCommand(scratch: scratch)
    }

    func locked<T>(_ work: () throws -> T) throws -> T {
        try GitWorkspaceError.require(try DirectoryIdentity(managedRoot) == rootIdentity
            && DirectoryIdentity(trees) == treesIdentity && DirectoryIdentity(records) == recordsIdentity
            && DirectoryIdentity(scratch) == scratchIdentity, "受管目录已被移动或替换。")
        let fd = open(managedRoot.appendingPathComponent("service.lock").path,
                      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GitWorkspaceError.operation("无法打开工作区锁文件。") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            if errno != EINTR { throw GitWorkspaceError.operation("无法锁定受管工作区。") }
        }
        defer { flock(fd, LOCK_UN) }
        return try work()
    }

    public func inspectProject(at directory: URL) throws -> GitProject {
        try locked {
            let info = try project(at: directory)
            try rememberOrigin(info)
            return info
        }
    }

    public func initializeProject(at directory: URL) throws -> GitProject {
        try locked {
            let directory = directory.standardizedFileURL
            guard directory.isFileURL else { throw GitWorkspaceError.operation("请选择本地目录。") }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try DirectoryIdentity(directory)
            let cwd = directory.resolvingSymlinksInPath()
            try checkSeparation(cwd)
            try GitWorkspaceError.require(!fm.fileExists(atPath: cwd.appendingPathComponent(".git").path)
                && (try runner.run(cwd, ["rev-parse", "--git-dir"], check: false)).status != 0,
                "此目录已有 Git 仓库。请使用“导入项目”。")
            try GitWorkspaceError.require(try fm.contentsOfDirectory(atPath: cwd.path).allSatisfy { $0 == ".DS_Store" },
                "请在空目录中新建项目。对于现有项目，请先提交用作基线的版本，再导入项目。")
            _ = try runner.run(cwd, ["init", "--template=", "--initial-branch=main", "."])
            _ = try runner.run(cwd, ["commit", "--allow-empty", "-m", "Initialize project"])
            let info = try project(at: cwd)
            try rememberOrigin(info)
            return info
        }
    }

    func project(at directory: URL) throws -> GitProject {
        try GitWorkspaceError.require(directory.isFileURL, "请选择本地仓库。")
        let cwd = directory.standardizedFileURL.resolvingSymlinksInPath()
        try validateConfiguration(cwd)
        let path = try gitPath(cwd, ["rev-parse", "--show-toplevel"])
        // Resolve the nearest repository only when the selected folder is its root.
        try GitWorkspaceError.require(cwd.path == path.path, "请选择项目 Git 仓库的根目录。")
        try checkSeparation(path)
        let manifests = [("Package.swift","Swift"),("package.json","JavaScript / TypeScript"),
                         ("Cargo.toml","Rust"),("pyproject.toml","Python"),("requirements.txt","Python"),
                         ("go.mod","Go"),("build.gradle","Gradle"),("pom.xml","Maven")]
        var seen = Set<String>()
        let tech = manifests.compactMap { file, label in
            fm.fileExists(atPath: path.appendingPathComponent(file).path) && seen.insert(label).inserted ? label : nil
        }
        let identity = try DirectoryIdentity(path)
        let common = try DirectoryIdentity(commonDirectory(path))
        let key = "\(identity.device):\(identity.inode)/\(common.device):\(common.inode)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let head = try runner.run(path, ["rev-parse", "--verify", "HEAD^{commit}"], check: false)
        try GitWorkspaceError.require(head.status == 0, "请为项目创建首次 Git 提交，然后再导入。")
        return try GitProject(id: digest, path: path, branch: branch(path), head: head.line(),
                              changes: changes(path), technologies: tech)
    }

    func checkSeparation(_ project: URL) throws {
        let a = managedRoot.path, b = project.path
        try GitWorkspaceError.require(a != b && !a.hasPrefix(b + "/") && !b.hasPrefix(a + "/") && b != "/",
                                     "受管目录与原项目目录必须分开存放，且不能互相嵌套。")
    }

    func gitPath(_ cwd: URL, _ args: [String]) throws -> URL {
        let str = try runner.run(cwd, args).line()
        return URL(fileURLWithPath: str, relativeTo: cwd).absoluteURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func branch(_ path: URL) throws -> String? {
        let out = try runner.run(path, ["symbolic-ref", "--quiet", "HEAD"], check: false)
        if out.status == 1 { return nil }
        let ref = try out.checked().line()
        guard ref.hasPrefix("refs/heads/") else { throw GitWorkspaceError.operation("HEAD 指向了非预期的引用。") }
        return String(ref.dropFirst("refs/heads/".count))
    }

    func oid(_ cwd: URL) throws -> String { try runner.run(cwd, ["rev-parse", "--verify", "HEAD^{commit}"]).line() }

    func changes(_ path: URL, includeIgnored: Bool = false) throws -> [GitChange] {
        let args = ["status","--porcelain=v1","-z","--untracked-files=all","--ignore-submodules=none"]
        let fields = try runner.run(path, args + (includeIgnored ? ["--ignored=matching"] : [])).fields()
        var index = 0, result = [GitChange]()
        while index < fields.count {
            let bytes = Array(fields[index].utf8)
            guard bytes.count >= 4, bytes[2] == 32 else { throw GitWorkspaceError.operation("Git 状态记录格式无效。") }
            let code = String(decoding: bytes.prefix(2), as: UTF8.self)
            let name = String(decoding: bytes.dropFirst(3), as: UTF8.self)
            index += 1
            var original: String?
            if code.contains("R") || code.contains("C") {
                guard index < fields.count else { throw GitWorkspaceError.operation("Git 的重命名记录不完整。") }
                original = fields[index]
                index += 1
            }
            result.append(.init(code: code, path: name, originalPath: original))
        }
        return result
    }

    func validateConfiguration(_ cwd: URL) throws {
        // Repository-controlled drivers and includes can execute programs or redirect
        // a checkout. Refuse them before asking Git to inspect any worktree files.
        let result = try runner.run(cwd, ["config","--local","--no-includes","--name-only","--null","--list"], check: false)
        guard result.status == 0 else { throw GitWorkspaceError.operation("请选择 Git 仓库。如要导入普通目录，请先初始化仓库并创建首次提交。") }
        var keys = try result.fields().map { $0.lowercased() }
        if keys.contains("extensions.worktreeconfig") {
            keys += try runner.run(cwd, ["config","--worktree","--no-includes","--name-only","--null","--list"]).fields().map { $0.lowercased() }
        }
        for key in keys {
            if key.hasPrefix("filter.") || key.hasPrefix("include.") || key.hasPrefix("includeif.")
                || (key.hasPrefix("merge.") && key.hasSuffix(".driver"))
                || (key.hasPrefix("branch.") && key.hasSuffix(".mergeoptions"))
                || (key.hasPrefix("diff.") && (key.hasSuffix(".command") || key.hasSuffix(".textconv")))
                || key == "core.worktree" || key == "core.alternaterefscommand"
                || key == "extensions.partialclone" || key.hasSuffix(".promisor")
                || key == "core.sparsecheckout" || key == "core.attributesfile"
                || key == "core.fsmonitorhookversion" || key == "core.ignorestat"
                || key == "core.checkstat" || key == "core.trustctime" {
                throw GitWorkspaceError.operation("当前仓库设置 \(key) 与受管工作树不兼容。请导入完整检出、不依赖外部驱动且工作树干净的本地克隆。")
            }
        }
    }

    func checkIdle(_ cwd: URL) throws {
        let admin = try gitPath(cwd, ["rev-parse","--absolute-git-dir"])
        for name in ["MERGE_HEAD","CHERRY_PICK_HEAD","REVERT_HEAD","rebase-merge","rebase-apply","BISECT_START","sequencer","index.lock"] {
            if fm.fileExists(atPath: admin.appendingPathComponent(name).path) {
                throw GitWorkspaceError.operation("请先在 \(cwd.path) 完成尚未结束的 Git 操作（\(name)）。")
            }
        }
    }

    func ensureAncestry(_ parent: String, _ child: String, in cwd: URL) throws {
        let relation = try runner.run(cwd, ["merge-base","--is-ancestor", parent, child], check: false)
        try GitWorkspaceError.require(relation.status == 0, "该提交的历史已不包含记录中的基线提交。")
    }

    func validatedOID(_ oid: String) throws -> String {
        try GitWorkspaceError.require([40,64].contains(oid.utf8.count) && oid.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }, "请输入完整的 Git 提交或树对象 ID。")
        return oid
    }
}
