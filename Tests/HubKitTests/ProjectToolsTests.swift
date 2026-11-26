import Foundation
import XCTest
@testable import HubKit

final class ProjectToolsTests: XCTestCase {
    private func checkout() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hub checks 中文 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testManifestDetectionAndNoCheckRemainsEmpty() throws {
        let root = try checkout()
        XCTAssertTrue(ProjectTools.detect(in: root).checks.isEmpty)
        let package = root.appendingPathComponent("package.json")
        for manager in ["npm", "pnpm", "yarn"] {
            let manifest = ["packageManager": manager + "@1", "scripts": ["build": "node build.js", "dev": "vite",
                                                                         "test": "echo \"Error: no test specified\" && exit 1"]] as [String: Any]
            try JSONSerialization.data(withJSONObject: manifest).write(to: package)
            let info = ProjectTools.detect(in: root)
            XCTAssertEqual(info.checks.map(\.argv), [[manager, "run", "build"]])
            guard case .command(let argv, _) = info.preview else { return XCTFail("missing script preview") }
            XCTAssertTrue(argv.contains("{port}"))
            XCTAssertEqual(argv.first, manager)
        }
        try FileManager.default.removeItem(at: package)
        for (name, tool) in [("pyproject.toml", "python3"), ("Cargo.toml", "cargo"), ("Package.swift", "swift")] {
            try Data().write(to: root.appendingPathComponent(name))
            XCTAssertTrue(ProjectTools.detect(in: root).checks.contains { $0.argv.first == tool })
        }
    }

    func testActualCommandEvidenceAndCredentialFilter() async throws {
        let root = try checkout()
        // Supplying a synthetic secret to the test host verifies the real child environment.
        let sentinel = "AGENT_HUB_CREDENTIAL_SENTINEL_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        setenv(sentinel, "present-in-parent", 1)
        defer { unsetenv(sentinel) }
        let folder = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let command = ProjectCheckCommand(name: "fixture", argv: ["/bin/sh", "-c", #"""
            [ -z "${DEEPSEEK_API_KEY-}" ] && [ -z "${OPENAI_API_KEY-}" ] || exit 99
            if /usr/bin/printenv "$2" >/dev/null; then exit 97; fi
            test "$NODE_ENV" = test || exit 98
            printf '%s\n' "$1" > evidence.txt
            printf 'ok\n'
            printf 'detail\n' >&2
            """#, "fixture", "literal $SHELL && punctuation", sentinel], workingDirectory: "src", environment: ["NODE_ENV": "test"])
        let result = try await ProjectTools.run(command, in: root)
        XCTAssertEqual(result.status, .passed, "\(result.reason ?? "") \(result.stderr)")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "ok\n")
        XCTAssertEqual(result.stderr, "detail\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("evidence.txt")), "literal $SHELL && punctuation\n")
        XCTAssertGreaterThanOrEqual(result.finishedAt, result.startedAt)
        let bad = try await ProjectTools.run(.init(name: "failure", argv: ["/bin/sh", "-c", "exit 6"]), in: root)
        XCTAssertEqual(bad.status, .failed)
        XCTAssertEqual(bad.exitCode, 6)
        let invalid = try await ProjectTools.run(.init(name: "missing", argv: ["not_an_agenthub_tool"]), in: root)
        XCTAssertEqual(invalid.status, .blocked)
        let empty = try await ProjectTools.run(.init(name: "empty", argv: []), in: root)
        XCTAssertEqual(empty.status, .blocked)
    }

    func testConfinementTimeoutAndCancellation() async throws {
        let root = try checkout()
        let outside = try checkout()
        let marker = outside.appendingPathComponent("written")
        let denied = try await ProjectTools.run(.init(name: "write boundary",
                                                      argv: ["/usr/bin/touch", marker.path]), in: root)
        XCTAssertNotEqual(denied.status, .passed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let escaped = try await ProjectTools.run(.init(name: "directory", argv: ["/usr/bin/true"], workingDirectory: ".."), in: root)
        XCTAssertEqual(escaped.status, .blocked)
        let secret = try await ProjectTools.run(.init(name: "environment", argv: ["/usr/bin/true"],
                                                      environment: ["DEEPSEEK_API_KEY": "dummy-sentinel"]), in: root)
        XCTAssertEqual(secret.status, .blocked)
        let timed = try await ProjectTools.run(.init(name: "timeout", argv: ["/bin/sleep", "8"], timeout: 0.15), in: root)
        XCTAssertEqual(timed.status, .blocked)
        XCTAssertTrue(timed.reason?.contains("超时") == true, timed.reason ?? "")
        let task = Task { try await ProjectTools.run(.init(name: "cancel", argv: ["/bin/sleep", "8"]), in: root) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled check returned normally") }
        catch is CancellationError {}
    }

    func testStaticCheckActuallyInspectsReferencedFiles() async throws {
        let root = try checkout()
        try Data("<html><img src='poster.png'></html>".utf8).write(to: root.appendingPathComponent("index.html"))
        let check = try XCTUnwrap(ProjectTools.detect(in: root).checks.first)
        let missing = try await ProjectTools.run(check, in: root)
        XCTAssertEqual(missing.status, .failed, "\(missing.reason ?? "") \(missing.stderr)")
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("poster.png"))
        let present = try await ProjectTools.run(check, in: root)
        XCTAssertEqual(present.status, .passed, present.stderr)
    }
}
