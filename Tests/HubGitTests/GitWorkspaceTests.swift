import XCTest
import Foundation
@testable import HubGit

private final class Fixture {
    let root: URL
    let source: URL
    let managed: URL
    let service: GitWorkspaceService
    let fm = FileManager.default

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Hub Git 中文 " + UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("项目 空格 [v1]", isDirectory: true)
        managed = root.appendingPathComponent("Managed", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        service = try GitWorkspaceService(managedRoot: managed)
        _ = try service.initializeProject(at: source)
        try write("base\n", to: "shared.txt", at: source)
        try write("rename me\n", to: "before.txt", at: source)
        try write("delete me\n", to: "gone.txt", at: source)
        try write(".env\ncache/\n*.ignored\n", to: ".gitignore", at: source)
        _ = try git(source, ["add", "."])
        _ = try git(source, ["commit","-m","Baseline"])
    }
    deinit { try? fm.removeItem(at: root) }

    func write(_ str: String, to file: String, at cwd: URL) throws {
        try Data(str.utf8).write(to: cwd.appendingPathComponent(file))
    }

    func str(_ filename: String, at cwd: URL) throws -> String {
        try String(contentsOf: cwd.appendingPathComponent(filename), encoding: .utf8)
    }

    @discardableResult func git(_ cwd: URL, _ args: [String]) throws -> String {
        let proc = Process(), pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.currentDirectoryURL = cwd
        proc.arguments = ["-c","core.hooksPath=/dev/null","-c","user.name=Test","-c","user.email=test@localhost",
                          "-c","commit.gpgSign=false"] + args
        proc.environment = ["PATH":"/usr/bin:/bin","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_NOSYSTEM":"1","LC_ALL":"C"]
        proc.standardOutput = pipe; proc.standardError = pipe
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard proc.terminationStatus == 0 else { throw GitWorkspaceError.operation(out) }
        return out
    }

    func task() throws -> GitWorkspace {
        try service.createTask(project: service.inspectProject(at: source), id: UUID())
    }
}

final class GitWorkspaceTests: XCTestCase {
    func testDirtySourceIndexBytesAndInspectableSnapshot() throws {
        let f = try Fixture(), s = f.service
        try f.write("staged\n",to:"shared.txt",at:f.source)
        try f.git(f.source, ["add","shared.txt"])
        try f.write("working\n",to:"shared.txt",at:f.source)
        try f.git(f.source, ["mv","before.txt","改名 [new].txt"])
        try f.fm.removeItem(at: f.source.appendingPathComponent("gone.txt"))
        let bytes = Data([0,255,1,0,33])
        try bytes.write(to: f.source.appendingPathComponent("bin file"))
        try f.write("ignored", to:".env",at:f.source)
        try f.write("redacted token", to:".env.local",at:f.source)
        try f.write("staged ignored", to:"force.ignored",at:f.source)
        try f.git(f.source, ["add","-f","force.ignored"])
        let index = f.source.appendingPathComponent(".git/index")
        let originalIndex = try Data(contentsOf: index)
        let p = try s.inspectProject(at: f.source)
        XCTAssertTrue(p.changes.contains { $0.code == "MM" && $0.path == "shared.txt" })
        let task = try s.createTask(project:p, id:UUID())
        XCTAssertEqual(task.baseline, p.head)
        XCTAssertEqual(try f.str("shared.txt",at:task.path), "base\n")
        XCTAssertFalse(f.fm.fileExists(atPath: task.path.appendingPathComponent("bin file").path))
        let preview = try s.previewUncommitted(in:p)
        XCTAssertTrue(String(decoding:preview.patch,as:UTF8.self).contains("GIT binary patch"))
        XCTAssertTrue(preview.excludedPaths.contains(".env.local"))
        XCTAssertFalse(String(decoding:preview.patch,as:UTF8.self).contains("redacted token"))
        let snap = try s.createTask(project:p, id:UUID(), includeUncommitted:true, expectedSnapshotID:preview.tree)
        XCTAssertEqual(try s.createTask(project:p, id:snap.id, includeUncommitted:true, expectedSnapshotID:preview.tree),snap)
        XCTAssertNotEqual(snap.baseline, p.head)
        XCTAssertEqual(try s.snapshotID(of:snap),preview.tree)
        XCTAssertEqual(try f.str("shared.txt",at:snap.path),"working\n")
        XCTAssertEqual(try f.str("改名 [new].txt",at:snap.path),"rename me\n")
        XCTAssertEqual(try f.str("force.ignored",at:snap.path),"staged ignored")
        XCTAssertEqual(try Data(contentsOf:snap.path.appendingPathComponent("bin file")),bytes)
        for path in ["gone.txt","before.txt",".env",".env.local"] {
            XCTAssertFalse(f.fm.fileExists(atPath:snap.path.appendingPathComponent(path).path))
        }
        XCTAssertEqual(try Data(contentsOf:index),originalIndex)
        try f.write("late edit",to:"shared.txt",at:f.source)
        XCTAssertThrowsError(try s.createTask(project:p,id:UUID(),includeUncommitted:true,expectedSnapshotID:preview.tree))
        XCTAssertEqual(try f.str("shared.txt",at:f.source),"late edit")
        XCTAssertEqual(try Data(contentsOf:index),originalIndex)
    }

    func testParallelBranchesConflictRestartResolutionAndAdoption() throws {
        let f = try Fixture(), s = f.service, task = try f.task()
        let a = try s.createAttempt(task:task,id:UUID())
        let b = try s.createAttempt(task:task,id:UUID())
        try f.write("worker A\n",to:"shared.txt",at:a.path)
        try f.write("worker B\n",to:"shared.txt",at:b.path)
        let ha = try s.checkpoint(a,message:"worker A")
        let hb = try s.checkpoint(b,message:"worker B")
        XCTAssertEqual(try s.integrate(attempt:a,into:task,expectedAttemptHead:ha,expectedTaskHead:task.baseline),.integrated(ha))
        XCTAssertThrowsError(try s.integrate(attempt:b,into:task,expectedAttemptHead:hb,expectedTaskHead:task.baseline))
        XCTAssertEqual(try s.integrate(attempt:b,into:task,expectedAttemptHead:hb,expectedTaskHead:ha),.conflict(["shared.txt"]))
        let restored = try GitWorkspaceService(managedRoot:f.managed)
        XCTAssertEqual(try restored.workspace(id:task.id),task)
        XCTAssertEqual(try restored.head(of:a),ha)
        XCTAssertEqual(try restored.head(of:b),hb)
        XCTAssertEqual(try f.str("shared.txt",at:f.source),"base\n")
        XCTAssertThrowsError(try restored.finishConflict(in:task,expectedTaskHead:ha,expectedAttemptHead:hb))
        try f.write("reviewed A + B\n",to:"shared.txt",at:task.path)
        try f.git(task.path,["add","shared.txt"])
        let final = try restored.finishConflict(in:task,expectedTaskHead:ha,expectedAttemptHead:hb)
        XCTAssertTrue(try restored.hasIntegrated(attempt:b,into:task,expectedAttemptHead:hb,previousTaskHead:ha))
        XCTAssertEqual(try restored.changedPaths(of:task),["shared.txt"])
        let patch = f.root.appendingPathComponent("成果 文件.patch")
        XCTAssertThrowsError(try restored.exportPatch(of:task,to:patch,expectedHead:ha))
        try restored.exportPatch(of:task,to:patch,expectedHead:final)
        XCTAssertThrowsError(try restored.exportPatch(of:task,to:patch))
        XCTAssertEqual(try Data(contentsOf:patch),try restored.diff(of:task))
        XCTAssertEqual(try restored.adopt(task:task,expectedTaskHead:final,expectedSourceHead:task.project.head),final)
        XCTAssertEqual(try f.str("shared.txt",at:f.source),"reviewed A + B\n")
        try restored.removeWorkspace(b,expectedHead:hb)
        try restored.removeWorkspace(b,expectedHead:hb)
        XCTAssertEqual(try f.git(f.source,["rev-parse",b.branch]),hb)
        XCTAssertThrowsError(try restored.workspace(id:b.id))
    }

    func testChangedSourceLateAttemptAndCleanup() throws {
        let f = try Fixture(), s = f.service, task = try f.task()
        let attempt = try s.createAttempt(task:task,id:UUID())
        try f.write("first",to:"out.txt",at:attempt.path)
        let old = try s.checkpoint(attempt,message:"worker checkpoint")
        try f.write("second",to:"out.txt",at:attempt.path)
        XCTAssertThrowsError(try s.integrate(attempt:attempt,into:task,expectedAttemptHead:old,expectedTaskHead:task.baseline))
        let current = try s.checkpoint(attempt,message:"updated worker checkpoint")
        XCTAssertThrowsError(try s.integrate(attempt:attempt,into:task,expectedAttemptHead:old,expectedTaskHead:task.baseline))
        XCTAssertThrowsError(try s.removeWorkspace(attempt,expectedHead:current))
        let handoff = try s.createAttempt(task:task,id:UUID(),continuing:attempt,expectedHead:current)
        XCTAssertEqual(handoff.baseline,current)
        XCTAssertEqual(try f.str("out.txt",at:handoff.path),"second")
        _ = try s.integrate(attempt:attempt,into:task,expectedAttemptHead:current,expectedTaskHead:task.baseline)
        try f.write("ignored local",to:"new.ignored",at:attempt.path)
        XCTAssertThrowsError(try s.removeWorkspace(attempt,expectedHead:current))
        try f.write("external",to:"shared.txt",at:f.source)
        XCTAssertThrowsError(try s.adopt(task:task,expectedTaskHead:current,expectedSourceHead:task.project.head))
        try f.git(f.source,["add","shared.txt"])
        try f.git(f.source,["commit","-m","external"])
        XCTAssertThrowsError(try s.adopt(task:task,expectedTaskHead:current,expectedSourceHead:task.project.head))
        XCTAssertFalse(f.fm.fileExists(atPath:f.source.appendingPathComponent("out.txt").path))
        XCTAssertEqual(try f.str("shared.txt",at:f.source),"external")
    }

    func testCleanupRejectsReplacedDirectoryAndConfigurationDrivers() throws {
        let f = try Fixture(), s = f.service, task = try f.task()
        let attempt = try s.createAttempt(task:task,id:UUID())
        let original = f.root.appendingPathComponent("quarantined")
        try f.fm.moveItem(at:attempt.path,to:original)
        try f.fm.createSymbolicLink(at:attempt.path,withDestinationURL:f.source)
        XCTAssertThrowsError(try s.removeWorkspace(attempt,expectedHead:attempt.baseline))
        XCTAssertEqual(try f.str("shared.txt",at:f.source),"base\n")
        XCTAssertTrue(f.fm.fileExists(atPath:original.appendingPathComponent("shared.txt").path))
        try f.git(f.source,["config","filter.untrusted.clean","false"])
        XCTAssertThrowsError(try s.inspectProject(at:f.source))
    }

    func testCheckoutHooksProtectedFilesAndIgnoredCollision() throws {
        let f = try Fixture(), s = f.service
        let hooks = f.root.appendingPathComponent("hooks",isDirectory:true)
        try f.fm.createDirectory(at:hooks,withIntermediateDirectories:true)
        let hook = hooks.appendingPathComponent("post-checkout")
        try f.write("#!/bin/sh\ntouch \"$PWD/hook-ran\"\n",to:"post-checkout",at:hooks)
        try f.fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        try f.git(f.source,["config","core.hooksPath",hooks.path])
        let task = try f.task()
        XCTAssertFalse(f.fm.fileExists(atPath:task.path.appendingPathComponent("hook-ran").path))
        try f.write("protected",to:".env.local",at:task.path)
        XCTAssertThrowsError(try s.checkpoint(task,message:"deny protected file"))
        try f.fm.removeItem(at:task.path.appendingPathComponent(".env.local"))
        try f.write("worker payload",to:"cache.ignored",at:task.path)
        try f.git(task.path,["add","-f","cache.ignored"])
        let head = try s.checkpoint(task,message:"Add reviewed artifact")
        try f.write("user local cache",to:"cache.ignored",at:f.source)
        XCTAssertThrowsError(try s.adopt(task:task,expectedTaskHead:head,expectedSourceHead:task.project.head))
        XCTAssertEqual(try f.str("cache.ignored",at:f.source),"user local cache")
        XCTAssertEqual(try f.git(f.source,["rev-parse","HEAD"]),task.project.head)
    }

    func testConcurrentIntegrationsHaveOneWinnerForReviewedHead() throws {
        let f = try Fixture(), s = f.service, task = try f.task()
        var sources = [(GitWorkspace, String)]()
        for name in ["first", "second"] {
            let work = try s.createAttempt(task:task,id:UUID())
            try f.write(name,to:name,at:work.path)
            sources.append((work,try s.checkpoint(work,message:name)))
        }
        let attempts = sources
        let other = try GitWorkspaceService(managedRoot:f.managed)
        let services = [s,other]
        let group = DispatchGroup()
        let lock = NSLock()
        final class Outcomes: @unchecked Sendable { var successes = [String](); var errors = [Error]() }
        let outcomes = Outcomes()
        for index in attempts.indices {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let (work,head) = attempts[index]
                do {
                    let result = try services[index].integrate(attempt:work,into:task,expectedAttemptHead:head,
                                                               expectedTaskHead:task.baseline)
                    if case let .integrated(actual) = result {
                        lock.lock(); outcomes.successes.append(actual); lock.unlock()
                    }
                } catch {
                    lock.lock(); outcomes.errors.append(error); lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout:.now() + 30),.success)
        XCTAssertEqual(outcomes.errors.count,1)
        XCTAssertEqual(outcomes.successes,[try s.head(of:task)])
        XCTAssertEqual(try f.git(f.source,["rev-parse","HEAD"]),task.project.head)
    }

    func testMovedSourceRepairsOnlyOwnedWorktrees() throws {
        let f = try Fixture(), s = f.service, task = try f.task()
        let attempt = try s.createAttempt(task:task,id:UUID())
        let moved = f.root.appendingPathComponent("moved 中文",isDirectory:true)
        let external = f.root.appendingPathComponent("external-worktree",isDirectory:true)
        try f.git(f.source,["worktree","add","-b","external",external.path])
        try f.fm.moveItem(at:f.source,to:moved)
        XCTAssertThrowsError(try s.relocateProject(from:f.source,to:moved,expectedCommit:task.project.head))
        try f.git(moved,["worktree","repair"])
        XCTAssertThrowsError(try s.workspace(id:task.id))
        let project = try s.relocateProject(from:f.source,to:moved,expectedCommit:task.project.head)
        XCTAssertEqual(project.id,task.project.id)
        XCTAssertEqual(try s.workspace(id:task.id).project.path.path,moved.path)
        XCTAssertEqual(try s.workspace(id:attempt.id).project.path.path,moved.path)
    }
}
