import XCTest
import HubProviders
@testable import HubKit

final class DiagnosticsTests: XCTestCase {
    func testReportExportsEvidenceWithoutProjectTextOrCredentials() throws {
        let secret = "private-report-sentinel"
        var task = HubTask(projectID: secret, title: secret, goal: secret)
        var attempt = HubAttempt(itemID: secret, provider: .dsh, role: secret,
                                 requirementRevision: 1, planRevision: 1, generation: 1)
        attempt.failureKind = secret
        attempt.failure = secret
        attempt.model = secret
        attempt.executable = "/private/" + secret
        task.attempts = [attempt]
        var check = HubVerification(name: secret, state: .failed, requirementRevision: 1,
                                    snapshot: String(repeating: "a", count: 40))
        check.command = ["/usr/bin/grep", secret]
        check.evidence = secret
        check.exitCode = 1
        task.verifications = [check]
        let event = HubEvent(id: secret, sequence: 7, taskID: task.id, attemptID: nil, requirementRevision: 1,
                             planRevision: 1, generation: 1, createdAt: Date(), kind: secret, detail: secret)
        let data = try TaskDiagnostics.data(for: task, recentEvents: [event], appVersion: "0.1.0", versions: [.dsh: secret])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        XCTAssertEqual((json["checks"] as? [[String: Any]])?.first?["exitCode"] as? Int, 1)
        XCTAssertEqual((json["attempts"] as? [[String: Any]])?.first?["provider"] as? String, "dsh")
    }
}
