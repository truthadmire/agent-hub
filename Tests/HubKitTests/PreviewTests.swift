import Foundation
import XCTest
@testable import HubKit

final class PreviewTests: XCTestCase {
    private func checkout(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview 中文 " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("<html><link rel='stylesheet' href='style.css'><body>\(label)</body></html>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        try Data("body{color:red}".utf8).write(to: root.appendingPathComponent("style.css"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testTwoTaskListenersAreDistinctAndPublishOnlyReferencedFiles() async throws {
        let first = try checkout("first"), second = try checkout("second")
        try Data("internal".utf8).write(to: first.appendingPathComponent("unpublished.js"))
        let manager = PreviewManager()
        let a = try await manager.start(taskID: "a", root: first, configuration: .staticSite(directory: "."))
        let b = try await manager.start(taskID: "b", root: second, configuration: .staticSite(directory: "."))
        XCTAssertNotEqual(a.port, b.port)
        for (url, label) in [(a, "first"), (b, "second")] {
            let (bytes, _) = try await URLSession.shared.data(from: url)
            XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(label))
        }
        let (style, _) = try await URLSession.shared.data(from: a.appendingPathComponent("style.css"))
        XCTAssertEqual(String(decoding: style, as: UTF8.self), "body{color:red}")
        let (_, hidden) = try await URLSession.shared.data(from: a.appendingPathComponent("unpublished.js"))
        XCTAssertEqual((hidden as? HTTPURLResponse)?.statusCode, 404)
        try FileManager.default.removeItem(at: first.appendingPathComponent("style.css"))
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("style.css"), withDestinationURL: second.appendingPathComponent("style.css"))
        let (_, link) = try await URLSession.shared.data(from: a.appendingPathComponent("style.css"))
        XCTAssertEqual((link as? HTTPURLResponse)?.statusCode, 404)
        await manager.stop(taskID: "a")
        let old = await manager.url(for: "a"), unaffected = await manager.url(for: "b")
        XCTAssertNil(old)
        XCTAssertEqual(unaffected, b)
        await manager.stopAll()
    }

    func testRealProjectCommandAndForeignPort() async throws {
        let root = try checkout("owned")
        let manager = PreviewManager()
        let python = ["/bin/sh", "-c", "echo generated > preview.txt && exec python3 -I -B -m http.server \"$PORT\" --bind 127.0.0.1"]
        let owned = try await manager.start(taskID: "owned", root: root, configuration: .command(argv: python))
        XCTAssertEqual(owned.host, "127.0.0.1")
        let (data, _) = try await URLSession.shared.data(from: owned)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("owned"))
        let (generated, _) = try await URLSession.shared.data(from: owned.appendingPathComponent("preview.txt"))
        XCTAssertEqual(String(decoding: generated, as: UTF8.self), "generated\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("preview.txt").path))
        let otherPort = try XCTUnwrap(owned.port)
        do {
            _ = try await manager.start(taskID: "other", root: root,
                                         configuration: .command(argv: ["python3", "-I", "-m", "http.server",
                                                                         String(otherPort), "--bind", "127.0.0.1"]),
                                         readinessTimeout: 2)
            XCTFail("Foreign service accepted as a ready preview")
        } catch {}
        let other = await manager.url(for: "other")
        XCTAssertNil(other)
        await manager.stopAll()
        let after = await manager.url(for: "owned")
        XCTAssertNil(after)
        do { _ = try await URLSession.shared.data(from: owned); XCTFail("managed server still accepts requests") }
        catch {}
    }
}
