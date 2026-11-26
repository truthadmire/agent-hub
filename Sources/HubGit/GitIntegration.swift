import Foundation

extension GitWorkspaceService {
    public func integrate(attempt: GitWorkspace, into task: GitWorkspace, expectedAttemptHead: String,
                          expectedTaskHead: String) throws -> GitIntegration {
        try locked {
            try check(task, kind: .task)
            try check(attempt, kind: .attempt)
            try GitWorkspaceError.require(attempt.taskID == task.id && attempt.project.id == task.project.id,
                                          "这次尝试属于另一个任务。")
            let incoming = try validatedOID(expectedAttemptHead)
            let previous = try validatedOID(expectedTaskHead)
            try GitWorkspaceError.require(try oid(task.path) == previous && oid(attempt.path) == incoming,
                                          "尝试工作树或整合工作树的 HEAD 已变化。请重新检查结果。")
            try ensureAncestry(task.baseline, attempt.baseline, in: task.path)
            try ensureAncestry(attempt.baseline, incoming, in: task.path)
            try ensureAncestry(task.baseline, previous, in: task.path)
            try checkIdle(attempt.path)
            try checkIndexFlags(attempt.path)
            try checkIndexFlags(task.path)
            try GitWorkspaceError.require(try changes(attempt.path).isEmpty, "尝试工作树在保存检查点后又有更改。")
            if let pending = try mergeHead(task.path) {
                try GitWorkspaceError.require(pending == incoming, "请先解决上一次整合留下的冲突。")
                return .conflict(try conflictPaths(task.path))
            }
            try checkIdle(task.path)
            try GitWorkspaceError.require(try changes(task.path).isEmpty, "整合工作树还有未提交的更改。")
            try ensureSafeTree(incoming, in: task.path)
            let merge = try runner.run(task.path, ["merge","--ff","--no-edit","--no-overwrite-ignore","--no-autostash",
                                                   "--no-gpg-sign","--no-stat",incoming], check: false)
            if merge.status == 0 {
                let head = try oid(task.path)
                try ensureAncestry(incoming, head, in: task.path)
                return .integrated(head)
            }
            let conflicts = try conflictPaths(task.path)
            if !conflicts.isEmpty, try mergeHead(task.path) == incoming { return .conflict(conflicts) }
            throw GitWorkspaceError.operation("整合已停止。Git 返回：\(merge.error)")
        }
    }

    /// Reconciles a durable integration intent if the app exited after Git
    /// advanced the branch, but before the controller recorded that result.
    public func hasIntegrated(attempt: GitWorkspace, into task: GitWorkspace, expectedAttemptHead: String,
                              previousTaskHead: String) throws -> Bool {
        try locked {
            try check(task, kind: .task)
            try check(attempt, kind: .attempt)
            guard attempt.taskID == task.id && attempt.project.id == task.project.id else { return false }
            let incoming = try validatedOID(expectedAttemptHead)
            let previous = try validatedOID(previousTaskHead)
            guard try oid(attempt.path) == incoming, try mergeHead(task.path) == nil,
                  try changes(task.path).isEmpty, try changes(attempt.path).isEmpty else { return false }
            try checkIdle(attempt.path)
            try checkIdle(task.path)
            try checkIndexFlags(attempt.path)
            try checkIndexFlags(task.path)
            try ensureAncestry(task.baseline, previous, in: task.path)
            try ensureAncestry(task.baseline, attempt.baseline, in: task.path)
            try ensureAncestry(attempt.baseline, incoming, in: task.path)
            let actual = try oid(task.path)
            if actual == incoming {
                return try runner.run(task.path, ["merge-base","--is-ancestor",previous,incoming], check: false).status == 0
            }
            if actual == previous {
                return try runner.run(task.path, ["merge-base","--is-ancestor",incoming,previous], check: false).status == 0
            }
            let parents = try runner.run(task.path, ["show","-s","--format=%P",actual]).line()
            return parents == previous + " " + incoming
        }
    }

    /// A merge conflict remains on disk across restart. Stage a reviewed resolution
    /// in the task worktree before completing the same merge.
    public func finishConflict(in task: GitWorkspace, expectedTaskHead: String,
                               expectedAttemptHead: String) throws -> String {
        try locked {
            try check(task, kind: .task)
            let old = try validatedOID(expectedTaskHead)
            let incoming = try validatedOID(expectedAttemptHead)
            try GitWorkspaceError.require(try oid(task.path) == old && mergeHead(task.path) == incoming,
                                          "冲突来源或整合工作树的 HEAD 已变化。")
            try GitWorkspaceError.require(try conflictPaths(task.path).isEmpty, "请解决所有冲突并暂存涉及的文件。")
            let edits = try changes(task.path)
            try GitWorkspaceError.require(edits.allSatisfy { $0.code.last == " " }, "冲突处理后仍有未暂存或未跟踪的更改。")
            let staged = try runner.run(task.path, ["write-tree"]).line()
            try ensureSafeTree(staged, in: task.path)
            _ = try runner.run(task.path, ["commit","--no-gpg-sign","-m","Resolve Agent Hub integration conflict"])
            let head = try oid(task.path)
            try ensureAncestry(incoming, head, in: task.path)
            try ensureAncestry(old, head, in: task.path)
            return head
        }
    }

    private func conflictPaths(_ cwd: URL) throws -> [String] {
        try runner.run(cwd, ["diff","--name-only","--diff-filter=U","-z","--"]).fields()
    }

    private func mergeHead(_ cwd: URL) throws -> String? {
        let result = try runner.run(cwd, ["rev-parse","--verify","--quiet","MERGE_HEAD"], check: false)
        if result.status == 1 { return nil }
        return try result.checked().line()
    }

    /// Explicit local adoption is fast-forward only. A changed branch, a dirty
    /// source, and divergent work all keep the result on its reviewable branch.
    public func adopt(task: GitWorkspace, expectedTaskHead: String, expectedSourceHead: String) throws -> String {
        try locked {
            try check(task, kind: .task)
            let source = task.project.path
            let result = try validatedOID(expectedTaskHead)
            let target = try validatedOID(expectedSourceHead)
            try GitWorkspaceError.require(target == task.project.head && task.project.branch != nil,
                                          "要采用任务结果，请使用原项目分支及已审查的基线提交。")
            try checkIdle(task.path)
            try checkIdle(source)
            try checkIndexFlags(source)
            try checkIndexFlags(task.path)
            try GitWorkspaceError.require(try oid(task.path) == result && changes(task.path).isEmpty,
                                          "任务结果已变化。请重新保存检查点并验证。")
            try ensureAncestry(target, result, in: source)
            try ensureSafeTree(result, in: source)
            try GitWorkspaceError.require(try branch(source) == task.project.branch && oid(source) == target,
                                          "原项目分支已变化。请检查任务分支或导出补丁。")
            try GitWorkspaceError.require(try changes(source).isEmpty, "原项目有本地更改。请先保存这些更改，再采用任务结果。")
            _ = try runner.run(source, ["merge","--ff-only","--no-overwrite-ignore","--no-autostash",
                                       "--no-edit","--no-stat",result])
            try GitWorkspaceError.require(try branch(source) == task.project.branch && oid(source) == result,
                                          "采用任务结果时原项目发生了变化。请检查原项目分支和任务分支。")
            return result
        }
    }

    /// Removes only a clean, already adopted worktree. Its branch and commits
    /// remain. Ignored files are included in the cleanliness check.
    public func removeWorkspace(_ workspace: GitWorkspace, expectedHead: String) throws {
        try locked {
            let head = try validatedOID(expectedHead)
            guard var record = try registration(workspace.id), record.workspace == workspace else {
                throw GitWorkspaceError.operation("找不到已登记的工作区。")
            }
            if record.removed && record.removalHead == head { return }
            var pathStat = stat()
            if record.removalHead == head && lstat(workspace.path.path, &pathStat) != 0 && errno == ENOENT {
                try GitWorkspaceError.require(try DirectoryIdentity(workspace.project.path) == record.source
                    && DirectoryIdentity(commonDirectory(workspace.project.path)) == record.common,
                    "清理过程中原仓库被移动。")
                let ref = try runner.run(workspace.project.path, ["rev-parse","--verify","refs/heads/" + workspace.branch]).line()
                try ensureAncestry(head, ref, in: workspace.project.path)
                record.removed = true
                try save(record)
                return
            }
            try check(workspace)
            try checkIdle(workspace.path)
            try checkIndexFlags(workspace.path)
            try GitWorkspaceError.require(try oid(workspace.path) == head
                && changes(workspace.path, includeIgnored: true).isEmpty, "工作区已变化，或包含清理时会被删除的文件。请先检查其内容。")
            if workspace.kind == .attempt, let task = try registration(workspace.taskID), !task.removed {
                let integrated = try restoreRegistration(task)
                try ensureAncestry(head, oid(integrated.path), in: workspace.path)
            } else {
                let source = workspace.project.path
                try GitWorkspaceError.require(try branch(source) == workspace.project.branch,
                                              "原项目分支已变化。请保留工作树，直至确认任务结果已采用。")
                try ensureAncestry(head, oid(source), in: source)
            }
            record.removalHead = head
            try save(record)
            _ = try runner.run(workspace.project.path, ["worktree","remove","--",workspace.path.path])
            record.removed = true
            try save(record)
        }
    }
}
