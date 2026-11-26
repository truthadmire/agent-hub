import Foundation
import Darwin

extension GitWorkspaceService {
    public func workspace(id: UUID) throws -> GitWorkspace {
        try locked { try registered(id: id) }
    }

    public func createTask(project supplied: GitProject, id: UUID, includeUncommitted: Bool = false,
                           expectedSnapshotID: String? = nil, baseCommit: String? = nil) throws -> GitWorkspace {
        try locked {
            if let stored = try registration(id) {
                try GitWorkspaceError.require(stored.workspace.kind == .task && stored.workspace.project.id == supplied.id,
                                              "此 ID 已属于另一个工作区。")
                return try restoreRegistration(stored)
            }
            let project = try project(at: supplied.path)
            try GitWorkspaceError.require(project.id == supplied.id && project.head == supplied.head
                    && project.branch == supplied.branch, "原项目的 HEAD 或分支已变化。请刷新项目后再创建任务。")
            try checkIdle(project.path)
            try checkIndexFlags(project.path)
            var base = try validatedOID(baseCommit ?? project.head)
            let verified = try runner.run(project.path, ["rev-parse","--verify",base + "^{commit}"]).line()
            try GitWorkspaceError.require(verified == base, "请选择一个提交作为任务基线。")
            try ensureSafeTree(base, in: project.path)
            if includeUncommitted {
                try GitWorkspaceError.require(base == project.head, "包含未提交更改的快照须基于已检查的原项目 HEAD。")
                let snapshot = try workingTree(in: project.path, head: base)
                if let expectedSnapshotID {
                    try GitWorkspaceError.require(expectedSnapshotID == snapshot.tree, "快照预览后，未提交的内容又发生了变化。请刷新预览。")
                }
                let originalTree = try runner.run(project.path, ["rev-parse",base + "^{tree}"]).line()
                if originalTree != snapshot.tree {
                    base = try runner.run(project.path, ["commit-tree",snapshot.tree,"-p",base,"-m",
                                                        "Agent Hub working-copy snapshot"]).line()
                }
            }
            return try makeWorkspace(project: project, id: id, taskID: id, kind: .task, base: base)
        }
    }

    public func createAttempt(task: GitWorkspace, id: UUID, continuing: GitWorkspace? = nil,
                              expectedHead: String? = nil) throws -> GitWorkspace {
        try locked {
            try check(task, kind: .task)
            if let stored = try registration(id) {
                try GitWorkspaceError.require(stored.workspace.kind == .attempt && stored.workspace.taskID == task.id
                    && stored.workspace.project.id == task.project.id, "此 ID 属于另一个工作区。")
                return try restoreRegistration(stored)
            }
            let parent = continuing ?? task
            if let continuing {
                try check(continuing, kind: .attempt)
                try GitWorkspaceError.require(continuing.taskID == task.id && continuing.project.id == task.project.id
                    && expectedHead != nil, "继续执行需要使用同一任务的检查点。")
            }
            try checkIdle(parent.path)
            try GitWorkspaceError.require(try changes(parent.path).isEmpty, "请先为现有更改保存检查点，再开始下一次尝试。")
            let base = try oid(parent.path)
            if let expectedHead {
                try GitWorkspaceError.require(base == expectedHead, "创建尝试前，上游工作树的检查点发生了变化。")
            }
            try ensureAncestry(task.baseline, base, in: task.path)
            try ensureSafeTree(base, in: task.path)
            return try makeWorkspace(project: task.project, id: id, taskID: task.id, kind: .attempt, base: base)
        }
    }

    private func makeWorkspace(project: GitProject, id: UUID, taskID: UUID,
                               kind: GitWorkspaceKind, base: String) throws -> GitWorkspace {
        let name = id.uuidString.lowercased()
        let path = trees.appendingPathComponent(name, isDirectory: true)
        let prefix = "agent-hub/" + taskID.uuidString.lowercased()
        let branch = kind == .task ? prefix + "/task" : prefix + "/attempt-" + name
        let work = GitWorkspace(id: id, project: project, path: path, branch: branch,
                                baseline: base, taskID: taskID, kind: kind)
        var st = stat()
        try GitWorkspaceError.require(lstat(path.path, &st) != 0 && errno == ENOENT,
                                      "所选工作区路径已被其他目录占用。")
        let ref = try runner.run(project.path, ["show-ref","--verify","--quiet","refs/heads/" + branch], check: false)
        try GitWorkspaceError.require(ref.status == 1, "此工作区名称已被现有 Git 分支占用。")
        let rec = try GitRegistration(workspace: work, source: DirectoryIdentity(project.path),
                                      common: DirectoryIdentity(commonDirectory(project.path)), directory: nil)
        try save(rec)
        return try restoreRegistration(rec)
    }

    func recordURL(_ id: UUID) -> URL {
        records.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    func registration(_ id: UUID) throws -> GitRegistration? {
        let path = recordURL(id)
        var st = stat()
        if lstat(path.path, &st) != 0 {
            if errno == ENOENT { return nil }
            throw GitWorkspaceError.operation("无法读取工作区登记记录。")
        }
        try GitWorkspaceError.require((st.st_mode & S_IFMT) == S_IFREG, "工作区登记记录已被替换。")
        let record = try JSONDecoder().decode(GitRegistration.self, from: Data(contentsOf: path))
        try GitWorkspaceError.require(record.workspace.id == id, "工作区 ID 与登记记录不符。")
        return record
    }

    func save(_ record: GitRegistration) throws {
        try JSONEncoder().encode(record).write(to: recordURL(record.workspace.id), options: .atomic)
    }

    func commonDirectory(_ cwd: URL) throws -> URL {
        try gitPath(cwd, ["rev-parse","--path-format=absolute","--git-common-dir"])
    }

    func registered(id: UUID) throws -> GitWorkspace {
        guard let record = try registration(id) else { throw GitWorkspaceError.operation("找不到已登记的工作区。") }
        return try restoreRegistration(record)
    }

    func restoreRegistration(_ record: GitRegistration) throws -> GitWorkspace {
        let work = record.workspace
        try GitWorkspaceError.require(!record.removed, "工作树已移除，其分支仍保留。")
        try checkSeparation(work.project.path)
        _ = try validatedOID(work.baseline)
        let namespace = "agent-hub/" + work.taskID.uuidString.lowercased()
        let expectedBranch = work.kind == .task ? namespace + "/task" : namespace + "/attempt-" + work.id.uuidString.lowercased()
        try GitWorkspaceError.require(work.branch == expectedBranch && ((work.kind == .task) == (work.id == work.taskID)),
                                      "工作树的分支或归属与登记不符。")
        let expected = trees.appendingPathComponent(work.id.uuidString.lowercased(), isDirectory: true)
        try GitWorkspaceError.require(work.path.path == expected.path && work.path.resolvingSymlinksInPath().path == expected.path,
                                      "已登记的工作区路径发生了变化。")
        try GitWorkspaceError.require(try DirectoryIdentity(work.project.path) == record.source,
                                      "原项目目录已被替换。")
        try validateConfiguration(work.project.path)
        let common = try commonDirectory(work.project.path)
        try GitWorkspaceError.require(try DirectoryIdentity(common) == record.common, "项目的 Git 目录已变化。")
        if record.directory == nil && !fm.fileExists(atPath: work.path.path) {
            // The durable intent was written before creating the worktree. Never
            // attach an independently created branch after a partial operation.
            _ = try runner.run(work.project.path, ["worktree","add","-b",work.branch,"--",work.path.path,work.baseline])
        }
        let actual = try DirectoryIdentity(work.path)
        if let saved = record.directory {
            try GitWorkspaceError.require(saved == actual, "工作区目录已被替换。")
        }
        let marker = work.path.appendingPathComponent(".git")
        let markerText = try readMarker(marker)
        guard markerText.hasPrefix("gitdir: ") else { throw GitWorkspaceError.operation("工作树登记信息无效。") }
        let admin = URL(fileURLWithPath: String(markerText.dropFirst(8)), relativeTo: work.path)
            .absoluteURL.standardizedFileURL
        let prefix = common.appendingPathComponent("worktrees", isDirectory: true)
        try GitWorkspaceError.require(admin.deletingLastPathComponent().path == prefix.path
            && admin.resolvingSymlinksInPath().path == admin.path, "工作树指向了项目 Git 管理目录以外的位置。")
        _ = try DirectoryIdentity(admin)
        let backlink = try readMarker(admin.appendingPathComponent("gitdir"))
        let backURL = URL(fileURLWithPath: backlink, relativeTo: admin).absoluteURL.standardizedFileURL
        try GitWorkspaceError.require(backURL.path == marker.path, "Git 记录的反向引用与当前工作树路径不符。")
        try validateConfiguration(work.path)
        try GitWorkspaceError.require(try branch(work.path) == work.branch && commonDirectory(work.path).path == common.path,
                                      "工作区的分支或仓库已变化。")
        if record.directory == nil {
            try GitWorkspaceError.require(try oid(work.path) == work.baseline, "工作区创建未完成，请手动检查其内容。")
            var completed = record
            completed.directory = actual
            try save(completed)
        }
        return work
    }

    private func readMarker(_ path: URL) throws -> String {
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw GitWorkspaceError.operation("缺少 Git 工作树归属标记。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var st = stat()
        try GitWorkspaceError.require(fstat(fd,&st) == 0 && (st.st_mode & S_IFMT) == S_IFREG && st.st_size <= 16_384,
                                      "Git 工作树归属标记无效。")
        var data = try handle.read(upToCount: 16_385) ?? Data()
        if data.last == 10 { data.removeLast() }
        guard let text = String(data: data, encoding: .utf8) else { throw GitWorkspaceError.operation("Git 路径编码无效。") }
        return text
    }

    func check(_ work: GitWorkspace, kind: GitWorkspaceKind? = nil) throws {
        let actual = try registered(id: work.id)
        try GitWorkspaceError.require(actual == work && (kind == nil || work.kind == kind), "工作区身份与登记记录不符。")
    }

    func checkIndexFlags(_ cwd: URL) throws {
        let entries = try runner.run(cwd, ["ls-files","-v","-z"]).fields()
        try GitWorkspaceError.require(!entries.contains { $0.first?.isLowercase == true || $0.hasPrefix("S ") },
                                      "请清除 skip-worktree 和 assume-unchanged 标记，或导入标准的完整检出。")
    }
}
