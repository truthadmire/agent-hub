import XCTest
import HubProviders
@testable import HubKit

final class PlanRulesTests: XCTestCase {
    private let routes: [String:ProviderID] = ["lead":.codex, "frontend":.antigravity, "backend":.codex]

    private func item(_ id: String, _ role: String, path: String, depends: [String] = []) -> WorkItem {
        var result = WorkItem(id: id, title: "Implement \(id)", role: role, provider: routes[role] ?? .codex)
        result.dependencies = depends
        result.writeScope = [path]
        result.deliverables = ["Source change"]
        return result
    }

    func testRejectsCyclesUnknownRolesMissingDependenciesDuplicatesAndAmbiguousOwnership() {
        let one = item("a","frontend",path:"Client")
        let invalid: [[WorkItem]] = [
            [one,one],
            [one,item("b","backend",path:"Server",depends:["missing"])],
            [item("a","frontend",path:"Client",depends:["b"]),item("b","backend",path:"Server",depends:["a"])],
            [one,item("b","test",path:"Tests")],
            [one,item("b","backend",path:"client/ui")],
            [item("a","frontend",path:"../outside")],
            [item("a","frontend",path:".git/hooks")]
        ]
        for items in invalid {
            let plan = PlanRevision(revision: 1, requirementRevision: 1, goal: "Improve project", items: items)
            XCTAssertThrowsError(try PlanRules.validate(plan, routes: routes))
        }
        let ordered = [one,item("b","backend",path:"Client/ui",depends:["a"]),item("c","backend",path:"Server",depends:["a"])]
        XCTAssertNoThrow(try PlanRules.validate(.init(revision: 1, requirementRevision: 1, goal: "Improve project", items: ordered), routes: routes))
    }

    func testMalformedSchemaDoesNotDispatch() {
        let task = HubTask(projectID:"p",title:"Build",goal:"Build")
        XCTAssertThrowsError(try PlanRules.decode(#"{"goal":"Do it","items":[]}"#,task:task,routes:routes))
        let question = #"{"goal":"Build","acceptance":[],"interfaces":[],"checks":[],"questions":["Which repository?"],"items":[]}"#
        XCTAssertEqual(try PlanRules.decode(question,task:task,routes:routes).questions, ["Which repository?"])
    }
    func testPaidFallbackRequiresSeparateConsentAndBudgetButDirectAssignmentWorks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hub-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = HubEngine(store: try HubStore(directory: directory), workspaceRoot: directory.appendingPathComponent("work"))
        let endpoint = EngineConnection(url: URL(fileURLWithPath:"/usr/bin/false"), paid:true)
        var config = HubConfiguration.balanced
        config.enabledRoles = ["lead","test"]
        config.paidProviders = [.dsh]
        var destinations = await engine.routes(config,[.dsh:endpoint])
        XCTAssertEqual(destinations["test"],.dsh)
        XCTAssertNil(destinations["lead"])
        config.allowedFallbacks = [.dsh]
        destinations = await engine.routes(config,[.dsh:endpoint])
        XCTAssertNil(destinations["lead"])
        config.maxCostUSD = 1
        destinations = await engine.routes(config,[.dsh:endpoint])
        XCTAssertEqual(destinations["lead"],.dsh)
        config.paidProviders = []
        destinations = await engine.routes(config,[.dsh:endpoint])
        XCTAssertNil(destinations["lead"])
    }
}
