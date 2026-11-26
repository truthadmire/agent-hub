import Darwin
import Foundation
import HubKit
import HubProcess
import HubProviders

@main
struct HubSmoke {
    static func main() async {
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            if args == ["--help"] || args == ["-h"] { print(usage); return }
            if args.first == "--restart-child", args.count == 2 {
                let url = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
                let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
                try require(url.deletingLastPathComponent().path == temporary.path
                            && url.lastPathComponent.hasPrefix("agent-hub-smoke-"), "Invalid fixture location")
                let files = SmokeFiles(root: url)
                try await runEngine(.fixture("restart"), files: files, crashAtMarker: true)
                throw SmokeError("Crash injection did not run")
            }
            if args.count == 2, args[0] == "--recheck-live" {
                let root = URL(fileURLWithPath: args[1]).standardizedFileURL.resolvingSymlinksInPath()
                let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
                let files = SmokeFiles(root: root)
                try require(root.deletingLastPathComponent().path == temp.path
                            && root.lastPathComponent.hasPrefix("agent-hub-smoke-"), "Expected a temporary HubSmoke run")
                let metadata = try String(contentsOf: root.appendingPathComponent("connection.txt"), encoding: .utf8)
                let mode: SmokeCase
                if metadata.hasPrefix("live-team\n") {
                    mode = .liveTeam
                } else if let name = metadata.split(separator: " ").first, let provider = ProviderID(rawValue: String(name)) {
                    mode = .live(provider)
                } else {
                    throw SmokeError("No saved live connection report")
                }
                let id = try String(contentsOf: files.taskFile, encoding: .utf8)
                try await verifyReopened(mode, files: files, id: id)
                return
            }
            if args == ["--fixture"] { args.append("single") }
            let mode: SmokeCase
            if args == ["--live-team"] {
                mode = .liveTeam
            } else if args.count == 2, args[0] == "--fixture", SmokeCase.fixtureNames.contains(args[1]) {
                mode = .fixture(args[1])
            } else if args.count == 2, args[0] == "--live", let id = ProviderID(rawValue: args[1]) {
                mode = .live(id)
            } else {
                throw SmokeError(usage)
            }
            let files = try SmokeFiles.create()
            print("\(mode.label) · \(files.root.path)")
            fflush(stdout)
            let liveProviders: [ProviderID] = mode.isTeam ? [.codex,.antigravity] : (mode.fixture == nil ? [mode.provider] : [])
            var descriptions: [String] = mode.isTeam ? ["live-team"] : []
            for provider in liveProviders {
                let probe = await ProviderDiscovery.detect(provider)
                let description = "\(provider.rawValue) \(probe.version ?? "version unknown") · \(probe.auth.rawValue) · \(probe.detail)"
                print(description)
                descriptions.append(description)
                try descriptions.joined(separator: "\n").write(to: files.root.appendingPathComponent("connection.txt"), atomically: true, encoding: .utf8)
                let permitted = provider == .dsh ? probe.auth == .apiKeySaved : probe.auth == .subscription
                guard probe.compatible && permitted else { throw SmokeError("SKIPPED live request: " + description) }
            }
            let id = try setup(mode, files: files)
            if mode.fixture == "restart" {
                let child = Process()
                child.executableURL = Bundle.main.executableURL
                child.arguments = ["--restart-child", files.root.path]
                try child.run()
                child.waitUntilExit()
                try require(child.terminationStatus == 86, "Crash fixture did not reach its checkpoint")
                try await runEngine(mode, files: files, recover: true)
            } else {
                try await runEngine(mode, files: files)
            }
            try await verifyReopened(mode, files: files, id: id)
        } catch {
            FileHandle.standardError.write(Data(("HubSmoke: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static let usage = """
        Usage: HubSmoke --fixture [\(SmokeCase.fixtureNames.joined(separator: "|"))]
               HubSmoke --live codex|antigravity|dsh
               HubSmoke --live-team
               HubSmoke --recheck-live <temporary-run-directory>
        --live performs one real model task using the selected provider's configured billing.
        Every run uses a new synthetic source repository and private temporary application database.
        """

    static func setup(_ mode: SmokeCase, files: SmokeFiles) throws -> String {
        let project = try files.seed(mode)
        let store = try HubStore(directory: files.db)
        try store.saveProject(project)
        let task = try store.createTask(files.task(for: mode, project: project))
        if let scenario = mode.fixture { _ = try files.installFixtures(scenario) }
        try task.id.write(to: files.taskFile, atomically: true, encoding: .utf8)
        return task.id
    }

    static func runEngine(_ mode: SmokeCase, files: SmokeFiles, crashAtMarker: Bool = false, recover: Bool = false) async throws {
        let id = try String(contentsOf: files.taskFile, encoding: .utf8)
        let store = try HubStore(directory: files.db)
        let engine = HubEngine(store: store, workspaceRoot: files.managed,
                               availableExecutables: mode.fixture.map(files.installedExecutables))
        if recover {
            try await engine.recover()
            let interrupted = try store.task(id)
            try require(interrupted.attempts.count == 1 && interrupted.attempts[0].state == .interrupted,
                        "Restart must recover the prior attempt without redispatch")
            try require(interrupted.state == .needsUser || interrupted.state == .paused, "Recovery must require a resume")
            try await engine.resume(id)
        } else {
            try await engine.start(id)
        }
        var controlled = false
        var observedOverlap = false
        let end = Date().addingTimeInterval(mode.isTeam ? 350 : (mode.fixture == nil ? 200 : 70))
        do {
            while true {
                let task = try store.task(id)
                if mode.isTeam && !observedOverlap {
                    let active = task.attempts.filter { $0.state == .running && ["backend","frontend"].contains($0.role) }
                    let matches = active.compactMap { attempt -> (HubAttempt, ProcessIdentity)? in
                        guard let data = attempt.processIdentity,
                              let identity = try? JSONDecoder().decode(ProcessIdentity.self, from: data),
                              ProcessRunner.inspect(identity) == .matching else { return nil }
                        return (attempt, identity)
                    }
                    if matches.count == 2 && Set(matches.map { $0.0.provider }).count == 2 {
                        let observation: [String:Any] = ["observedAt": ISO8601DateFormatter().string(from: Date()),
                            "workers": matches.map { ["attempt": $0.0.id, "role": $0.0.role, "provider": $0.0.provider.rawValue, "pid": $0.1.pid] as [String:Any] }]
                        try JSONSerialization.data(withJSONObject: observation, options: .prettyPrinted)
                            .write(to: files.root.appendingPathComponent("team-overlap.json"), options: .atomic)
                        observedOverlap = true
                    }
                }
                if !controlled && FileManager.default.fileExists(atPath: files.marker.path) {
                    controlled = true
                    if crashAtMarker { _exit(86) } // Actual process death skips shutdown and releases SQLite's owner lock.
                    if mode.fixture == "cancel" { try await engine.cancel(id) }
                    if mode.fixture == "pause" {
                        try await engine.pause(id)
                        try require(try store.task(id).state == .paused, "Pause did not stabilize")
                        try await engine.resume(id)
                    }
                }
                if [.completed,.cancelled,.needsUser].contains(task.state) { break }
                try require(Date() < end, "Timed out. Task \(id) · \(task.state.rawValue)/\(task.phase.rawValue)")
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            try await engine.shutdown()
        } catch {
            try? await engine.shutdown()
            throw error
        }
    }
}
