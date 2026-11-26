import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import SQLite3

private struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct Inspection: Decodable {
    let path: String?
    let version: String?
    let checkedAt: Date
}

private func databaseState(at url: URL) -> (version: Int32, projects: Int32, tasks: Int32)? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if let db { sqlite3_close(db) }
        return nil
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    let query = "SELECT user_version, (SELECT COUNT(*) FROM projects), (SELECT COUNT(*) FROM tasks) FROM pragma_user_version"
    guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return (sqlite3_column_int(statement, 0), sqlite3_column_int(statement, 1), sqlite3_column_int(statement, 2))
}

// WindowServer exposes the owner, layer and bounds without requesting Accessibility or screen capture.
private func mainWindowCount(pid: pid_t) -> Int? {
    guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] else { return nil }
    return rows.filter {
        guard ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = $0[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber else { return false }
        return width.doubleValue >= 400 && height.doubleValue >= 300
    }.count
}

@main
private struct FirstLaunch {
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("First launch failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure("expected app and isolated data directory") }
        let app = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().standardizedFileURL
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
        let id = "org.agenthub.desktop"
        guard Bundle(url: app)?.bundleIdentifier == id else { throw Failure("unexpected app bundle identifier") }
        guard CGSessionCopyCurrentDictionary() != nil else {
            print("A01=SKIPPED reason=no_graphical_login_session")
            return
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else {
            print("A01=SKIPPED reason=existing_Agent_Hub_instance")
            return
        }

        let digest = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let domain = "org.agenthub.desktop.test." + digest
        guard let preferences = UserDefaults(suiteName: domain),
              preferences.persistentDomain(forName: domain)?.isEmpty != false,
              !FileManager.default.fileExists(atPath: directory.path) else { throw Failure("test storage is not fresh") }
        defer { preferences.removePersistentDomain(forName: domain); preferences.synchronize() }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.addsToRecentItems = false
        configuration.activates = true
        configuration.environment = ["AGENTHUB_DATA_DIR": directory.path]
        configuration.arguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        let started = Date()
        let process = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        guard process.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == app.path else {
            throw Failure("LaunchServices returned a different app; leaving that process untouched")
        }
        print("launch=LaunchServices install=isolated_Applications_copy process=\(process.processIdentifier)")
        var outcome: Error?
        do { try await observe(process, directory: directory, domain: domain, since: started) }
        catch { outcome = error }
        if !process.isTerminated {
            _ = process.terminate()
            for _ in 0..<40 where !process.isTerminated { try await Task.sleep(nanoseconds: 200_000_000) }
            if !process.isTerminated {
                _ = process.forceTerminate()
                for _ in 0..<20 where !process.isTerminated { try await Task.sleep(nanoseconds: 100_000_000) }
                throw Failure("app did not terminate normally; forced termination requested only for the launched process")
            }
        }
        if let outcome { throw outcome }
        print("shutdown=normal")
    }

    @MainActor private static func observe(_ process: NSRunningApplication, directory: URL,
                                           domain: String, since started: Date) async throws {
        let providers = ["codex", "antigravity", "dsh"]
        var inspections: [String: Inspection] = [:]
        var windows = 0
        var windowListAvailable = false
        var database: (version: Int32, projects: Int32, tasks: Int32)?
        for _ in 0..<180 {
            guard !process.isTerminated else { throw Failure("app exited during first launch") }
            if let count = mainWindowCount(pid: process.processIdentifier) {
                windowListAvailable = true
                windows = max(windows, count)
            }
            if database == nil { database = databaseState(at: directory.appendingPathComponent("agent-hub.sqlite3")) }
            CFPreferencesAppSynchronize(domain as CFString)
            for id in providers where inspections[id] == nil {
                let key = ("cliInspection." + id) as CFString
                if let bytes = CFPreferencesCopyAppValue(key, domain as CFString) as? Data,
                   let inspection = try? JSONDecoder().decode(Inspection.self, from: bytes), inspection.checkedAt >= started {
                    inspections[id] = inspection
                }
            }
            if database != nil && inspections.count == providers.count && windows > 0 { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        print("window_server_observable=\(windowListAvailable) on_screen_app_windows=\(windows)")
        if let database {
            print("sqlite_schema=\(database.version) projects=\(database.projects) tasks=\(database.tasks)")
        }
        for id in providers {
            guard let record = inspections[id] else { print("provider=\(id) detection=incomplete"); continue }
            let evidence: [String: Any] = [
                "provider": id, "detection": "completed",
                "path": record.path as Any? ?? NSNull(), "version": record.version as Any? ?? NSNull(),
                "checkedAt": ISO8601DateFormatter().string(from: record.checkedAt)
            ]
            let bytes = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: bytes, as: UTF8.self))
        }
        guard let database, database.version > 0, database.projects == 0, database.tasks == 0 else {
            throw Failure("fresh SQLite database and empty project/task tables not observed")
        }
        guard inspections.count == providers.count else { throw Failure("missing first-launch CLI inspection records") }
        guard windows > 0 else {
            throw Failure(windowListAvailable ? "running app had no observable on-screen main window" : "WindowServer list unavailable; GUI startup unverified")
        }
        let installed = providers.filter { inspections[$0]?.path != nil }
        if installed.isEmpty {
            print("A01=OBSERVED clean_launch_window_SQLite_and_all_three_CLIs_absent; first-run buttons were not inspected")
        } else {
            print("A01=PARTIAL clean_launch_with_installed_CLIs=\(installed.joined(separator: ",")); all-absent scenario unavailable on this host")
        }
    }
}
