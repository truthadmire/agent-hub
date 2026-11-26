import Foundation
import CryptoKit

extension GitWorkspaceService {
    private func locationReceipt(_ location: URL) -> URL {
        let key = SHA256.hash(data: Data(location.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return records.appendingPathComponent("origin-" + key + ".json")
    }

    func rememberOrigin(_ project: GitProject) throws {
        let location = locationReceipt(project.path)
        if fm.fileExists(atPath: location.path), try String(contentsOf: location, encoding: .utf8) == project.id { return }
        try Data(project.id.utf8).write(to: location, options: .atomic)
    }

    /// Reconnects a moved repository on the same volume. Registered linked
    /// worktrees must still match their saved directory and branch identities.
    public func relocateProject(from original: URL, to destination: URL, expectedCommit: String) throws -> GitProject {
        try locked {
            let fresh = try project(at: destination)
            let original = original.standardizedFileURL
            let expected = try validatedOID(expectedCommit)
            _ = try runner.run(fresh.path, ["cat-file","-e",expected + "^{commit}"])
            if fresh.path.path == original.path {
                if fm.fileExists(atPath: locationReceipt(original).path) {
                    try GitWorkspaceError.require(try String(contentsOf: locationReceipt(original), encoding: .utf8) == fresh.id,
                                                  "原路径已被另一个仓库占用。")
                }
                return fresh
            }
            try GitWorkspaceError.require(!fm.fileExists(atPath: original.path), "原项目仍位于已记录的位置。")
            let receipt = locationReceipt(original)
            if fm.fileExists(atPath: receipt.path) {
                try GitWorkspaceError.require(try String(contentsOf: receipt, encoding: .utf8) == fresh.id,
                                              "所选目录与记录中的项目目录或 Git 目录不符。")
            }
            let items = try fm.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)
            let associated = try items.compactMap { item -> GitRegistration? in
                guard let id = UUID(uuidString: item.deletingPathExtension().lastPathComponent),
                      let rec = try registration(id), rec.workspace.project.path.path == original.path else { return nil }
                return rec
            }
            let common = try commonDirectory(fresh.path)
            var active = Set<String>()
            for rec in associated {
                let work = rec.workspace
                try GitWorkspaceError.require(rec.source == (try DirectoryIdentity(fresh.path)) &&
                    rec.common == (try DirectoryIdentity(common)), "已登记的工作区指向另一个仓库。")
                if !rec.removed {
                    try GitWorkspaceError.require(rec.directory == (try DirectoryIdentity(work.path)) &&
                        work.path.path == trees.appendingPathComponent(work.id.uuidString.lowercased()).path,
                        "已登记的工作树被移动。请保留仓库和工作树，以便手动修复 Git 关联。")
                    active.insert(work.path.path)
                }
            }
            let updated = associated.map { rec -> GitRegistration in
                let old = rec.workspace
                let p = old.project
                let origin = GitProject(id: p.id, path: fresh.path, branch: p.branch, head: p.head,
                                        changes: p.changes, technologies: p.technologies)
                let work = GitWorkspace(id: old.id, project: origin, path: old.path, branch: old.branch,
                                        baseline: old.baseline, taskID: old.taskID, kind: old.kind)
                return GitRegistration(workspace: work, source: rec.source, common: rec.common,
                                       directory: rec.directory, removed: rec.removed, removalHead: rec.removalHead)
            }
            // A user may already have repaired a repository that also has
            // unmanaged worktrees. Accept intact owned pointers without touching
            // any worktree metadata in that case.
            let needsRepair = updated.contains { !$0.removed && (try? restoreRegistration($0)) == nil }
            if needsRepair {
                let fields = try runner.run(fresh.path, ["worktree","list","--porcelain","-z"]).fields()
                func canonical(_ path: String) -> String {
                    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
                }
                let linked = Set(fields.filter { $0.hasPrefix("worktree ") }.map { canonical(String($0.dropFirst(9))) })
                    .subtracting([canonical(fresh.path.path)])
                let knownPaths = Set(active.map(canonical))
                try GitWorkspaceError.require(knownPaths == linked,
                    "还需检查其他关联工作树。请在移动后的仓库中运行 git worktree repair，再重新选择仓库。")
                for rec in associated where !rec.removed {
                    let work = rec.workspace
                    guard let idx = fields.firstIndex(where: { $0.hasPrefix("worktree ") &&
                        canonical(String($0.dropFirst(9))) == canonical(work.path.path) }) else { throw GitWorkspaceError.operation("找不到工作树记录。") }
                    let details = fields.dropFirst(idx + 1).prefix { !$0.hasPrefix("worktree ") }
                    try GitWorkspaceError.require(details.contains("branch refs/heads/" + work.branch),
                                                  "重新定位前，已登记工作树的分支发生了变化。")
                }
                _ = try runner.run(fresh.path, ["worktree","repair","--"] + active.sorted())
            }
            for record in updated {
                if !record.removed { _ = try restoreRegistration(record) }
                try save(record)
            }
            try rememberOrigin(fresh)
            return fresh
        }
    }
}
