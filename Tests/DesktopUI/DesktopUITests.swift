import AppKit
import XCTest

@MainActor
final class DesktopUITests: XCTestCase {
    private struct Run: Decodable {
        let app: String
        let work: String
        let captureInbox: String
        let evidence: String
        let gallery: String?
        var repository: String { work + "/Field Notes" }
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ window: XCUIElement, _ name: String, run: Run) throws {
        // Never capture a display, Finder, an open panel, or a different application.
        XCTAssertTrue(window.exists)
        let inbox = URL(fileURLWithPath: run.captureInbox)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let request = try JSONEncoder().encode(["name": name, "title": window.title])
        try request.write(to: inbox.appendingPathComponent(name + ".request"), options: .atomic)
        let status = inbox.appendingPathComponent(name + ".status")
        let limit = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: status.path), Date() < limit {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(try String(contentsOf: status, encoding: .utf8), "ok")

    }

    private func importProject(_ app: XCUIApplication, run: Run) {
        element("board.import", in: app).click()
        let choose = app.buttons["导入项目"].firstMatch
        // The go-to-folder sheet belongs to the app's own attached NSOpenPanel.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(run.repository)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        // Resolve the button inside the open panel, apart from the welcome view.
        let confirm = sheet.buttons["导入项目"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(element("board.newTask", in: app).waitForExistence(timeout: 15))
    }

    func testGalleryFixture() throws {
        continueAfterFailure = false
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Run", withExtension: "plist"))
        let run = try PropertyListDecoder().decode(Run.self, from: Data(contentsOf: config))
        guard let gallery = run.gallery else { throw XCTSkip("No completed gallery fixture supplied.") }
        let url = URL(fileURLWithPath: run.app)
        XCTAssertEqual(Bundle(url: url)?.bundleIdentifier, "org.agenthub.desktop")
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "org.agenthub.desktop")
        try XCTSkipUnless(existing.isEmpty, "Close other Agent Hub instances before running the fixture.")
        let app = XCUIApplication(url: url)
        let home = run.work + "/home"
        app.launchEnvironment = ["AGENTHUB_DATA_DIR": gallery, "HOME": home, "CFFIXED_USER_HOME": home]
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock { @MainActor in if app.state != .notRunning { app.terminate() } }
        let card = app.buttons.matching(NSPredicate(format: "label == %@", "打开任务，fixture-gallery")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.click()
        let front = element("workspace.draft.frontend", in: app)
        let back = element("workspace.draft.backend", in: app)
        XCTAssertTrue(front.waitForExistence(timeout: 8))
        XCTAssertTrue(back.exists)
        try capture(app.windows.firstMatch, "07-paired-fixture", run: run)
        front.click()
        front.typeText("Keep the layout")
        back.click()
        back.typeText("Check the API")
        element("workspace.role.frontend", in: app).click()
        app.menuItems["负责人"].firstMatch.click()
        XCTAssertFalse(front.exists)
        XCTAssertEqual(back.value as? String, "Check the API")
        element("workspace.role.lead", in: app).click()
        app.menuItems["前端"].firstMatch.click()
        XCTAssertEqual(front.value as? String, "Keep the layout")
    }

    func testPackagedApplication() throws {
        continueAfterFailure = false
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Run", withExtension: "plist"))
        let run = try PropertyListDecoder().decode(Run.self, from: Data(contentsOf: config))
        let url = URL(fileURLWithPath: run.app)
        XCTAssertEqual(Bundle(url: url)?.bundleIdentifier, "org.agenthub.desktop")
        let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "org.agenthub.desktop")
        try XCTSkipUnless(existing.isEmpty, "Close other Agent Hub instances before using this isolated test.")
        let app = XCUIApplication(url: url)
        let home = run.work + "/home"
        app.launchEnvironment = [
            "AGENTHUB_DATA_DIR": run.work + "/data", "HOME": home, "CFFIXED_USER_HOME": home
        ]
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        addTeardownBlock { @MainActor in if app.state != .notRunning { app.terminate() } }
        let welcome = element("board.import", in: app)
        XCTAssertTrue(welcome.waitForExistence(timeout: 15))
        try capture(app.windows.firstMatch, "01-welcome", run: run)
        importProject(app, run: run)

        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("n", modifierFlags: .command)
        let goal = element("task.goal", in: app)
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        goal.click()
        goal.typeText("Check the project status")
        let create = element("task.create", in: app)
        XCTAssertTrue(create.isEnabled)
        create.click()
        let editor = element("workspace.draft.task", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("Review this draft")
        let recipient = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "选择消息接收对象")).firstMatch
        recipient.click()
        app.menuItems["角色级 · 发给负责人"].firstMatch.click()
        let roleDraft = element("workspace.draft.lead", in: app)
        XCTAssertTrue(roleDraft.waitForExistence(timeout: 5))
        XCTAssertEqual(roleDraft.value as? String ?? "", "")
        roleDraft.click()
        roleDraft.typeText("Role-specific note")
        element("workspace.send.lead", in: app).click()
        recipient.click()
        app.menuItems["任务级 · 发给负责人"].firstMatch.click()
        XCTAssertEqual(editor.value as? String, "Review this draft")

        app.buttons["返回看板"].firstMatch.click()
        let taskCard = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Check the project status")).firstMatch
        XCTAssertTrue(taskCard.waitForExistence(timeout: 5))
        try capture(app.windows.firstMatch, "02-board", run: run)
        taskCard.click()
        app.buttons["成果与验证"].firstMatch.click()
        try capture(app.windows.firstMatch, "02-results", run: run)
        app.buttons["协作"].firstMatch.click()
        XCTAssertEqual(editor.value as? String, "Review this draft")
        try capture(app.windows.firstMatch, "03-workspace", run: run)

        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
            .withOffset(CGVector(dx: -2, dy: -2))
        let target = edge.withOffset(CGVector(dx: 760 - window.frame.width, dy: 0))
        edge.click(forDuration: 0.2, thenDragTo: target)
        XCTAssertLessThan(window.frame.width, 860)
        XCTAssertTrue(editor.isHittable)
        try capture(window, "04-compact", run: run)

        app.typeKey(",", modifierFlags: .command)
        let settings = element("hub-settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.staticTexts["通用与版本"].firstMatch.click()
        for (scheme, filename) in [("深色", "05-dark"), ("浅色", "06-light")] {
            let choice = app.radioButtons[scheme].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.click()
            try capture(app.windows.containing(.any, identifier: "hub-settings").firstMatch, filename, run: run)
        }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertNotEqual(app.state, .notRunning)
        // A LaunchServices reopen event exercises the same delegate path as a Dock click.
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 12))
        app.launch()
        XCTAssertTrue(editor.waitForExistence(timeout: 12))
        XCTAssertEqual(editor.value as? String, "Review this draft")
    }
}
