import AppKit
import Combine
import CryptoKit
import Foundation
import HubGit
import HubKit
import HubProviders

enum TaskAction { case start, pause, resume, cancel, retry, archive, unarchive }

@MainActor
final class HubController: ObservableObject {
    @Published private(set) var projects: [HubProject] = []
    @Published private(set) var tasks: [HubTask] = []
    @Published var connections: [ProviderID: ProviderConnection] = [:]
    @Published var detectingProviders: Set<ProviderID> = []
    @Published var testingProviders: Set<ProviderID> = []
    @Published var errorMessage: String?
    @Published private(set) var revisionClock = 0
    @Published var selectedProjectID: String? {
        didSet {
            if oldValue != selectedProjectID {
                preferences.set(selectedProjectID, forKey: "selectedProject")
                if let selectedTaskID, tasks.first(where: { $0.id == selectedTaskID })?.projectID != selectedProjectID {
                    self.selectedTaskID = nil
                }
            }
        }
    }
    @Published var selectedTaskID: String? {
        didSet { preferences.set(selectedTaskID, forKey: "selectedTask") }
    }

    let preferences: UserDefaults
    private(set) var store: HubStore?
    private(set) var git: GitWorkspaceService?
    private(set) var engine: HubEngine?
    private var previewTrees: [String: String] = [:]
    private var knownTaskVersions: [String: Date] = [:]
    private var observedChange: Int64 = -1
    private var polling: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var shuttingDown = false

    nonisolated static var settingsDefaults: UserDefaults {
        guard let path = ProcessInfo.processInfo.environment["AGENTHUB_DATA_DIR"], !path.isEmpty else {
            #if DEBUG
            return UserDefaults(suiteName: "org.agenthub.desktop.development") ?? .standard
            #else
            return .standard
            #endif
        }
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return UserDefaults(suiteName: "org.agenthub.desktop.test." + digest) ?? .standard
    }

    nonisolated static func dataDirectory() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["AGENTHUB_DATA_DIR"], !path.isEmpty {
            guard path.hasPrefix("/"), path != "/" else {
                throw HubStoreError.invalid("AGENTHUB_DATA_DIR 需要指向专用的绝对路径。")
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        #if DEBUG
        return support.appendingPathComponent("org.agenthub.desktop.development", isDirectory: true)
        #else
        return support.appendingPathComponent("org.agenthub.desktop", isDirectory: true)
        #endif
    }

    init() {
        preferences = Self.settingsDefaults
        selectedProjectID = preferences.string(forKey: "selectedProject")
        selectedTaskID = preferences.string(forKey: "selectedTask")
        do {
            let data = try Self.dataDirectory()
            let workspaces = data.appendingPathComponent("Managed", isDirectory: true)
            let localStore = try HubStore(directory: data)
            let localGit = try GitWorkspaceService(managedRoot: workspaces)
            let runtime = HubEngine(store: localStore, workspaceRoot: workspaces)
            store = localStore
            git = localGit
            engine = runtime
            refresh()
            startup = Task { [weak self] in
                do { try await runtime.recover() }
                catch { self?.showError(error) }
                self?.refresh()
            }
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 650_000_000) } catch { return }
                    guard let self, !self.shuttingDown else { return }
                    await self.pollChanges()
                }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.shuttingDown else { return }
                    do { try await runtime.reconcile() } catch { self.showError(error) }
                    self.refresh()
                }
            }
        } catch {
            showError(error)
        }
        if store != nil { Task { [weak self] in await self?.refreshConnections() } }
    }

    deinit {
        polling?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    var hasActiveTasks: Bool { tasks.contains { $0.state == .running || $0.state == .pausing } }

    func refresh() {
        guard let store else { return }
        let change = store.changeCounter
        guard observedChange != change else { return }
        do {
            apply(projects: try store.projects(), updates: try store.taskUpdates(known: knownTaskVersions), counter: change)
        } catch { showError(error) }
    }

    private func pollChanges() async {
        guard let store else { return }
        let counter = store.changeCounter
        guard counter != observedChange else { return }
        let previous = observedChange
        let versions = knownTaskVersions
        do {
            let (projects, updates) = try await Task.detached(priority: .utility) {
                (try store.projects(), try store.taskUpdates(known: versions))
            }.value
            // A user action may have refreshed the board while this read was in flight.
            guard previous == observedChange, !shuttingDown else { return }
            apply(projects: projects, updates: updates, counter: counter)
        } catch { showError(error) }
    }

    private func apply(projects currentProjects: [HubProject], updates: [HubTask], counter: Int64) {
        if currentProjects != projects { projects = currentProjects }
        if !updates.isEmpty {
            var byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            for task in updates {
                knownTaskVersions[task.id] = task.updatedAt
                byID[task.id] = task
            }
            tasks = byID.values.sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
        }
        if !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = projects.first?.id
        }
        if let id = selectedTaskID, !tasks.contains(where: { $0.id == id && $0.projectID == selectedProjectID }) {
            selectedTaskID = nil
        }
        observedChange = counter
        revisionClock &+= 1
    }

    func showError(_ error: Error) {
        errorMessage = HubRedaction.text(error.localizedDescription)
    }

    private func dataServices() throws -> (HubStore, GitWorkspaceService) {
        guard let store, let git, !shuttingDown else { throw HubStoreError.invalid(errorMessage ?? "本地服务暂不可用。") }
        return (store, git)
    }

    @discardableResult
    func importProject(at directory: URL, initialize: Bool) async throws -> HubProject {
        let (store, git) = try dataServices()
        let (source, inspection) = try await Task.detached(priority: .userInitiated) {
            let source = try initialize ? git.initializeProject(at: directory) : git.inspectProject(at: directory)
            return (source, ProjectTools.detect(in: source.path))
        }.value
        let registered = try store.projects()
        if let moved = registered.first(where: { $0.id == source.id }), moved.path != source.path.path {
            try await relocateProject(projectID: moved.id, at: source.path)
            return try store.project(moved.id)
        }
        let existing = registered.first { $0.path == source.path.path }
        if let existing, existing.id != source.id, UUID(uuidString: existing.id) == nil {
            throw HubStoreError.invalid("这个路径属于另一个已登记的仓库。请先重新定位原项目，或选择新仓库的独立目录。")
        }
        var project = existing ?? HubProject(id: source.id, name: source.path.lastPathComponent, path: source.path.path)
        populate(&project, from: source, inspection: inspection)
        try store.saveProject(project)
        refresh()
        return project
    }

    private func populate(_ project: inout HubProject, from source: GitProject, inspection: ProjectInspection) {
        project.path = source.path.path
        project.branch = source.branch
        project.baseCommit = source.head
        project.isDirty = !source.changes.isEmpty
        project.changedPaths = source.changes.map(\.path)
        project.stack = inspection.stack.isEmpty ? source.technologies : inspection.stack
        project.instructions = inspection.instructions
    }

    func relocateProject(projectID: String, at directory: URL) async throws {
        let (store, git) = try dataServices()
        let original = try store.project(projectID)
        guard let baseline = original.baseCommit else { throw HubStoreError.invalid("缺少可核对的项目基线。") }
        guard !tasks.contains(where: { $0.projectID == projectID && ($0.state == .running || $0.state == .pausing) }) else {
            throw HubStoreError.invalid("请先暂停此项目正在执行的任务，再重新定位仓库。")
        }
        let (source, inspection) = try await Task.detached(priority: .userInitiated) {
            let source = try git.relocateProject(from: URL(fileURLWithPath: original.path), to: directory, expectedCommit: baseline)
            return (source, ProjectTools.detect(in: source.path))
        }.value
        var project = try store.project(projectID)
        populate(&project, from: source, inspection: inspection)
        try store.saveProject(project)
        previewTrees.removeValue(forKey: projectID)
        refresh()
    }

    func workingChanges(projectID: String) async throws -> String {
        let (store, git) = try dataServices()
        let project = try store.project(projectID)
        let (source, preview) = try await Task.detached(priority: .userInitiated) {
            let source = try git.inspectProject(at: URL(fileURLWithPath: project.path))
            return (source, try git.previewUncommitted(in: source))
        }.value
        previewTrees[projectID] = preview.tree
        var lines = source.changes.map { "\($0.code)  \($0.path)" }
        if !preview.excludedPaths.isEmpty { lines.append("快照排除：" + preview.excludedPaths.joined(separator: "、")) }
        let limit = 96 * 1024
        if !preview.patch.isEmpty { lines.append(String(decoding: preview.patch.prefix(limit), as: UTF8.self)) }
        if preview.patch.count > limit { lines.append("仅显示前 96 KiB 差异。") }
        return lines.joined(separator: "\n")
    }

    @discardableResult
    func createTask(projectID: String, goal: String, acceptance: [String], priority: Int,
                    overrides: HubConfiguration, includeUncommitted: Bool = false) async throws -> HubTask {
        let (store, git) = try dataServices()
        let requested = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { throw HubStoreError.invalid("请填写本次开发目标。") }
        let project = try store.project(projectID)
        let source = try await Task.detached(priority: .userInitiated) {
            try git.inspectProject(at: URL(fileURLWithPath: project.path))
        }.value
        let title = requested.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? requested
        var task = HubTask(projectID: projectID, title: title, goal: requested,
                           acceptance: acceptance, priority: priority, overrides: overrides)
        task.includeUncommitted = includeUncommitted
        task.selectedBaseCommit = source.head
        if includeUncommitted {
            guard let tree = previewTrees[projectID] else { throw HubStoreError.invalid("请先预览要纳入的未提交修改。") }
            task.expectedSnapshotID = tree
        }
        let created = try store.createTask(task, requestID: task.id)
        refresh()
        return created
    }

    func perform(_ action: TaskAction, taskID: String) async throws {
        await startup?.value
        guard let store, let engine, !shuttingDown else { throw HubStoreError.invalid("本地调度尚未准备好。") }
        switch action {
        case .start: try await engine.start(taskID)
        case .pause:
            try await engine.pause(taskID)
            await PreviewManager.shared.stop(taskID: taskID)
        case .resume, .retry: try await engine.resume(taskID)
        case .cancel:
            try await engine.cancel(taskID)
            await PreviewManager.shared.stop(taskID: taskID)
        case .archive, .unarchive:
            try store.updateTask(taskID, kind: action == .archive ? "task.archived" : "task.unarchived") {
                guard $0.state != .running && $0.state != .pausing else {
                    throw HubStoreError.invalid("请先暂停、取消或完成此任务，再归档。")
                }
                $0.isArchived = action == .archive
            }
            if action == .archive { await PreviewManager.shared.stop(taskID: taskID) }
        }
        refresh()
    }

    func setPriority(taskID: String, priority: Int) throws {
        let (store, _) = try dataServices()
        try store.updateTask(taskID, kind: "queue.priority", detail: String(priority)) {
            guard $0.state == .queued else { throw HubStoreError.invalid("队列优先级只适用于待开始的任务。") }
            $0.priority = priority
        }
        refresh()
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        polling?.cancel()
        await startup?.value
        do { try await engine?.shutdown() } catch { showError(error) }
        await PreviewManager.shared.stopAll()
        refresh()
    }
}
