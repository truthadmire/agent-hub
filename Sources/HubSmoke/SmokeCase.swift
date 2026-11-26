import Foundation
import HubGit
import HubKit
import HubProviders

struct SmokeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw SmokeError(message) }
}

enum SmokeCase {
    case fixture(String)
    case live(ProviderID)
    case liveTeam

    static let fixtureNames = ["single", "gallery", "repair", "stalled", "quota", "auth", "protocol", "pause", "cancel", "restart"]
    var label: String {
        switch self { case .fixture(let name): return "fixture-\(name)"
        case .live(let provider): return "live-\(provider.rawValue)"
        case .liveTeam: return "live-team" }
    }
    var fixture: String? {
        if case .fixture(let name) = self { return name }
        return nil
    }
    var isTeam: Bool {
        if case .liveTeam = self { return true }
        return false
    }
    var provider: ProviderID {
        if case .live(let provider) = self { return provider }
        return .codex
    }
}

struct SmokeFiles {
    let root: URL
    var source: URL { root.appendingPathComponent("示例 repository") }
    var db: URL { root.appendingPathComponent("data") }
    var managed: URL { root.appendingPathComponent("managed") }
    var fixtures: URL { root.appendingPathComponent("fixture") }
    var marker: URL { fixtures.appendingPathComponent("interrupted") }
    var taskFile: URL { root.appendingPathComponent("task-id.txt") }

    static func create() throws -> Self {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("agent-hub-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return Self(root: root)
    }

    static var examples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Examples")
    }

    func seed(_ mode: SmokeCase) throws -> HubProject {
        let fm = FileManager.default
        if mode.fixture == "gallery" {
            try fm.copyItem(at: Self.examples.appendingPathComponent("Gallery/seed"), to: source)
        } else {
            try fm.createDirectory(at: source, withIntermediateDirectories: false)
            for name in mode.isTeam ? ["frontend.txt", "backend.txt"] : ["status.txt"] {
                try "pending\n".write(to: source.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        _ = try git(["init", "-b", "main"], at: source)
        _ = try git(["add", "."], at: source)
        _ = try git(["commit", "-m", "Seed synthetic Agent Hub project"], at: source)
        let info = try GitWorkspaceService(managedRoot: managed).inspectProject(at: source)
        var project = HubProject(id: info.id, name: "Field Notes · " + mode.label, path: info.path.path)
        project.branch = info.branch
        project.baseCommit = info.head
        let inspection = ProjectTools.detect(in: source)
        project.stack = inspection.stack
        project.instructions = inspection.instructions
        return project
    }

    func installFixtures(_ scenario: String) throws -> [String:URL] {
        let fm = FileManager.default
        let bin = fixtures.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try JSONEncoder().encode(["scenario":scenario]).write(to: fixtures.appendingPathComponent("fixture.json"))
        if scenario == "gallery" {
            try fm.copyItem(at: Self.examples.appendingPathComponent("Gallery/solution"),
                            to: fixtures.appendingPathComponent("solution"))
        }
        let providers: [ProviderID] = scenario == "gallery" ? ProviderID.allCases :
            (scenario == "quota" ? [.codex, .antigravity] : [.codex])
        var installed: [String:URL] = [:]
        for provider in providers {
            let destination = bin.appendingPathComponent(provider.executableName)
            try fm.copyItem(at: Self.examples.appendingPathComponent("FixtureCLI/provider.py"), to: destination)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
            installed[provider.rawValue] = destination
        }
        return installed
    }

    func installedExecutables(_ scenario: String) -> [String:URL] {
        var known: [String:URL] = [:]
        for id in ProviderID.allCases {
            let executable = fixtures.appendingPathComponent("bin/" + id.executableName)
            if FileManager.default.isExecutableFile(atPath: executable.path) { known[id.rawValue] = executable }
        }
        return known
    }

    func task(for mode: SmokeCase, project: HubProject) -> HubTask {
        let gallery = mode.fixture == "gallery"
        var config = HubConfiguration()
        config.maxConcurrent = gallery ? 2 : 1
        config.maxAttempts = gallery ? 5 : (mode.fixture == nil ? 1 : 4)
        config.maxRetries = mode.fixture == "quota" ? 1 : 0
        config.maxRepairs = ["repair", "stalled"].contains(mode.fixture ?? "") ? 1 : 0
        config.maxSeconds = mode.fixture == nil ? 160 : 45
        config.paidProviders = gallery || mode.provider == .dsh ? [.dsh] : []
        config.allowedFallbacks = mode.fixture == "quota" ? [.antigravity] : []
        if mode.isTeam {
            config.roles = ["lead": .codex, "backend": .codex, "frontend": .antigravity]
            config.enabledRoles = ["lead", "backend", "frontend"]
            config.disabledProviders = [.dsh]
            config.maxAttempts = 3
            config.maxConcurrent = 2
            config.maxSeconds = 300
            config.maxRetries = 0
            config.maxRepairs = 0
            config.paidProviders = []
            config.allowedFallbacks = []
            config.verificationCommands = [["/usr/bin/grep","-Fx","Ready to browse","frontend.txt"],
                                           ["/usr/bin/grep","-Fx","ready","backend.txt"]]
        } else if gallery {
            config.verificationCommands = [["/usr/bin/env","python3","-B","-m","unittest","discover","-s","tests","-v"]]
            config.previewCommand = ["/usr/bin/env","python3","-B","server.py","--port","{port}"]
        } else {
            config.roles = Dictionary(uniqueKeysWithValues: PlanRules.roles.map { ($0, mode.provider) })
            config.enabledRoles = ["lead","backend"]
            let enabled = mode.fixture == "quota" ? [ProviderID.codex, .antigravity] : [mode.provider]
            config.disabledProviders = ProviderID.allCases.filter { !enabled.contains($0) }
            config.verificationCommands = [["/usr/bin/grep","-Fx","verified","status.txt"]]
        }
        if mode.isTeam {
            let goal = """
                Deliver the two independent pieces of this synthetic release status update. The frontend role owns only frontend.txt and must replace its entire contents with the line Ready to browse followed by one newline. The backend role owns only backend.txt and must replace its entire contents with the line ready followed by one newline. Assign the two work items to their respective roles. Both can begin immediately and have no dependencies. Each worker must make the actual edit in its own worktree and read it back. Preserve the other file. No commits or additional files, tests, planning questions, shared interfaces or review work are requested. The two configured exact-line checks provide complete acceptance criteria and are run by the hub. Use empty acceptance and questions arrays in the plan as no additional human check is required.
                """
            return .init(projectID: project.id, title: mode.label, goal: goal, overrides: config)
        }
        let goal = gallery ? "Add category filtering, paginated photo API and empty state to Field Notes. Follow the contract in README.md, preserve the layout, and add integration tests." :
            "Edit status.txt in this synthetic managed repository so its entire contents are verified followed by one newline. Make and verify the actual file edit. No commits, other files, network or external resources are needed."
        return .init(projectID: project.id, title: mode.label, goal: goal, overrides: config)
    }

    /// All caller arguments are fixture constants, checked Git refs, or paths under this temporary run.
    func git(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Agent Hub Example", "-c", "user.email=example@invalid",
                             "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        process.standardOutput = pipe
        let errorURL = root.appendingPathComponent("git-stderr-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else { throw SmokeError("Cannot capture Git diagnostics") }
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? errors.close(); try? FileManager.default.removeItem(at: errorURL) }
        process.standardError = errors
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw SmokeError("Git command failed: " + (try String(contentsOf: errorURL, encoding: .utf8)))
        }
        return output.trimmingCharacters(in: .newlines)
    }
}
