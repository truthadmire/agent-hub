import Foundation
import HubKit
import HubProviders
import XCTest

final class WorkflowIsolationTests: XCTestCase {
    /// A missing configured provider must surface before any model or Git worktree is created.
    func testNoConnectionPreservesTaskAndEvidenceAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-connection-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data")
        let id = try await createDisconnectedTask(root: root, data: data)
        let reopened = try HubStore(directory: data)
        let task = try reopened.task(id)
        XCTAssertEqual(task.state, .needsUser)
        XCTAssertEqual(task.attentionReason, "connection_required")
        XCTAssertTrue(task.attempts.isEmpty)
        XCTAssertNil(task.workspace)
        XCTAssertTrue(try reopened.events(taskID: id).contains { $0.kind == "task.needs_user" })
        XCTAssertEqual(task.runtimeConfig?.maxAttempts, 1)
    }

    private func createDisconnectedTask(root: URL, data: URL) async throws -> String {
        let store = try HubStore(directory: data)
        let project = HubProject(name: "Disconnected synthetic project", path: root.appendingPathComponent("unused").path)
        try store.saveProject(project)
        var config = HubConfiguration()
        config.maxAttempts = 1
        config.disabledProviders = [.antigravity, .dsh]
        let task = try store.createTask(.init(projectID: project.id, title: "Disconnected",
                                               goal: "Record the missing connection.", overrides: config))
        // An explicitly empty executable map keeps this regression test entirely offline.
        let engine = HubEngine(store: store, workspaceRoot: root.appendingPathComponent("managed"), availableExecutables: [:])
        try await engine.start(task.id)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try store.task(task.id).state == .running && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await engine.shutdown()
        return task.id
    }
}
