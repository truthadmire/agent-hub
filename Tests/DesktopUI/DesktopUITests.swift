import AppKit
import SQLite3
import XCTest

@MainActor
final class DesktopUITests: XCTestCase {
    private struct Run: Decodable {
        let app: String
        let work: String
        let captureInbox: String
        let evidence: String
        let providerHome: String?
        let gallery: String?
        let galleryTitle: String?
        var repository: String { work + "/Field Notes" }
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ window: XCUIElement, _ name: String, run: Run, action: String = "capture") throws {
        // Never capture a display, Finder, an open panel, or a different application.
        XCTAssertTrue(window.exists)
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let inbox = URL(fileURLWithPath: run.captureInbox)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let request = try JSONEncoder().encode(["name": name, "title": window.title, "action": action])
        try request.write(to: inbox.appendingPathComponent(name + ".request"), options: .atomic)
        let status = inbox.appendingPathComponent(name + ".status")
        let limit = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: status.path), Date() < limit {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(try String(contentsOf: status, encoding: .utf8), "ok")

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
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 6))
        try capture(app.windows.firstMatch, "gallery-wide", run: run, action: "wide")
        let title = try XCTUnwrap(run.galleryTitle)
        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "打开任务，"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(cards.count, 1)
        let card = app.buttons.matching(NSPredicate(format: "label == %@", "打开任务，" + title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.click()
        let front = element("workspace.draft.frontend", in: app)
        let back = element("workspace.draft.backend", in: app)
        XCTAssertTrue(front.waitForExistence(timeout: 8))
        XCTAssertTrue(back.exists)
        try capture(app.windows.firstMatch, title == "live-team" ? "07-paired-live" : "07-paired-fixture", run: run)
        front.click()
        front.typeText("1042")
        back.click()
        back.typeText("2064")
        element("workspace.role.frontend", in: app).click()
        let leader = app.menuItems.matching(NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@", "负责人", "负责人")).firstMatch
        if !leader.waitForExistence(timeout: 2) { element("workspace.role.frontend", in: app).click() }
        XCTAssertTrue(leader.waitForExistence(timeout: 3))
        leader.click()
        XCTAssertFalse(front.exists)
        XCTAssertEqual(back.value as? String, "2064")
        element("workspace.role.lead", in: app).click()
        app.menuItems["前端"].firstMatch.click()
        XCTAssertEqual(front.value as? String, "1042")
    }

    func testReadingWhileAgentWrites() throws {
        continueAfterFailure = false
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Run", withExtension: "plist"))
        let run = try PropertyListDecoder().decode(Run.self, from: Data(contentsOf: config))
        let app = XCUIApplication(url: URL(fileURLWithPath: run.app))
        let home = run.work + "/home"
        app.launchEnvironment = ["AGENTHUB_DATA_DIR": run.work + "/data", "HOME": home, "CFFIXED_USER_HOME": home]
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock { @MainActor in if app.state != .notRunning { app.terminate() } }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        try capture(window, "history-wide", run: run, action: "wide")
        element("board.newTask", in: app).click()
        let goal = element("task.goal", in: app)
        XCTAssertTrue(goal.waitForExistence(timeout: 6))
        goal.click()
        goal.typeText("Observe incoming history")
        element("task.start", in: app).click()
        let older = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@", "查看更早记录", "查看更早记录")).firstMatch
        XCTAssertTrue(older.waitForExistence(timeout: 20))
        let reader = app.scrollViews.containing(.link, identifier: "查看更早记录").firstMatch
        XCTAssertTrue(reader.exists)
        if !older.isHittable { reader.scroll(byDeltaX: 0, deltaY: 8000) }
        if !older.isHittable { reader.scroll(byDeltaX: 0, deltaY: -8000) }
        XCTAssertTrue(older.isHittable)
        older.click()
        let waiting = app.buttons["返回最新记录"].firstMatch
        XCTAssertTrue(waiting.waitForExistence(timeout: 6))
        let history = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "UI history entry", "UI history entry"))
        let anchor = try XCTUnwrap(history.allElementsBoundByIndex.first(where: { $0.isHittable }))
        let value = try XCTUnwrap(anchor.value as? String)
        let y = anchor.frame.midY
        let marker = URL(fileURLWithPath: run.captureInbox).appendingPathComponent("history-release")
        try Data().write(to: marker)
        let unread = app.buttons["有新消息"].firstMatch
        XCTAssertTrue(unread.waitForExistence(timeout: 12))
        let saved = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", value, value)).firstMatch
        XCTAssertTrue(saved.isHittable)
        XCTAssertEqual(saved.frame.midY, y, accuracy: 3)
        unread.click()
        let incoming = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "New controlled provider message", "New controlled provider message")).firstMatch
        XCTAssertTrue(incoming.waitForExistence(timeout: 8))
    }

    func testInstalledExecution() throws {
        try runInstalledTask(live: false)
    }

    func testLiveCodexOnce() throws {
        try runInstalledTask(live: true)
    }

    private func runInstalledTask(live: Bool) throws {
        continueAfterFailure = false
        let config = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Run", withExtension: "plist"))
        let run = try PropertyListDecoder().decode(Run.self, from: Data(contentsOf: config))
        let app = XCUIApplication(url: URL(fileURLWithPath: run.app))
        let home = run.work + "/home"
        let providerHome: String
        if live { providerHome = try XCTUnwrap(run.providerHome, "This case requires explicit --live-codex.") }
        else { providerHome = home }
        app.launchEnvironment = ["AGENTHUB_DATA_DIR": run.work + "/data", "HOME": providerHome, "CFFIXED_USER_HOME": home]
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock { @MainActor in if app.state != .notRunning { app.terminate() } }
        let create = element("board.newTask", in: app)
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.click()
        let goal = element("task.goal", in: app)
        XCTAssertTrue(goal.waitForExistence(timeout: 5))
        goal.click()
        let prompt = live ? "Edit status.txt so its entire content is verified followed by one newline. No commits, other files or network requests." : "Offline UI fixture: write verified to status.txt"
        goal.typeText(prompt)
        XCTAssertEqual(goal.value as? String, prompt)
        element("task.start", in: app).click()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(run.work + "/data/agent-hub.sqlite3", &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "select json_extract(cast(payload as text),'$.state') from tasks order by updated desc limit 1"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let deadline = Date().addingTimeInterval(live ? 325 : 45)
        var state = ""
        repeat {
            if sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
                state = String(cString: value)
            }
            sqlite3_reset(statement)
            if ["completed","needs_user","cancelled"].contains(state) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        XCTAssertEqual(state, "completed")
        try capture(app.windows.firstMatch, "fixture-results-tab", run: run, action: "results")
        try capture(app.windows.firstMatch, live ? "09-installed-live-result" : "08-installed-fixture-result", run: run)
        if live {
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 12))
            // Return to a fully isolated home for read-only restoration of the finished result.
            app.launchEnvironment["HOME"] = home
            app.launch()
            XCTAssertTrue(app.buttons["成果与验证"].firstMatch.waitForExistence(timeout: 12))
        }
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
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO", "-NSNavLastRootDirectory", run.work]
        app.launch()
        addTeardownBlock { @MainActor in if app.state != .notRunning { app.terminate() } }
        // The LaunchServices preflight imported this directory via the native panel.
        XCTAssertTrue(element("board.newTask", in: app).waitForExistence(timeout: 10))

        try capture(app.windows.firstMatch, "basic-wide", run: run, action: "wide")
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
        app.buttons["返回看板"].firstMatch.click()
        let taskCard = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Check the project status")).firstMatch
        XCTAssertTrue(taskCard.waitForExistence(timeout: 5))
        try capture(app.windows.firstMatch, "02-board", run: run)
        taskCard.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        try capture(app.windows.firstMatch, "03-workspace", run: run)
        let window = app.windows.firstMatch
        try capture(window, "basic-narrow", run: run, action: "narrow")
        XCTAssertLessThan(window.frame.width, 860)
        try capture(window, "04-compact", run: run)
        XCTAssertTrue(editor.exists)

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
    }
}
