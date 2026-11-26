import Foundation
import HubGit
import HubProcess
import HubProviders

/// Only this actor dispatches, integrates and completes work. SQLite owns the durable evidence.
public actor HubEngine {
    let store: HubStore
    let root: URL
    let fixtures: [String:URL]?
    var gitService: GitWorkspaceService?
    var connections: [String:[ProviderID:EngineConnection]] = [:]
    var jobs: [String:EngineJob] = [:]
    var scheduled = false
    var stopping = false
    var held = Set<String>()
    var lastServed: [String:Int] = [:]
    var serial = 0

    public init(store: HubStore, workspaceRoot: URL, availableExecutables: [String:URL]? = nil) {
        self.store = store
        self.root = workspaceRoot
        self.fixtures = availableExecutables
    }

    public func start(_ taskID: String) async throws {
        guard !stopping else { throw EngineError("Agent Hub 正在退出。") }
        let task = try store.task(taskID)
        guard task.state == .queued else { return }
        let config = try store.effectiveConfiguration(for: task)
        try store.updateTask(taskID, kind: "task.started") { t in
            guard t.state == .queued else { return }
            t.runtimeConfig = t.runtimeConfig ?? config
            t.generation += 1
            t.planRevision = max(1, t.planRevision)
            Self.transition(&t, to: .running)
            t.attentionReason = nil
        }
        kick()
    }

    public func resume(_ taskID: String) async throws {
        guard !stopping, !held.contains(taskID) else { return }
        let task = try store.task(taskID)
        if task.state == .queued { try await start(taskID); return }
        guard [.paused,.needsUser].contains(task.state), !jobs.values.contains(where: { $0.taskID == taskID }) else { return }
        held.insert(taskID)
        defer { held.remove(taskID); kick() }
        await PreviewManager.shared.stop(taskID: taskID)
        try await reconcileSavedWork(task)
        guard !stopping, try store.task(taskID).state == task.state else { return }
        let effective = try store.effectiveConfiguration(for: task)
        try store.updateTask(taskID, kind: "task.resumed", detail: "已从保存的工作树继续。中断的步骤将在新的 CLI 会话中执行。") { t in
            t.runtimeConfig = t.runtimeConfig ?? effective
            t.planRevision = max(1, t.planRevision)
            t.generation = max(1, t.generation)
            t.attentionReason = nil
            Self.transition(&t, to: .running)
        }
        connections[taskID] = nil
        kick()
    }

    public func pause(_ taskID: String) async throws {
        let task = try store.task(taskID)
        guard [.running,.queued,.pausing].contains(task.state) else { return }
        try store.updateTask(taskID, kind: "task.pausing", detail: "正在保存工作树并停止此任务启动的进程。") { t in
            Self.transition(&t, to: .pausing)
        }
        held.insert(taskID)
        await drain(taskID)
        await PreviewManager.shared.stop(taskID: taskID)
        try store.updateTask(taskID, kind: "task.paused") { t in
            guard t.state == .pausing else { return }
            Self.transition(&t, to: .paused)
        }
        held.remove(taskID)
        kick()
    }

    public func cancel(_ taskID: String) async throws {
        let task = try store.task(taskID)
        guard task.state != .cancelled && task.state != .completed else { return }
        try store.updateTask(taskID, kind: "task.cancelled", detail: "已停止分派任务。各次尝试的工作树和输出已保留。") { t in
            t.generation += 1
            Self.transition(&t, to: .cancelled)
        }
        await drain(taskID)
        await PreviewManager.shared.stop(taskID: taskID)
        connections[taskID] = nil
        kick()
    }

    public func changeRequirements(_ taskID: String, goal: String, acceptance: [String]) async throws {
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError("请输入任务目标。") }
        let previous = try store.task(taskID)
        guard previous.goal != goal || previous.acceptance != acceptance else { return }
        try await revise(taskID, reason: "用户已修改任务目标或验收条件。") { t in
            t.goal = goal
            t.acceptance = acceptance
        }
    }

    public func addDecision(_ taskID: String, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EngineError("请输入需要共享的决定。") }
        guard try store.task(taskID).decisions.last != text else { return }
        try await revise(taskID, reason: "已更新共享决定，计划将据此重新制定。") { $0.decisions.append(text) }
    }

    public func reassign(_ taskID: String, role: String, provider: ProviderID) async throws {
        guard PlanRules.roles.contains(role) else { throw EngineError("未知角色：\(role)") }
        let current = try store.task(taskID)
        let config = try store.effectiveConfiguration(for: current)
        try await revise(taskID, reason: "用户已将\(HubPresentation.roleTitle(role))角色分配给 \(provider.displayName)。") { t in
            t.overrides.roles[role] = provider
            // Explicit migration of connection availability/authorization is necessary for a newly selected role.
            t.runtimeConfig = config.overriding(with: t.overrides)
        }
    }

    func revise(_ id: String, reason: String, change: (inout HubTask) -> Void) async throws {
        let before = try store.task(id)
        guard before.state != .cancelled, !held.contains(id) else { throw EngineError("任务已取消或正在停止，当前无法修改。") }
        held.insert(id)
        defer { held.remove(id); kick() }
        try store.updateTask(id, kind: "requirements.revised", detail: reason) { t in
            t.handoffs.append(Self.handoff(t, from: t.attempts.last, next: reason))
            change(&t)
            t.requirementRevision += 1
            t.planRevision += 1
            t.generation += 1
            t.plan = nil
            t.phase = .planning
            t.attentionReason = nil
            if t.state == .running { Self.transition(&t, to: .pausing) }
            else if t.state == .completed || t.state == .needsUser { Self.transition(&t, to: .paused) }
        }
        await drain(id)
        await PreviewManager.shared.stop(taskID: id)
        connections[id] = nil
        if before.state == .running {
            try store.updateTask(id, kind: "task.replanning") { t in
                if t.state == .pausing { Self.transition(&t, to: .running) }
            }
        }
    }

    public func recover() async throws {
        guard jobs.isEmpty else { return }
        for task in try store.tasks() where [.running,.pausing].contains(task.state) {
            for attempt in task.attempts where attempt.state.isActive {
                if let data = attempt.processIdentity, let identity = try? JSONDecoder().decode(ProcessIdentity.self, from: data) {
                    let presence = ProcessRunner.inspect(identity)
                    let detail: String
                    switch presence {
                    case .matching: detail = "找到了与记录相符的执行进程"
                    case .gone: detail = "此前的执行进程已退出"
                    case .unverified: detail = "无法核实此前执行进程的身份"
                    }
                    try store.appendEvent(taskID: task.id, kind: "recovery.process", detail: "PID \(identity.pid) · \(detail)", attemptID: attempt.id)
                }
            }
        }
        _ = try store.recoverInterrupted()
    }

    public func reconcile() async throws {
        for t in try store.tasks() where t.state == .running {
            let limit = t.runtimeConfig?.maxSeconds ?? 3600
            if Self.elapsed(t) >= Double(limit) {
                try attention(t.id, code: "time_budget", detail: "任务已达时限。已保存的工作树仍可查看。")
                await drain(t.id)
            }
        }
        kick()
    }

    public func shutdown() async throws {
        stopping = true
        let tasks = try store.tasks().filter { [.running,.pausing].contains($0.state) }
        for t in tasks {
            try store.updateTask(t.id, kind: "task.shutdown") { task in
                task.generation += 1
                Self.transition(&task, to: .needsUser)
                task.attentionReason = "resume_required"
                task.summary = "任务随 Agent Hub 退出而中断。可以从保存的工作树继续。"
            }
        }
        let ids = Set(jobs.values.map(\.taskID)).union(tasks.map(\.id))
        for id in ids { await drain(id) }
        await PreviewManager.shared.stopAll()
    }

    func drain(_ id: String) async {
        let active = jobs.values.filter { $0.taskID == id }.map(\.task)
        for task in active { task.cancel() }
        for task in active { await task.value }
    }

    static func elapsed(_ t: HubTask) -> Double {
        t.elapsedSeconds + (t.runningSince.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
    }

    static func transition(_ t: inout HubTask, to state: TaskState) {
        t.state = state
    }

    func attention(_ id: String, code: String, detail: String) throws {
        try store.updateTask(id, kind: "task.needs_user", detail: detail) { t in
            guard t.state == .running else { return }
            Self.transition(&t, to: .needsUser)
            t.attentionReason = code
            t.summary = detail
        }
    }

    func service() throws -> GitWorkspaceService {
        if let gitService { return gitService }
        let s = try GitWorkspaceService(managedRoot: root)
        gitService = s
        return s
    }

    func workspace(_ task: HubTask) throws -> GitWorkspace {
        guard let uuid = UUID(uuidString: task.id) else { throw EngineError("受管任务 ID 无效。") }
        let git = try service()
        if task.workspace != nil { let existing = try git.workspace(id: uuid); guard existing.taskID == uuid && existing.kind == .task else { throw EngineError("已登记的工作区与当前任务不符。") }; return existing }
        let project = try store.project(task.projectID)
        let source = try git.inspectProject(at: URL(fileURLWithPath: project.path))
        let work = try git.createTask(project: source, id: uuid, includeUncommitted: task.includeUncommitted,
                                      expectedSnapshotID: task.expectedSnapshotID, baseCommit: task.selectedBaseCommit)
        let ref = try reference(work)
        try store.updateTask(task.id, kind: "workspace.created", detail: work.branch) { t in
            t.workspace = ref
        }
        return work
    }

    func attemptWorkspace(_ attempt: HubAttempt, task: HubTask) throws -> GitWorkspace {
        guard let id = UUID(uuidString: attempt.id), let tid = UUID(uuidString: task.id) else { throw EngineError("尝试记录或其所属任务的 ID 无效。") }
        let w = try service().workspace(id: id)
        guard w.taskID == tid && w.kind == .attempt else { throw EngineError("工作区与该任务的尝试记录不符。") }
        return w
    }

    func reference(_ work: GitWorkspace) throws -> WorkspaceReference {
        var ref = WorkspaceReference(id: work.id.uuidString, path: work.path.path, branch: work.branch, baseCommit: work.baseline)
        ref.snapshot = try service().head(of: work)
        return ref
    }

    static func handoff(_ t: HubTask, from: HubAttempt?, next: String) -> HubHandoff {
        var h = HubHandoff(goal: t.goal, requirementRevision: t.requirementRevision, planRevision: t.planRevision, nextAction: next)
        h.fromAttemptID = from?.id
        h.workspace = from?.workspace ?? t.workspace
        h.completed = t.plan?.items.filter { $0.state == .integrated }.map(\.id) ?? []
        h.remaining = t.plan?.items.filter { $0.state != .integrated }.map(\.id) ?? []
        h.decisions = Array(t.decisions.suffix(24))
        h.interfaces = t.plan?.interfaces ?? []
        h.verificationIDs = t.verifications.filter { $0.requirementRevision == t.requirementRevision }.suffix(20).map(\.id)
        h.artifactIDs = t.artifacts.suffix(20).map(\.id)
        h.lastFailure = from?.failure
        h.issues = t.verifications.filter { $0.requirementRevision == t.requirementRevision && $0.required && $0.state == .failed }.suffix(4).map(\.name)
        return h
    }

    func kick() {
        guard !stopping, !scheduled else { return }
        scheduled = true
        Task { await self.pump() }
    }

    func pump() async {
        scheduled = false
        guard !stopping else { return }
        do {
            let candidates = try store.tasks().filter { $0.state == .running && !held.contains($0.id) }
            let ordered = candidates.sorted { a,b in
                let waitA = serial - (lastServed[a.id] ?? 0), waitB = serial - (lastServed[b.id] ?? 0)
                let scoreA = min(100, max(-100, a.priority)) + waitA, scoreB = min(100, max(-100, b.priority)) + waitB
                if scoreA == scoreB { return a.createdAt < b.createdAt }
                return scoreA > scoreB
            }
            for task in ordered {
                do {
                    if try advance(task) { serial += 1; lastServed[task.id] = serial; kick() }
                } catch {
                    try attention(task.id, code: "runtime_error", detail: error.localizedDescription)
                }
            }
        } catch {
            // A failed durable store cannot safely issue new executions. The next explicit reconciliation retries.
        }
    }

    func launch(taskID: String, key: String, provider: ProviderID? = nil, operation: @escaping @Sendable () async throws -> Void) {
        let handle = Task {
            do { try await operation() }
            catch is CancellationError { }
            catch { try? attention(taskID, code: "execution_error", detail: error.localizedDescription) }
            self.jobs[key] = nil
            self.kick()
        }
        jobs[key] = EngineJob(taskID: taskID, provider: provider, task: handle)
    }
}

struct EngineConnection: Sendable {
    let url: URL
    let paid: Bool
}

struct EngineJob {
    let taskID: String
    let provider: ProviderID?
    let task: Task<Void,Never>
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
