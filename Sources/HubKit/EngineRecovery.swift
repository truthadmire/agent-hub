import Foundation
import HubGit
import HubProcess
import HubProviders

extension HubEngine {
    public func startPreview(_ taskID: String, root requested: URL, configuration: PreviewConfiguration,
                             environment: [String:String] = [:]) async throws -> URL {
        let task = try store.task(taskID)
        guard !stopping, !held.contains(taskID), !jobs.values.contains(where: { $0.taskID == taskID }),
              [.completed,.needsUser,.paused].contains(task.state), task.workspace != nil else {
            throw EngineError("请等待任务工作区停止写入后再预览。")
        }
        if task.state == .paused, case .command = configuration { throw EngineError("暂停的任务只能查看已保存的静态预览。") }
        let work = try workspace(task)
        guard ProjectTools.relative(requested, under: work.path) != nil else { throw EngineError("预览目录不属于此任务的受管工作区。") }
        held.insert(taskID)
        defer { held.remove(taskID); kick() }
        let url = try await PreviewManager.shared.start(taskID: taskID, root: requested, configuration: configuration, environment: environment)
        let current = try store.task(taskID)
        guard !stopping && current.state == task.state && current.generation == task.generation else {
            await PreviewManager.shared.stop(taskID: taskID)
            throw CancellationError()
        }
        return url
    }

    /// Reuse only a worktree whose previous writer is gone, after an explicit Resume.
    /// A live or ambiguous writer is never signalled using a persisted PID.
    func reconcileSavedWork(_ task: HubTask) async throws {
        guard task.workspace != nil else { return }
        let git = try service(), work = try workspace(task)
        var recovered: [String:(WorkspaceReference,[String])] = [:]
        var revalidated = Set<String>()
        for attempt in task.attempts where attempt.requirementRevision == task.requirementRevision && attempt.planRevision == task.planRevision {
            guard let item = task.plan?.items.first(where: { $0.id == attempt.itemID }),
                  item.state != .integrated, item.workspace?.id == attempt.workspace?.id || item.workspace == nil else { continue }
            if attempt.state == .interrupted {
                if let data = attempt.processIdentity {
                    let identity = try JSONDecoder().decode(ProcessIdentity.self, from: data)
                    var presence = ProcessRunner.inspect(identity)
                    for _ in 0..<15 where presence == .matching {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        presence = ProcessRunner.inspect(identity)
                    }
                    guard presence == .gone else {
                        throw EngineError("尚无法确认此前的执行进程已退出。其工作区和 PID 记录已保留，请在该进程退出后重试。")
                    }
                }
                let worker = try attemptWorkspace(attempt, task: task)
                _ = try git.checkpoint(worker, message: "Recover interrupted attempt " + item.title)
                let paths = try git.changedPaths(of: worker)
                guard paths.allSatisfy({ path in item.writeScope.contains { PlanRules.covers($0, path) } }) else {
                    throw EngineError("中断前的更改超出了分配范围。请检查保存的尝试工作树，或修改计划。")
                }
                recovered[attempt.id] = (try reference(worker),paths)
            }
            if item.state == .delivered, attempt.state == .succeeded, attempt.generation != task.generation {
                let worker = try attemptWorkspace(attempt, task: task)
                guard worker.baseline == attempt.workspace?.baseCommit, try git.head(of: worker) == attempt.workspace?.snapshot,
                      try git.status(of: worker).isEmpty else { throw EngineError("任务中断后，已交付的工作树发生了变化。") }
                let paths = try git.changedPaths(of: worker)
                guard paths.allSatisfy({ path in item.writeScope.contains { PlanRules.covers($0, path) } }) else {
                    throw EngineError("恢复的交付结果包含超出分配范围的更改。")
                }
                revalidated.insert(attempt.id)
            }
        }
        guard try store.task(task.id).generation == task.generation else { throw CancellationError() }
        if !recovered.isEmpty || !revalidated.isEmpty || task.plan?.items.contains(where: { $0.state == .running }) == true {
            try store.updateTask(task.id, kind: "recovery.checkpoint", detail: "已恢复 \(recovered.count) 个检查点，并重新核验 \(revalidated.count) 项交付结果。") { t in
                guard t.generation == task.generation, t.requirementRevision == task.requirementRevision else { throw CancellationError() }
                for i in t.attempts.indices {
                    if let (ref,paths) = recovered[t.attempts[i].id] {
                        t.attempts[i].workspace = ref
                        t.attempts[i].changedPaths = paths
                        t.handoffs.append(Self.handoff(t, from: t.attempts[i], next: "从本次尝试恢复的检查点继续。"))
                    }
                    if revalidated.contains(t.attempts[i].id) { t.attempts[i].revalidatedGeneration = t.generation }
                }
                if var plan = t.plan {
                    for i in plan.items.indices where plan.items[i].state == .running { plan.items[i].state = .pending }
                    t.plan = plan
                }
            }
        }
        if task.attentionReason == "merge_conflict",
           let item = task.plan?.items.first(where: { $0.state == .delivered }),
           let attempt = task.attempts.last(where: { $0.itemID == item.id && $0.state == .succeeded && $0.planRevision == task.planRevision }),
           let expected = attempt.workspace?.snapshot, let parent = task.workspace?.snapshot {
            let worker = try attemptWorkspace(attempt, task: task)
            let status = try git.integrate(attempt: worker, into: work, expectedAttemptHead: expected, expectedTaskHead: parent)
            if case .conflict(let files) = status {
                guard files.isEmpty else { throw EngineError("请先解决以下文件的冲突并暂存更改：" + files.joined(separator: ", ")) }
                _ = try git.finishConflict(in: work, expectedTaskHead: parent, expectedAttemptHead: expected)
            }
        }
    }

    func addFollowUpIfNeeded(_ t: HubTask, routes: [String:ProviderID]) throws -> Bool {
        let pending = try store.pendingUserMessages(taskID: t.id, requirementRevision: t.requirementRevision, limit: 100)
        guard let message = pending.first else { return false }
        let role: String
        if message.recipient == "task" {
            role = routes["lead"] != nil ? "lead" : (routes.keys.sorted().first ?? "")
        } else { role = message.recipient }
        guard let provider = routes[role] else { throw EngineError("一条消息正在等待\(HubPresentation.roleTitle(role))角色处理。请先启用该角色或为其更换连接。") }
        let source = message.itemID.flatMap { id in t.plan?.items.first { $0.id == id } }
        let id = "followup-\(message.sequence)"
        guard t.plan?.items.contains(where: { $0.id == id }) != true else {
            throw EngineError("补充消息尚未送达。请先检查已保存的消息。")
        }
        var item = WorkItem(id: id, title: "处理用户的补充消息", role: role, provider: provider)
        item.dependencies = t.plan?.items.map(\.id) ?? []
        item.readScope = source?.readScope ?? ["."]
        item.writeScope = source?.writeScope ?? ["."]
        item.inputs = ["补充消息 #\(message.sequence)，接收方为\(HubPresentation.roleTitle(message.recipient))。"]
        item.deliverables = ["回应这条补充消息，并在授权范围内完成相关更改。"]
        try store.updateTask(t.id, kind: "message.followup_scheduled", detail: message.id) { task in
            task.planRevision += 1
            task.plan?.revision = task.planRevision
            task.plan?.items.append(item)
        }
        return true
    }
}
