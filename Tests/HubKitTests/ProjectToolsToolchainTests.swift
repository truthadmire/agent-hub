import Foundation
import XCTest
import HubProcess
@testable import HubKit

final class ProjectToolsToolchainTests: XCTestCase {
    private func fixture(files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toolchain " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for (name, text) in files {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path)
        }
        return root
    }

    func testSwiftPackageActuallyBuildsDiscoverableArtifactWithPrivateCaches() async throws {
        let root = try fixture(files: [
            "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "Hello", targets: [.executableTarget(name: "Hello")])
                """,
            "Sources/Hello/main.swift": #"print("hello")"#
        ])
        let check = try XCTUnwrap(ProjectTools.detect(in: root).checks.first)
        let result = try await ProjectTools.run(check, in: root)
        XCTAssertEqual(result.status, .passed, "\(result.reason ?? "") \(result.stderr)")
        XCTAssertTrue(ProjectTools.artifacts(in: root).contains { $0.lastPathComponent == "Hello" })
    }

    func testNpmRunsExistingScript() async throws {
        try XCTSkipUnless(ProcessEnvironment.resolve("npm") != nil, "npm is not installed.")
        let root = try fixture(files: [
            "package.json": #"{"scripts":{"test":"node check.js"}}"#,
            "check.js": "require('node:assert').strictEqual(3 + 4, 7)"
        ])
        let check = try XCTUnwrap(ProjectTools.detect(in: root).checks.first)
        let result = try await ProjectTools.run(check, in: root)
        XCTAssertEqual(result.status, .passed, "\(result.reason ?? "") \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("node check.js"))
    }
}
