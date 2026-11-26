import Foundation
import HubGit
import HubProviders

extension HubEngine {
    func discover(_ t: HubTask, config: HubConfiguration) async throws {
        var ready: [ProviderID:EngineConnection] = [:]
        var reasons: [String] = []
        for provider in ProviderID.allCases where !(config.disabledProviders ?? []).contains(provider) {
            try Task.checkCancellation()
            if let fixtures {
                if let url = fixtures[provider.rawValue] { ready[provider] = EngineConnection(url: url, paid: false) }
                continue
            }
            let url = config.executableOverrides[provider.rawValue].map { URL(fileURLWithPath: $0) }
            let probe = await ProviderDiscovery.detect(provider, override: url)
            guard let path = probe.executable, probe.compatible else { reasons.append("\(provider.displayName)：\(probe.detail)"); continue }
            let paid: Bool
            switch probe.auth {
            case .subscription: paid = false
            case .externalAPIKey:
                reasons.append("\(provider.displayName)：此连接需要官方订阅登录；外部 API key 不用于此任务。")
                continue
            case .apiKeySaved:
                guard provider == .dsh else {
                    reasons.append("\(provider.displayName)：仅支持用户明确授权的 DSH API key。")
                    continue
                }
                paid = true
            default:
                reasons.append("\(provider.displayName)：\(probe.detail)")
                continue
            }
            guard !paid || (config.paidProviders ?? []).contains(provider) else { reasons.append("\(provider.displayName)：使用此连接前，请在设置中授权 API 计费。"); continue }
            ready[provider] = EngineConnection(url: path, paid: paid)
        }
        try Task.checkCancellation()
        guard try same(t) else { return }
        connections[t.id] = ready
        if ready.isEmpty {
            try attention(t.id, code: "connection_required", detail: (["请在连接设置中配置至少一个可用连接，然后继续任务。"] + reasons).joined(separator: "\n"))
        }
    }

    func routes(_ config: HubConfiguration, _ ready: [ProviderID:EngineConnection]) -> [String:ProviderID] {
        var result: [String: ProviderID] = [:]
        for role in config.enabledRoles ?? PlanRules.roles {
            guard let primary = config.roles[role] else { continue }
            if ready[primary] != nil { result[role] = primary; continue }
            // A single connected subscription can do suitable work without buying another source.
            if ready.count == 1, let single = ready.first, !single.value.paid {
                result[role] = single.key
            } else if let alternate = (config.allowedFallbacks ?? []).first(where: {
                guard let info = ready[$0] else { return false }
                return !info.paid || ((config.paidProviders ?? []).contains($0) && config.maxCostUSD != nil)
            }) {
                result[role] = alternate
            }
        }
        return result
    }

    func same(_ task: HubTask) throws -> Bool {
        let current = try store.task(task.id)
        return current.state == .running && current.generation == task.generation &&
            current.planRevision == task.planRevision && current.requirementRevision == task.requirementRevision
    }

    func advance(_ t: HubTask) throws -> Bool {
        guard let config = t.runtimeConfig else { throw EngineError("缺少任务启动时保存的配置。") }
        if Self.elapsed(t) >= Double(config.maxSeconds ?? 3600) {
            try attention(t.id, code: "time_budget", detail: "任务已达时限。已有检查点和验证记录可在工作区中查看。")
            return false
        }
        if connections[t.id] == nil, t.phase == .verifying, t.plan?.items.isEmpty == false,
           t.plan?.items.allSatisfy({ $0.state == .integrated }) == true,
           try store.pendingUserMessages(taskID: t.id, requirementRevision: t.requirementRevision, limit: 1).isEmpty {
            guard !jobs.values.contains(where: { $0.taskID == t.id }) else { return false }
            let work = try workspace(t)
            launch(taskID: t.id, key: "verify/" + t.id) { try await self.verify(t, work: work, baseline: false) }
            return false
        }
        guard let ready = connections[t.id] else {
            let key = "discover/" + t.id
            if jobs[key] == nil { launch(taskID: t.id, key: key) { try await self.discover(t, config: config) } }
            return false
        }
        let assignments = routes(config, ready)
        guard !assignments.isEmpty else {
            try attention(t.id, code: "role_unavailable", detail: "请启用至少一个使用已授权连接的角色，然后继续任务。")
            return false
        }
        let work = try workspace(t)
        if t.workspace == nil { return true }
        if let plan = t.plan, !plan.questions.isEmpty {
            try attention(t.id, code: "planning_question", detail: plan.questions.joined(separator: "\n"))
            return false
        }
        let active = jobs.values.filter { $0.taskID == t.id }
        if t.plan == nil {
            let primaryRole = assignments["lead"] != nil ? "lead" : assignments.keys.sorted()[0]
            if Set(assignments.values).count == 1 {
                let draft = PlanRules.single(task: t, role: primaryRole, provider: assignments[primaryRole]!)
                try store.updateTask(t.id, kind: "plan.created", detail: "当前只有一个可用连接，将在独立工作树中完成一项实现任务。") {
                    $0.plan = draft
                    $0.phase = .implementing
                }
                return true
            }
            guard active.isEmpty else { return false }
            var planner = WorkItem(id: "@plan", title: "制定工作计划", role: primaryRole, provider: assignments[primaryRole]!)
            planner.readScope = ["."]
            return try dispatch(t, item: planner, config: config, ready: ready, routes: assignments, work: work)
        }
        guard let plan = t.plan else { return false }
        // Integrate delivered siblings serially, and dispatch dependents only after integration settles.
        if let delivered = plan.items.first(where: { $0.state == .delivered }) {
            try integrate(t, item: delivered, work: work)
            return true
        }
        let integrated = Set(plan.items.filter { $0.state == .integrated }.map(\.id))
        if integrated.count == plan.items.count {
            guard active.isEmpty else { return false }
            if try addFollowUpIfNeeded(t, routes: assignments) { return true }
            launch(taskID: t.id, key: "verify/" + t.id) { try await self.verify(t, work: work, baseline: false) }
            return false
        }
        if !t.verifications.contains(where: { $0.name.hasPrefix("Baseline · ") }) && t.attempts.allSatisfy({ $0.itemID == "@plan" }) {
            let checks = try Self.commands(t, root: work.path)
            if !checks.isEmpty {
                guard active.isEmpty else { return false }
                let scratch = try service().createAttempt(task: work, id: UUID())
                launch(taskID: t.id, key: "baseline/" + t.id) { try await self.verify(t, work: scratch, baseline: true) }
                return false
            }
        }
        guard jobs["baseline/" + t.id] == nil else { return false }
        let enabled = plan.items.filter { $0.state == .pending && Set($0.dependencies).isSubset(of: integrated) }
        for item in enabled {
            if try dispatch(t, item: item, config: config, ready: ready, routes: assignments, work: work) { return true }
        }
        return false
    }

    func dispatch(_ t: HubTask, item: WorkItem, config: HubConfiguration, ready: [ProviderID:EngineConnection],
                  routes: [String:ProviderID], work: GitWorkspace) throws -> Bool {
        let global = HubConfiguration.balanced.overriding(with: try store.globalConfiguration())
        let active = jobs.values.filter { $0.provider != nil }
        guard active.count < max(1, global.maxConcurrent ?? 2),
              active.filter({ $0.taskID == t.id }).count < max(1, config.maxConcurrent ?? 2) else { return false }
        let history = t.attempts.filter { $0.itemID == item.id && $0.requirementRevision == t.requirementRevision && $0.planRevision == t.planRevision }
        guard !history.contains(where: { $0.state.isActive }) else { return false }
        let previous = history.last
        if let until = previous?.retryAfter, until > Date() {
            let key = "delay/" + (previous?.id ?? t.id)
            if jobs[key] == nil {
                launch(taskID: t.id, key: key) {
                    try await Task.sleep(nanoseconds: UInt64(max(0,until.timeIntervalSinceNow) * 1_000_000_000))
                }
            }
            return false
        }
        var provider = previous?.provider ?? item.provider
        if let previous, previous.failureKind == "switch" {
            let tried = Set(history.map(\.provider))
            guard let replacement = (config.allowedFallbacks ?? []).first(where: {
                guard !tried.contains($0), let info = ready[$0] else { return false }
                return !info.paid || ((config.paidProviders ?? []).contains($0) && config.maxCostUSD != nil)
            }) else { throw EngineError("没有已授权的备用连接。请重新分配角色，或修复当前连接。") }
            provider = replacement
        }
        guard let endpoint = ready[provider] else { throw EngineError("“\(item.title)”所需的 \(provider.displayName) 连接不可用。请重新连接或重新分配角色。") }
        let accountCount = active.filter { $0.provider == provider }.count
        let localCap = config.providerConcurrency[provider.rawValue] ?? 1
        let globalCap = global.providerConcurrency[provider.rawValue] ?? 1
        guard accountCount < min(max(1,localCap),max(1,globalCap)) else { return false }
        guard t.attempts.count < min(config.maxAttempts ?? 12, global.maxAttempts ?? 12) else {
            try attention(t.id, code: "attempt_budget", detail: "任务已达尝试次数上限。请查看已保存的更改和历次尝试记录。")
            return false
        }
        if endpoint.paid, let threshold = config.maxCostUSD {
            let unsettled = t.attempts.filter { $0.provider == .dsh && $0.billingUSD == nil }.count
            let known = t.attempts.compactMap(\.billingUSD).reduce(0,+)
            guard known < threshold, (unsettled == 0 || (config.reservedCostUSD ?? 0) > 0),
                  known + Double(unsettled + 1) * (config.reservedCostUSD ?? 0) <= threshold else {
                try attention(t.id, code: "cost_threshold", detail: "已达支出上限，或此前一次付费尝试的费用尚未确定。请核对账单后再继续。")
                return false
            }
        }
        var attempt = HubAttempt(itemID: item.id, provider: provider, role: item.role, requirementRevision: t.requirementRevision,
                                 planRevision: t.planRevision, generation: t.generation)
        attempt.model = config.models[item.role] ?? config.models[provider.rawValue]
        attempt.configuration = config
        attempt.previousID = previous?.id
        let git = try service()
        // Checkpoint inheritance requires an exact old worktree and HEAD, and is never reused across revisions.
        var parent: GitWorkspace?
        if let previous, previous.state != .succeeded, previous.workspace?.snapshot != nil, item.id != "@plan" {
            parent = try attemptWorkspace(previous, task: t)
        }
        let attemptWork = try git.createAttempt(task: work, id: UUID(uuidString: attempt.id)!, continuing: parent,
                                                expectedHead: parent == nil ? nil : previous?.workspace?.snapshot)
        attempt.workspace = try reference(attemptWork)
        let source = previous ?? t.attempts.last(where: { item.dependencies.contains($0.itemID) && $0.integratedCommit != nil })
        var handoff = Self.handoff(t, from: source, next: item.title)
        handoff.workspace = attempt.workspace
        let planned = item.id == "@plan"
        let repairing = item.id.hasPrefix("repair-")
        let messages = try pendingMessages(t, item: item, solo: Set(routes.values).count == 1)
        let prompt: String
        if planned {
            prompt = PlanRules.plannerPrompt(task: t, routes: routes, correction: previous?.failure) + Self.instructions(messages)
        } else {
            prompt = Self.brief(t, item: item, work: attemptWork, handoff: handoff) + Self.instructions(messages)
        }
        let snapshot = attempt
        try store.updateTask(t.id, kind: previous?.provider != nil && previous?.provider != provider ? "provider.switched" : "attempt.prepared", detail: "\(HubPresentation.roleTitle(item.role)) → \(provider.displayName) · \(item.title)") { task in
            guard task.state == .running, task.generation == t.generation, task.planRevision == t.planRevision,
                  task.requirementRevision == t.requirementRevision else { throw CancellationError() }
            if let previous, previous.provider != provider { task.switchCount += 1 }
            if source != nil || !task.decisions.isEmpty { task.handoffs.append(handoff) }
            task.phase = planned ? .planning : (repairing ? .repairing : .implementing)
            if let ix = task.plan?.items.firstIndex(where: { $0.id == item.id }) {
                task.plan?.items[ix].state = .running
                task.plan?.items[ix].workspace = snapshot.workspace
            }
            task.attempts.append(snapshot)
        }
        launch(taskID: t.id, key: attempt.id, provider: provider) {
            try await self.runAttempt(t, item: item, attempt: snapshot, work: attemptWork, connection: endpoint,
                                      routes: routes, prompt: prompt, messages: messages)
        }
        return true
    }

    func pendingMessages(_ t: HubTask, item: WorkItem, solo: Bool) throws -> [HubMessage] {
        var result: [HubMessage] = []
        var after: Int64 = 0
        repeat {
            let page = try store.messages(taskID: t.id, after: after, limit: 500)
            for message in page where message.sender == "user" && message.delivery != .processed && message.requirementRevision == t.requirementRevision {
                guard message.itemID == nil || message.itemID == item.id || item.id == "followup-\(message.sequence)" else { continue }
                guard message.recipient == item.role || ((solo || item.id == "@plan" || item.id == "followup-\(message.sequence)") && message.recipient == "task") else { continue }
                result.append(message)
            }
            guard let last = page.last, page.count == 500, result.count < 64 else { break }
            after = last.sequence
        } while true
        return Array(result.prefix(64))
    }

    static func instructions(_ messages: [HubMessage]) -> String {
        guard !messages.isEmpty else { return "" }
        return "\nUser follow-ups queued for this role:\n" + messages.map { String($0.text.prefix(3000)) }.joined(separator: "\n")
    }

    static func brief(_ task: HubTask, item: WorkItem, work: GitWorkspace, handoff: HubHandoff) -> String {
        """
        Agent Hub work order. Work only in the current managed repository. Do not switch branches, push, publish, install credentials, or modify other worktrees. Preserve repository instructions that fit this scope.
        User goal: \(task.goal)
        Requirement revision \(task.requirementRevision), plan \(task.planRevision). Role: \(item.role).
        Assignment: \(item.title)
        Baseline: \(work.baseline); managed workspace: \(work.path.path).
        Inputs: \(item.inputs.joined(separator: "\n"))
        Read scope: \(item.readScope.joined(separator: ", ")). Write scope: \(item.writeScope.isEmpty ? "read only" : item.writeScope.joined(separator: ", ")).
        Upstream decisions and interfaces: \((handoff.decisions + handoff.interfaces).joined(separator: "\n"))
        Completed: \(handoff.completed.joined(separator: ", ")). Outstanding: \(handoff.remaining.joined(separator: ", ")).
        Deliverables: \(item.deliverables.joined(separator: "\n"))
        Acceptance: \((task.plan?.acceptance ?? task.acceptance).joined(separator: "\n"))
        Checks: \(task.plan?.checks.joined(separator: "\n") ?? "")
        Next action: \(handoff.nextAction)
        Prior changed paths: \(task.attempts.first(where: { $0.id == handoff.fromAttemptID })?.changedPaths.joined(separator: ", ") ?? "none")
        Known issues: \(handoff.issues.joined(separator: ", "))
        Saved artifact references: \(task.artifacts.filter { handoff.artifactIDs.contains($0.id) }.suffix(5).map { "\($0.title) · \($0.path)" }.joined(separator: "\n"))
        Verification evidence: \(task.verifications.filter { handoff.verificationIDs.contains($0.id) }.suffix(6).map { "\($0.id) · \($0.name) · \($0.state.rawValue) · \(String(($0.evidence ?? "").suffix(900)))" }.joined(separator: "\n"))
        Last failure: \(handoff.lastFailure ?? "none")
        Work within the configured time and provider limits. Report blocking information immediately. At the end summarize actual changed files, checks, and remaining issues. Agent Hub independently checks the resulting diff and runs the configured verification.
        """
    }
}
