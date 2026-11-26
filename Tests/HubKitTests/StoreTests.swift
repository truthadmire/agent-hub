import CSQLite
import Foundation
import XCTest
@testable import HubKit

final class StoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hub-store-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func seed(_ store: HubStore) throws -> HubTask {
        let project = HubProject(name: "示例工程", path: directory.appendingPathComponent("项目 with spaces").path)
        try store.saveProject(project)
        return try store.createTask(HubTask(projectID: project.id, title: "修复", goal: "解决跨模块问题"))
    }

    private func executeDatabaseSQL(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(directory.appendingPathComponent("agent-hub.sqlite3").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK
        else { throw HubStoreError.database("test SQLite open failed") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HubStoreError.database(String(cString: sqlite3_errmsg(db))) }
    }

    func testCommitRollbackAndConcurrentIdempotentRequest() throws {
        let store = try HubStore(directory: directory)
        let task = try seed(store)
        XCTAssertThrowsError(try HubStore(directory: directory))
        XCTAssertThrowsError(try store.updateTask(task.id, kind: "bad", requestID: "rollback") { value in
            value.title = "rolled back"
            throw HubStoreError.invalid("fixture")
        })
        XCTAssertEqual(try store.task(task.id).title, task.title)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do { _ = try store.updateTask(task.id, kind: "dispatch", requestID: "shared") { $0.retryCount += 1 } }
            catch { XCTFail("Concurrent transaction failed: \(error)") }
        }
        XCTAssertEqual(try store.task(task.id).retryCount, 1)
        XCTAssertEqual(try store.events(taskID: task.id).map(\.kind), ["task.created", "dispatch"])
        XCTAssertThrowsError(try store.updateTask(task.id, kind: "another", requestID: "shared") { $0.retryCount += 50 })
        XCTAssertThrowsError(try store.createTask(HubTask(projectID: "missing", title: "a", goal: "b")))
    }

    func testSnapshotInheritanceAcrossReopenAndProviderSwitch() throws {
        var store: HubStore? = try HubStore(directory: directory)
        let task = try seed(store!)
        var base = HubConfiguration.balanced
        base.models["lead"] = "initial-model"
        base.maxSeconds = 90
        try store!.saveGlobalConfiguration(base)
        var project = try store!.project(task.projectID)
        project.configuration.roles["lead"] = .antigravity
        project.configuration.maxRepairs = 3
        try store!.saveProject(project)
        let started = try store!.updateTask(task.id, kind: "dispatch") {
            $0.overrides.maxAttempts = 2
            $0.state = .running
        }
        XCTAssertEqual(started.runtimeConfig?.roles["lead"], .antigravity)
        XCTAssertNil(started.runtimeConfig?.models["lead"])
        XCTAssertEqual(started.runtimeConfig?.maxRepairs, 3)
        XCTAssertEqual(started.runtimeConfig?.maxAttempts, 2)
        base.maxSeconds = 180
        try store!.saveGlobalConfiguration(base)
        store = nil
        let reopened = try HubStore(directory: directory)
        let resumed = try reopened.task(task.id)
        XCTAssertEqual(try reopened.effectiveConfiguration(for: resumed).maxSeconds, 90)
        XCTAssertEqual(try reopened.globalConfiguration().maxSeconds, 180)
    }

    func testRecoveryPreservesResultsAndPreventsCancelledResurrection() throws {
        var store: HubStore? = try HubStore(directory: directory)
        let task = try seed(store!)
        let attempt = HubAttempt(itemID: "backend", provider: .codex, role: "backend", requirementRevision: 1, planRevision: 1, generation: 1)
        var item = WorkItem(id: "backend", title: "待恢复的执行", role: "backend", provider: .codex)
        item.state = .running
        var delivered = WorkItem(id: "docs", title: "已交付", role: "test", provider: .dsh)
        delivered.state = .delivered
        _ = try store!.updateTask(task.id, kind: "attempt.intent") {
            $0.planRevision = 1
            $0.plan = PlanRevision(revision: 1, requirementRevision: 1, goal: task.goal, items: [item, delivered])
            $0.generation = 1
            $0.state = .running
            $0.attempts.append(attempt)
            $0.artifacts.append(HubArtifact(kind: "report", title: "实际 diff", path: "reports/diff.patch"))
        }
        store = nil
        let reopened = try HubStore(directory: directory)
        XCTAssertEqual(try reopened.recoverInterrupted(), [task.id])
        XCTAssertEqual(try reopened.recoverInterrupted(), [])
        let saved = try reopened.task(task.id)
        XCTAssertEqual(saved.state, .needsUser)
        XCTAssertEqual(saved.attentionReason, "resume_required")
        XCTAssertEqual(saved.generation, 2)
        XCTAssertEqual(saved.plan?.items.map(\.state), [.pending, .delivered])
        XCTAssertEqual(saved.attempts.first?.state, .interrupted)
        XCTAssertEqual(saved.artifacts.first?.path, "reports/diff.patch")
        XCTAssertNil(saved.runningSince)
        _ = try reopened.updateTask(task.id, kind: "cancel") { $0.state = .cancelled; $0.generation += 1 }
        XCTAssertThrowsError(try reopened.updateTask(task.id, kind: "late") { $0.state = .completed })
        try reopened.appendEvent(taskID: task.id, kind: "late.text", detail: "late", attemptID: attempt.id)
        let late = try XCTUnwrap(reopened.recentEvents(taskID: task.id, attemptID: attempt.id).last)
        XCTAssertEqual(late.generation, 1)
        XCTAssertEqual(try reopened.task(task.id).state, .cancelled)
    }

    func testDraftQueueReplayAndConversationPages() throws {
        var store: HubStore? = try HubStore(directory: directory)
        let task = try seed(store!)
        try store!.saveDraft(taskID: task.id, recipient: "frontend", text: "请使用红色")
        try store!.saveDraft(taskID: task.id, recipient: "backend", text: "API remains v1")
        let first = HubMessage(taskID: task.id, sender: "user", recipient: "frontend", text: "请使用红色", requirementRevision: 1)
        try store!.saveMessage(first, clearDraft: true)
        XCTAssertEqual(try store!.draft(taskID: task.id, recipient: "frontend"), "")
        try store!.saveDraft(taskID: task.id, recipient: "frontend", text: "follow up")
        try store!.saveMessage(first, clearDraft: true)
        try store!.setDelivery(messageID: first.id, to: .delivered)
        try store!.setDelivery(messageID: first.id, to: .queued)
        let reply = HubMessage(taskID: task.id, sender: "frontend", recipient: "user", text: "完成", requirementRevision: 1)
        try store!.saveMessage(reply)
        store = nil
        let reopened = try HubStore(directory: directory)
        XCTAssertEqual(try reopened.draft(taskID: task.id, recipient: "backend"), "API remains v1")
        XCTAssertEqual(try reopened.draft(taskID: task.id, recipient: "frontend"), "follow up")
        let latest = try XCTUnwrap(reopened.recentConversation(taskID: task.id, role: "frontend", limit: 1).first)
        XCTAssertEqual(latest.id, reply.id)
        let earlier = try reopened.recentConversation(taskID: task.id, role: "frontend", before: latest.sequence, limit: 1)
        XCTAssertEqual(earlier.first?.delivery, .delivered)
        XCTAssertEqual(try reopened.messages(taskID: task.id, after: earlier[0].sequence).map(\.id), [reply.id])
    }

    func testEventPagingRedactionAndCapturedRevision() throws {
        let store = try HubStore(directory: directory)
        let task = try seed(store)
        let attempt = HubAttempt(itemID: "A", provider: .codex, role: "lead", requirementRevision: 1, planRevision: 1, generation: 1)
        _ = try store.updateTask(task.id, kind: "new.plan") {
            $0.attempts.append(attempt)
            $0.requirementRevision = 2
            $0.generation = 2
            $0.goal = "revised"
            $0.planRevision = 2
            $0.plan = PlanRevision(revision: 2, requirementRevision: 2, goal: "revised", items: [])
        }
        for index in 0..<5 {
            try store.appendEvent(taskID: task.id, kind: "tool", detail: "token=synthetic_fixture_value \(index)", attemptID: attempt.id,
                                  eventID: "event-\(index)")
        }
        try store.appendEvent(taskID: task.id, kind: "tool", detail: "duplicate", attemptID: attempt.id, eventID: "event-3")
        let latest = try store.recentRoleEvents(taskID: task.id, attemptIDs: [attempt.id], includeTaskEvents: false, limit: 2)
        XCTAssertEqual(latest.map(\.id), ["event-3", "event-4"])
        XCTAssertEqual(latest.map(\.requirementRevision), [1, 1])
        XCTAssertEqual(latest.map(\.generation), [1, 1])
        XCTAssertTrue(latest.allSatisfy { !$0.detail.contains("synthetic_fixture_value") })
        XCTAssertEqual(try store.recentEvents(taskID: task.id, before: latest[0].sequence, limit: 2).map(\.id), ["event-1", "event-2"])
        XCTAssertEqual(try store.requirementHistory(taskID: task.id).map(\.revision), [1, 2])
        XCTAssertEqual(try store.planHistory(taskID: task.id).map(\.revision), [2])
        var config = HubConfiguration()
        config.commandEnvironment = ["SERVICE_ACCESS_TOKEN": "fictional"]
        XCTAssertThrowsError(try store.saveGlobalConfiguration(config))
    }

    func testRoleFeedCoalescesReceivedTextSnapshotsBeforePaging() throws {
        let store = try HubStore(directory: directory)
        let task = try seed(store)
        let attempt = UUID().uuidString
        let stream = "text/" + attempt + "/c3RyZWFt/"
        try store.appendEvent(taskID: task.id, kind: "provider.text", detail: "partial", attemptID: attempt,
                              eventID: stream + UUID().uuidString)
        try store.appendEvent(taskID: task.id, kind: "provider.tool", detail: "action", attemptID: attempt)
        try store.appendEvent(taskID: task.id, kind: "provider.text", detail: "complete", attemptID: attempt,
                              eventID: stream + UUID().uuidString)
        let message = HubMessage(taskID: task.id, sender: "user", recipient: "lead", text: "please continue", requirementRevision: 1)
        try store.saveMessage(message)
        let latest = try XCTUnwrap(store.recentRoleEvents(taskID: task.id, attemptIDs: [attempt], includeTaskEvents: true, limit: 1).first)
        XCTAssertEqual(latest.detail, "complete")
        let previous = try store.recentRoleEvents(taskID: task.id, attemptIDs: [attempt], includeTaskEvents: true, before: latest.sequence)
        XCTAssertEqual(previous.map(\.kind), ["task.created", "provider.tool"])
        XCTAssertEqual(try store.recentEvents(taskID: task.id, attemptID: attempt).count, 3)
    }

    func testBoardRefreshOnlyReturnsChangedTasksEvenWhenMessagesArrive() throws {
        let store = try HubStore(directory: directory)
        let first = try seed(store)
        let second = try store.createTask(HubTask(projectID: first.projectID, title: "second", goal: "second"))
        let cache = [first.id: first.updatedAt, second.id: second.updatedAt]
        XCTAssertTrue(try store.taskUpdates(known: cache).isEmpty)
        try store.appendEvent(taskID: first.id, kind: "provider.text", detail: "typing")
        XCTAssertTrue(try store.taskUpdates(known: cache).isEmpty)
        _ = try store.updateTask(second.id, kind: "renamed") { $0.title = "changed" }
        XCTAssertEqual(try store.taskUpdates(known: cache).map(\.id), [second.id])
    }

    func testPendingMessageGateAndIdempotentReplayAfterCompletion() throws {
        let store = try HubStore(directory: directory)
        let task = try seed(store)
        let message = HubMessage(taskID: task.id, sender: "user", recipient: "backend", text: "Review the API", requirementRevision: 1)
        try store.saveMessage(message)
        try store.setDelivery(messageID: message.id, to: .delivered)
        XCTAssertEqual(try store.pendingUserMessages(taskID: task.id, requirementRevision: 1).map(\.id), [message.id])
        try store.setDelivery(messageID: message.id, to: .processed)
        _ = try store.updateTask(task.id, kind: "fixture.completed") {
            XCTAssertTrue(try store.pendingUserMessages(taskID: $0.id, requirementRevision: 1).isEmpty)
            $0.state = .completed
        }
        try store.saveMessage(message)
        var newMessage = message
        newMessage.id = UUID().uuidString
        XCTAssertThrowsError(try store.saveMessage(newMessage))
        XCTAssertEqual(try store.task(task.id).state, .completed)
    }

    func testCLISessionsGroupOnlyWithinTheSameProvider() throws {
        let store = try HubStore(directory: directory)
        let task = try seed(store)
        var first = HubAttempt(itemID: "A", provider: .codex, role: "lead", requirementRevision: 1, planRevision: 1, generation: 1)
        first.providerSessionID = "opaque-provider-id"
        first.state = .succeeded
        var second = first
        second.id = UUID().uuidString
        var other = first
        other.id = UUID().uuidString
        other.provider = .dsh
        let saved = try store.updateTask(task.id, kind: "fixture.sessions") { $0.attempts = [first, second, other] }
        XCTAssertEqual(saved.providerSessions.count, 2)
        XCTAssertEqual(saved.providerSessions.first { $0.provider == .codex }?.attemptIDs, [first.id, second.id])
        XCTAssertEqual(saved.providerSessions.first { $0.provider == .dsh }?.attemptIDs, [other.id])
    }

    func testSparseAndUnknownConfigurationFields() throws {
        let sparse = try JSONDecoder().decode(HubConfiguration.self, from: Data(#"{"maxAttempts":3}"#.utf8))
        XCTAssertEqual(sparse.maxAttempts, 3)
        XCTAssertEqual(sparse.executableOverrides, [:])
        XCTAssertThrowsError(try JSONDecoder().decode(HubConfiguration.self, from: Data(#"{"futureOption":true}"#.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("futureOption"))
        }
    }

    func testIndexedRefreshAndBoundedStreamWithHistory() throws {
        let store = try HubStore(directory: directory)
        let active = try seed(store)
        for n in 0..<150 {
            var history = HubTask(projectID: active.projectID, title: "Task \(n)", goal: "History load fixture")
            history.summary = String(repeating: "历史记录", count: 50)
            _ = try store.createTask(history)
        }
        let known = Dictionary(uniqueKeysWithValues: try store.tasks().map { ($0.id, $0.updatedAt) })
        let reads = 20
        let beforeFull = Date()
        for _ in 0..<reads { _ = try store.tasks() }
        let fullMilliseconds = Date().timeIntervalSince(beforeFull) * 1000 / Double(reads)
        let beforeIncremental = Date()
        for _ in 0..<reads { XCTAssertTrue(try store.taskUpdates(known: known).isEmpty) }
        let indexedMilliseconds = Date().timeIntervalSince(beforeIncremental) * 1000 / Double(reads)

        for n in 0..<4_400 {
            try store.appendEvent(taskID: active.id, kind: "provider.text", detail: "chunk-\(n)")
        }
        var cursor: Int64 = 0
        var retained = 0
        while true {
            let page = try store.events(taskID: active.id, after: cursor, limit: 500)
            guard let last = page.last else { break }
            XCTAssertGreaterThan(last.sequence, cursor)
            cursor = last.sequence
            retained += page.count
        }
        XCTAssertTrue((4096...4223).contains(retained))
        XCTAssertEqual(try store.recentEvents(taskID: active.id, limit: 1).first?.detail, "chunk-4399")
        print(String(format: "Storage fixture: 151 tasks, %d stream rows retained, full %.2f ms/read, metadata %.2f ms/read",
                     retained, fullMilliseconds, indexedMilliseconds))
    }

    func testVersionMigrationBacksUpBeforeUpgradeAndFutureVersionIsReadableByItsOwner() throws {
        var store: HubStore? = try HubStore(directory: directory)
        let task = try seed(store!)
        store = nil
        try executeDatabaseSQL("DROP TABLE requirements; DROP TABLE plans; DROP TABLE event_counters; DROP INDEX tasks_change; PRAGMA user_version=1")
        store = try HubStore(directory: directory)
        XCTAssertEqual(try store!.requirementHistory(taskID: task.id).first?.goal, task.goal)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("before-v2-") })
        store = nil
        try executeDatabaseSQL("PRAGMA user_version=99")
        XCTAssertThrowsError(try HubStore(directory: directory)) { error in
            guard case HubStoreError.incompatible(99) = error else { return XCTFail("Unexpected error \(error)") }
        }
        try executeDatabaseSQL("PRAGMA user_version=2")
        let reopened = try HubStore(directory: directory)
        XCTAssertEqual(try reopened.task(task.id).goal, task.goal)
    }
}
