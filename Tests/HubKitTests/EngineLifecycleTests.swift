import Foundation
import XCTest
import HubGit
import HubProviders
@testable import HubKit

final class EngineLifecycleTests: XCTestCase {
    struct Fixture {
        var root: URL
        var source: URL
        var engine: HubEngine
        var store: HubStore
        var task: HubTask
    }

    private func fixture(script: String, configure: (inout HubConfiguration) -> Void = { _ in },
                         acceptance: [String] = []) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-engine-\(UUID())")
        let work = root.appendingPathComponent("work")
        let source = root.appendingPathComponent("original")
        let cli = root.appendingPathComponent("codex-fixture")
        let git = try GitWorkspaceService(managedRoot: work)
        _ = try git.initializeProject(at: source)
        let store = try HubStore(directory: root.appendingPathComponent("db"))
        let p = HubProject(name: "Fixture",path: source.path)
        try store.saveProject(p)
        var cfg = HubConfiguration()
        cfg.verificationCommands = [["/bin/test","-f","result.txt"]]
        cfg.enabledRoles = ["lead"]
        configure(&cfg)
        let task = try store.createTask(.init(projectID:p.id,title:"Write result",goal:"Write result.txt.",acceptance:acceptance,overrides:cfg))
        try Data(("#!/bin/sh\nset -eu\n" + script).utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath: cli.path)
        return Fixture(root:root,source:source,engine:HubEngine(store:store,workspaceRoot:work,availableExecutables:["codex":cli]),store:store,task:task)
    }

    private let writes = #"""
    prompt=$(cat)
    printf '%s\n' '{"type":"thread.started","thread_id":"ac013e45-bf70-40ee-b91a-1aaea3ee3dd1"}'
    sleep 0.35
    case "$prompt" in
      *FOLLOWUP_REQUEST*) printf 'amended\n' > result.txt ;;
      *) printf 'initial\n' > result.txt ;;
    esac
    printf '%s\n' '{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"Produced result.txt."}}' '{"type":"turn.completed","usage":{"input_tokens":4,"output_tokens":2}}'
    """#

    private func wait(_ f: Fixture, until predicate: (HubTask) -> Bool) async throws -> HubTask {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            let t = try f.store.task(f.task.id)
            if predicate(t) { return t }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let last = try f.store.task(f.task.id)
        throw NSError(domain:"EngineTestTimeout", code:1, userInfo:[NSLocalizedDescriptionKey:"\(last.state) / \(last.phase) / \(last.attentionReason ?? "") / \(last.summary)"])
    }

    func testInputDuringOnlyAttemptGetsNewTurnBeforeCompletion() async throws {
        let f = try fixture(script:writes)
        defer { try? FileManager.default.removeItem(at:f.root) }
        try await f.engine.start(f.task.id)
        _ = try await wait(f) { $0.attempts.first?.state == .running }
        let msg = HubMessage(taskID:f.task.id,sender:"user",recipient:"task",text:"FOLLOWUP_REQUEST",requirementRevision:1)
        try f.store.saveMessage(msg)
        let result = try await wait(f) { [.completed,.needsUser].contains($0.state) }
        XCTAssertEqual(result.state,.completed,result.summary)
        XCTAssertEqual(result.attempts.count,2)
        let committedAnswers = try f.store.messages(taskID:f.task.id).filter { $0.sender == "lead" && $0.recipient == "user" }
        XCTAssertEqual(committedAnswers.compactMap(\.attemptID), result.attempts.map(\.id))
        XCTAssertTrue(committedAnswers.allSatisfy { $0.finalStreamGroup?.hasPrefix("text/") == true })
        XCTAssertTrue(try f.store.events(taskID:f.task.id).contains { $0.providerEventType == "item.completed" })
        XCTAssertEqual(try f.store.messages(taskID:f.task.id).first(where: { $0.id == msg.id })?.delivery,.processed)
        let taskPath = try XCTUnwrap(result.workspace?.path)
        XCTAssertEqual(try String(contentsOfFile:taskPath+"/result.txt"),"amended\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.source.appendingPathComponent("result.txt").path))
        XCTAssertTrue(result.verifications.contains { $0.state == .passed && $0.snapshot == result.workspace?.snapshot })
    }

    func testRetriesUseOnePersistentBudgetAndNeverCompleteFromExitAlone() async throws {
        let script = #"""
        cat >/dev/null
        printf '%s\n' '{"type":"turn.failed","error":{"message":"network connection timeout"}}'
        exit 1
        """#
        let f = try fixture(script:script) { $0.maxRetries = 1 }
        defer { try? FileManager.default.removeItem(at:f.root) }
        try await f.engine.start(f.task.id)
        let result = try await wait(f) { $0.state == .needsUser }
        XCTAssertEqual(result.retryCount,1)
        XCTAssertEqual(result.attempts.count,2,result.summary)
        XCTAssertFalse(result.attempts.contains { $0.state == .succeeded })
    }

    func testCancelLeavesPartialEvidenceAndDoesNotLaunchNextTurn() async throws {
        let f = try fixture(script:writes)
        defer { try? FileManager.default.removeItem(at:f.root) }
        try await f.engine.start(f.task.id)
        _ = try await wait(f) { $0.attempts.first?.state == .running }
        _ = try await wait(f) { $0.attempts.first?.providerSessionID != nil }
        try await f.engine.cancel(f.task.id)
        let result = try f.store.task(f.task.id)
        XCTAssertEqual(result.state,.cancelled)
        XCTAssertEqual(result.attempts.count,1)
        XCTAssertEqual(result.attempts.first?.state,.cancelled)
        XCTAssertTrue(result.artifacts.isEmpty)
        try await f.engine.start(f.task.id)
        XCTAssertEqual(try f.store.task(f.task.id).state,.cancelled)
    }

    func testManualAcceptanceRequiresActualCurrentSnapshotAndEvidence() async throws {
        let f = try fixture(script:writes,acceptance:["Read and approve the output"])
        defer { try? FileManager.default.removeItem(at:f.root) }
        try await f.engine.start(f.task.id)
        let waiting = try await wait(f) { $0.state == .needsUser }
        let check = try XCTUnwrap(waiting.verifications.first { $0.actor == "manual" })
        XCTAssertEqual(check.snapshot, waiting.workspace?.snapshot)
        try await f.engine.recordHumanCheck(f.task.id,verificationID:check.id,reason:"Reviewed result.txt")
        let done = try await wait(f) { $0.state == .completed }
        XCTAssertTrue(done.verifications.contains { $0.reason == "Reviewed result.txt" && $0.state == .passed })
        XCTAssertEqual(done.attempts.count,1)
    }
    func testRevisedRequirementRejectsLateAttemptAndPreservesOriginal() async throws {
        let script = #"""
        prompt=$(cat)
        case "$prompt" in
          *NEW_REQUIREMENT*) printf 'new\n' > result.txt ;;
          *) printf 'old\n' > obsolete.txt; sleep 15 ;;
        esac
        printf '%s\n' '{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"Saved."}}' '{"type":"turn.completed"}'
        """#
        let f = try fixture(script:script)
        defer { try? FileManager.default.removeItem(at:f.root) }
        try await f.engine.start(f.task.id)
        _ = try await wait(f) { task in
            guard let path = task.attempts.first?.workspace?.path else { return false }
            return FileManager.default.fileExists(atPath:path+"/obsolete.txt")
        }
        try await f.engine.changeRequirements(f.task.id,goal:"NEW_REQUIREMENT: create result.txt",acceptance:[])
        let final = try await wait(f) { [.needsUser,.completed].contains($0.state) }
        XCTAssertEqual(final.state,.completed,final.summary)
        XCTAssertEqual(final.requirementRevision,2)
        XCTAssertEqual(final.attempts.first?.state,.interrupted)
        XCTAssertNil(final.attempts.first?.integratedCommit)
        let path = try XCTUnwrap(final.workspace?.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path+"/obsolete.txt"))
        XCTAssertEqual(try String(contentsOfFile:path+"/result.txt"),"new\n")
        XCTAssertEqual(try f.store.requirementHistory(taskID:f.task.id).count,2)
    }

    func testExplicitReverificationBindsChecksToEditedDeliveryCommit() async throws {
        let f = try fixture(script:writes)
        defer { try? FileManager.default.removeItem(at:f.root) }
        try await f.engine.start(f.task.id)
        let first = try await wait(f) { $0.state == .completed }
        let path = try XCTUnwrap(first.workspace?.path)
        try Data("user reviewed change".utf8).write(to:URL(fileURLWithPath:path+"/result.txt"))
        try await f.engine.reverify(f.task.id)
        let second = try await wait(f) { $0.state == .completed }
        XCTAssertNotEqual(first.workspace?.snapshot,second.workspace?.snapshot)
        XCTAssertTrue(second.verifications.contains { $0.state == .passed && $0.snapshot == second.workspace?.snapshot })
        XCTAssertTrue(second.verifications.contains { $0.state == .passed && $0.snapshot == first.workspace?.snapshot })
        XCTAssertEqual(second.attempts.count,1)
    }

    func testIdenticalFailedCheckAndUnchangedRepairStopEarly() async throws {
        let f = try fixture(script:writes,configure:{ $0.verificationCommands = [["/usr/bin/grep","wanted","result.txt"]] })
        defer { try? FileManager.default.removeItem(at:f.root) }
        try await f.engine.start(f.task.id)
        let result = try await wait(f) { $0.state == .needsUser }
        XCTAssertEqual(result.attentionReason,"no_progress",result.summary)
        XCTAssertEqual(result.repairCount,1)
        XCTAssertEqual(result.attempts.count,2)
        XCTAssertEqual(result.verifications.filter { $0.required && $0.state == .failed }.count,2)
    }
}
