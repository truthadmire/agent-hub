import Foundation

public struct ProjectCheckCommand: Equatable, Sendable {
    public let name: String
    public let argv: [String]
    public let required: Bool
    public let workingDirectory: String
    public let environment: [String: String]
    public let timeout: TimeInterval

    public init(name: String, argv: [String], required: Bool = true,
                workingDirectory: String = ".", timeout: TimeInterval = 300, environment: [String: String] = [:]) {
        self.name = name
        self.argv = argv
        self.required = required
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.environment = environment
    }
}

public enum PreviewConfiguration: Equatable, Sendable {
    case command(argv: [String], workingDirectory: String = ".")
    case staticSite(directory: String)
}

public struct ProjectInspection: Sendable {
    public var stack: [String] = []
    public var checks: [ProjectCheckCommand] = []
    public var preview: PreviewConfiguration?
    public var instructions: [String] = []
    public var installCommand: [String]?
}

public enum ProjectToolsError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return reason }
    }
}

public enum ProjectTools {
    public static let allowedEnvironmentNames = ["APP_ENV", "BUILD_MODE", "CI", "LANG", "LC_ALL", "LOG_LEVEL", "NODE_ENV", "TZ"]

    /// Inspect manifests without loading a project's executable configuration.
    public static func detect(in root: URL) -> ProjectInspection {
        var result = ProjectInspection()
        func exists(_ name: String) -> Bool { file(in: root, relative: name) != nil }
        func add(_ name: String, _ argv: [String]) {
            result.checks.append(.init(name: name, argv: argv))
        }
        result.instructions = ["AGENTS.md", "README.md", "CONTRIBUTING.md"].filter(exists)
        if exists("package.json") {
            result.stack.append("Node.js")
            let manifest = json(in: root, name: "package.json")
            let declared = (manifest["packageManager"] as? String).flatMap { $0.components(separatedBy: "@").first }
            let managers: [String] = ["pnpm", "yarn", "npm"]
            let manager: String = managers.first { $0 == declared }
                ?? (exists("pnpm-lock.yaml") ? "pnpm" : exists("yarn.lock") ? "yarn" : "npm")
            let scripts = manifest["scripts"] as? [String: String] ?? [:]
            let usesLock = exists("package-lock.json") || exists("npm-shrinkwrap.json")
            result.installCommand = [manager, manager == "npm" && usesLock ? "ci" : "install"]
            for key in ["lint", "typecheck", "type-check", "check", "test", "build"] {
                guard let script = scripts[key], !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !script.contains("Error: no test specified") else { continue }
                add("\(manager) · \(key)", [manager, "run", key])
            }
            for key in ["dev", "preview", "start"] {
                guard let script = scripts[key], !script.isEmpty else { continue }
                var arguments = [manager, "run", key]
                let flags: [String]
                let tokens = script.split(whereSeparator: \.isWhitespace).map(String.init)
                if tokens.contains("vite") || tokens.contains("astro") || tokens.contains("nuxt") {
                    flags = ["--host", "127.0.0.1", "--port", "{port}"] + (tokens.contains("vite") ? ["--strictPort"] : [])
                } else if tokens.contains("next") {
                    flags = ["--hostname", "127.0.0.1", "--port", "{port}"]
                } else {
                    flags = [] // Other scripts may honor the injected HOST and PORT.
                }
                if !flags.isEmpty && manager == "npm" { arguments.append("--") }
                arguments.append(contentsOf: flags)
                result.preview = .command(argv: arguments)
                break
            }
        }
        if exists("Package.swift") {
            result.stack.append("Swift")
            // The native backend works inside the task sandbox without a shared
            // Xcode build service. The outer seatbelt still applies to manifests/plugins.
            add("Swift build", ["swift", "build", "--disable-sandbox", "--build-system", "native"])
            if directory(in: root, relative: "Tests") != nil
                || source(in: root, name: "Package.swift").contains(".testTarget(") {
                add("Swift tests", ["swift", "test", "--disable-sandbox", "--build-system", "native"])
            }
        }
        if exists("Cargo.toml") {
            result.stack.append("Rust")
            add("Cargo tests", ["cargo", "test"])
        }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        if ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "pytest.ini"].contains(where: exists)
            || children.contains(where: { $0.hasSuffix(".py") && exists($0) }) {
            result.stack.append("Python")
            let localPython = root.appendingPathComponent(".venv/bin/python").path
            let python = FileManager.default.isExecutableFile(atPath: localPython) ? "./.venv/bin/python" : "python3"
            let hints = ["pyproject.toml", "requirements.txt", "requirements-dev.txt", "setup.cfg"]
                .map { source(in: root, name: $0) }.joined()
            let tests = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tests").path)) ?? []
            let unitTests = tests.filter { $0.hasPrefix("test") && $0.hasSuffix(".py") }
            if exists("pytest.ini") || hints.contains("pytest") ||
                unitTests.contains(where: { !source(in: root, name: "tests/" + $0).contains("unittest") }) {
                add("Pytest", [python, "-B", "-m", "pytest"])
            } else if !unitTests.isEmpty {
                add("Python unit tests", [python, "-B", "-c", PythonChecks.unitTests])
            } else {
                add("Python syntax", [python, "-B", "-I", "-c", PythonChecks.syntax])
            }
        }
        if let site = ["dist", "build", "public", "."].first(where: { exists($0 + "/index.html") }) {
            if result.preview == nil { result.preview = .staticSite(directory: site) }
            if result.stack.isEmpty {
                result.stack.append("静态网站")
                let check = ProjectCheckCommand(name: "HTML entry and local assets",
                                                argv: ["python3", "-I", "-B", "-c", PythonChecks.html],
                                                workingDirectory: site)
                result.checks.append(check)
            }
        }
        return result
    }

    /// Discover real deliverables in conventional output directories. Keep the paths to
    /// directories as well, so unrecognized project-specific output can still be inspected.
    public static func artifacts(in root: URL) -> [URL] {
        let locations = ["dist", "build", "target/release", "target/debug", ".build/release", ".build/debug",
                         ".build/out/Products/Release", ".build/out/Products/Debug",
                         "build/Release", "build/Debug", ".next"]
        let folders = locations.compactMap { directory(in: root, relative: $0) }
        var products = Set<URL>()
        for folder in [root] + folders {
            let contents = (try? FileManager.default.contentsOfDirectory(at: folder,
                        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                        options: [.skipsHiddenFiles])) ?? []
            for path in contents {
                guard let relativePath = relative(path, under: root) else { continue }
                if path.pathExtension == "app", let application = directory(in: root, relative: relativePath) {
                    products.insert(application)
                } else if folder != root, let file = file(in: root, relative: relativePath),
                          (["whl", "dmg", "pkg", "zip"].contains(file.pathExtension) || file.lastPathComponent == "index.html" ||
                           file.lastPathComponent.hasSuffix(".tar.gz") ||
                           (file.pathExtension.isEmpty && FileManager.default.isExecutableFile(atPath: file.path))) {
                    products.insert(file)
                }
            }
        }
        return products.sorted { $0.path < $1.path } + Set(folders).sorted { $0.path < $1.path }
    }

    static func relative(_ url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let targetPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        if rootPath == targetPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return targetPath.hasPrefix(prefix) ? String(targetPath.dropFirst(prefix.count)) : nil
    }

    private static func candidate(in root: URL, relative path: String) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        return relative(url, under: root) != nil ? url : nil
    }

    static func file(in root: URL, relative path: String) -> URL? {
        guard let url = candidate(in: root, relative: path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    public static func directory(in root: URL, relative path: String) -> URL? {
        guard let url = candidate(in: root, relative: path),
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return url
    }

    private static func source(in root: URL, name: String) -> String {
        guard let url = file(in: root, relative: name),
              let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 1_048_576)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func json(in root: URL, name: String) -> [String: Any] {
        let data = Data(source(in: root, name: name).utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

private enum PythonChecks {
    static let unitTests = """
    import unittest, sys
    suite = unittest.defaultTestLoader.discover("tests")
    if not suite.countTestCases():
        sys.exit("No Python unit tests discovered")
    sys.exit(0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1)
    """
    static let syntax = """
    import os, sys, tokenize
    count = 0
    for folder, dirs, names in os.walk("."):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in {"node_modules","build","dist","target","venv","__pycache__"}]
        for name in names:
            if name.endswith(".py"):
                path = os.path.join(folder, name)
                if os.path.islink(path): continue
                with tokenize.open(path) as f: compile(f.read(), path, "exec")
                count += 1
    if not count: sys.exit("No Python sources found")
    print("Compiled", count, "Python source files")
    """
    static let html = """
    from html.parser import HTMLParser
    from pathlib import Path
    from urllib.parse import urlsplit, unquote
    import sys
    root = Path.cwd().resolve()
    class Check(HTMLParser):
        def __init__(self):
            super().__init__()
            self.tags = 0
            self.assets = 0
        def handle_starttag(self, tag, pairs):
            self.tags += 1
            attrs = dict(pairs)
            ref = attrs.get("src") if tag in ("img","script","video","audio","source") else attrs.get("href") if tag == "link" and "stylesheet" in (attrs.get("rel") or "").split() else ""
            if not ref: return
            url = urlsplit(ref)
            if url.scheme or url.netloc or not url.path: return
            asset = (root / unquote(url.path).lstrip("/")).resolve()
            if root not in asset.parents or not asset.is_file():
                sys.exit("Missing or out-of-scope local asset: " + url.path)
            self.assets += 1
    check = Check()
    check.feed((root / "index.html").read_text(encoding="utf-8-sig"))
    check.close()
    if not check.tags: sys.exit("No HTML elements in index.html")
    print("Parsed index.html and checked", check.assets, "local asset references")
    """
}
