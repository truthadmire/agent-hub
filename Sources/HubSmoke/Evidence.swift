import Darwin
import Foundation
import HubKit
import HubProviders

extension HubSmoke {
    private static func openAfterShutdown(_ data: URL) async throws -> HubStore {
        // An already queued actor callback can briefly retain the previous owner after shutdown returns.
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            do { return try HubStore(directory: data) }
            catch HubStoreError.occupied where ContinuousClock.now < end {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    static func verifyGalleryPreview(task: HubTask, root: URL, output: URL) async throws {
        guard let argv = task.runtimeConfig?.previewCommand else { throw SmokeError("Missing gallery preview configuration") }
        let preview = PreviewManager()
        let base = try await preview.start(taskID: task.id, root: root, configuration: .command(argv: argv))
        do {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            guard let api = URL(string: "/api/photos?category=Coast&page=2", relativeTo: base),
                  let empty = URL(string: "/?category=Portraits", relativeTo: base) else { throw SmokeError("Invalid fixture URL") }
            let (data, response) = try await session.data(from: api)
            let payload = try JSONSerialization.jsonObject(with: data) as? [String:Any]
            let items = payload?["items"] as? [[String:Any]]
            try require((response as? HTTPURLResponse)?.statusCode == 200 && items?.count == 1
                        && items?.first?["title"] as? String == "Last Ferry", "Preview API returned the wrong page")
            let (html, pageResponse) = try await session.data(from: empty)
            try require((pageResponse as? HTTPURLResponse)?.statusCode == 200
                        && String(decoding: html, as: UTF8.self).contains("No photographs found."), "Missing empty state in preview")
            try data.write(to: output.appendingPathComponent("preview-api.json"))
            try html.write(to: output.appendingPathComponent("preview-empty.html"))
        } catch {
            await preview.stop(taskID: task.id)
            throw error
        }
        await preview.stop(taskID: task.id)
    }

    static func verifyReopened(_ mode: SmokeCase, files: SmokeFiles, id: String) async throws {
        // This new exclusive store handle proves that output and task state survived a close and reopen.
        let store = try await openAfterShutdown(files.db)
        let task = try store.task(id)
        let project = try store.project(task.projectID)
        let events = try store.events(taskID: id, limit: 500)
        let report = files.root.appendingPathComponent("result.json")
        var result: [String:Any] = [
            "mode": mode.label, "task": task.id, "state": task.state.rawValue,
            "reason": task.attentionReason ?? "", "summary": task.summary,
            "base": project.baseCommit ?? "", "source": files.source.path,
            "attempts": task.attempts.map {
                ["provider": $0.provider.rawValue, "id": $0.id, "item": $0.itemID, "state": $0.state.rawValue,
                 "directory": $0.workspace?.path ?? "", "sessionObserved": $0.providerSessionID != nil,
                 "failure": $0.failure ?? "", "inputTokens": $0.inputTokens as Any,
                 "outputTokens": $0.outputTokens as Any, "changedPaths": $0.changedPaths] as [String:Any]
            },
            "checks": task.verifications.map {
                ["name": $0.name, "state": $0.state.rawValue, "command": $0.command, "exit": $0.exitCode as Any,
                 "snapshot": $0.snapshot, "after": $0.snapshotAfter as Any, "directory": $0.directory ?? "",
                 "evidence": $0.evidence ?? ""] as [String:Any]
            },
            "events": events.map(\.kind), "artifacts": task.artifacts.map(\.path),
            "handoffs": task.handoffs.count, "switches": task.switchCount, "repairs": task.repairCount
        ]
        let originalHead = try files.git(["rev-parse","HEAD"], at: files.source)
        let originalStatus = try files.git(["status","--porcelain","--untracked-files=all"], at: files.source)
        result["originalUnchanged"] = originalHead == project.baseCommit && originalStatus.isEmpty
        if let ref = task.workspace, let base = project.baseCommit {
            let path = URL(fileURLWithPath: ref.path)
            result["integratedWorktree"] = ref.path
            result["integratedHead"] = try files.git(["rev-parse","HEAD"], at: path)
            result["diffFiles"] = try files.git(["diff","--name-only",base,"HEAD"], at: path).components(separatedBy: .newlines).filter { !$0.isEmpty }
            try files.git(["diff",base,"HEAD"], at: path).write(to: files.root.appendingPathComponent("integrated.patch"), atomically:true, encoding:.utf8)
        }
        try JSONSerialization.data(withJSONObject: result, options:[.prettyPrinted,.sortedKeys])
            .write(to: report, options: .atomic)
        print("\(task.state.rawValue) · \(task.attempts.count) attempts · \(task.verifications.count) checks · \(report.path)")
        if !task.summary.isEmpty { print(task.summary) }
        try require(result["originalUnchanged"] as? Bool == true, "Source HEAD or working tree changed")
        try require(!events.isEmpty, "Reopened database has no event history")
        let integratedChecks = task.verifications.filter { !$0.name.hasPrefix("Baseline · ") }
        let scenario = mode.fixture ?? "live"
        if ["pause", "cancel", "restart"].contains(scenario) {
            let raw = try String(contentsOf: files.marker, encoding: .utf8)
            guard let fixturePID = Int32(raw), fixturePID > 1 else { throw SmokeError("Missing fixture child PID") }
            let end = Date().addingTimeInterval(5)
            while kill(fixturePID, 0) == 0 && Date() < end {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try require(kill(fixturePID, 0) == -1 && errno == ESRCH, "Fixture descendant persisted after interruption")
        }
        switch scenario {
        case "cancel":
            try require(task.state == .cancelled && task.attempts.count == 1, "Cancellation dispatched extra work")
            try require((result["diffFiles"] as? [String]) == [], "Cancelled attempt was merged")
            guard let path = task.attempts.first?.workspace?.path else { throw SmokeError("No interrupted attempt checkout") }
            try require(try String(contentsOfFile: path + "/status.txt", encoding: .utf8) == "partial\n",
                        "Interrupted work was discarded")
        case "auth", "protocol":
            let expected = scenario == "auth" ? "authentication" : "protocolError"
            try require(task.state == .needsUser && task.attempts.count == 1 && task.attempts[0].failureKind == expected,
                        "Expected a classified \(expected) failure")
        case "stalled":
            try require(task.state == .needsUser && integratedChecks.contains { $0.state == .failed }
                        && task.repairCount == 1 && task.attempts.count == 2,
                        "Repeated failure did not stop after one repair")
        default:
            try require(task.state == .completed, task.attentionReason.map { "Task blocked: \($0). \(task.summary)" } ?? "Task did not complete")
            guard let work = task.workspace else { throw SmokeError("Missing integrated worktree") }
            let head = result["integratedHead"] as? String
            try require(integratedChecks.contains { $0.state == .passed && $0.exitCode == 0 && $0.snapshot == head },
                        "Missing passing independent command against final HEAD")
            try require(!task.attempts.isEmpty && task.attempts.contains { $0.providerSessionID != nil }, "Missing provider session")
            if mode.isTeam {
                try require(task.attempts.count == 3 && task.attempts.allSatisfy { $0.state == .succeeded && $0.providerSessionID != nil },
                            "Expected one successful plan and two successful worker sessions")
                let peers = task.attempts.filter { $0.itemID != "@plan" }
                try require(peers.count == 2 && Set(peers.map(\.provider)) == Set([.codex,.antigravity]), "Missing distinct provider workers")
                for (name, provider, value) in [("frontend", ProviderID.antigravity, "Ready to browse\n"), ("backend", ProviderID.codex, "ready\n")] {
                    let filename = name + ".txt"
                    try require(peers.contains { $0.provider == provider && $0.role == name && $0.changedPaths == [filename] },
                                "A worker did not deliver exactly its requested file")
                    try require(try String(contentsOfFile: work.path + "/" + filename, encoding: .utf8) == value, "Unexpected bytes in " + filename)
                }
                try require(Set(result["diffFiles"] as? [String] ?? []) == Set(["frontend.txt","backend.txt"])
                            && integratedChecks.filter { $0.state == .passed && $0.snapshot == head }.count == 2,
                            "The integrated two-file result needs both checks on the same final commit")
                try require(FileManager.default.fileExists(atPath: files.root.appendingPathComponent("team-overlap.json").path),
                            "Did not observe both kernel-verified worker processes alive simultaneously")
            } else if scenario == "gallery" {
                try require(Set(result["diffFiles"] as? [String] ?? []) == Set(["catalog.py","page.py","tests/test_filter.py"]),
                            "Gallery contributions missing from integrated diff")
                try require(Set(task.attempts.map(\.provider)) == Set(ProviderID.allCases) && !task.handoffs.isEmpty,
                            "Gallery did not use all three fixture protocols or did not record its handoff")
                try await verifyGalleryPreview(task: task, root: URL(fileURLWithPath: work.path), output: files.root)
                print("Preview from \(work.path) with python3 -B server.py --port 8765")
            } else {
                try require(try String(contentsOfFile: work.path + "/status.txt", encoding: .utf8) == "verified\n", "Edited bytes do not match")
            }
            if scenario == "repair" {
                try require(task.repairCount == 1 && integratedChecks.contains { $0.state == .failed }, "Missing failed check and bounded repair")
            }
            if scenario == "quota" {
                try require(task.switchCount == 1 && task.attempts.contains { $0.failureKind == "quota" }
                            && task.attempts.last?.provider == .antigravity && !task.handoffs.isEmpty, "Missing quota handoff")
            }
            if scenario == "restart" || scenario == "pause" {
                try require(task.attempts.count == 2 && task.attempts.last?.previousID == task.attempts.first?.id, "Interrupted attempt was not linked to its replacement")
            }
        }
        print("PASS · reopened persistence, independent assertions and original checkout")
    }
}
