import Foundation
import HubGit
import HubProcess

extension HubEngine {
    static func commands(_ t: HubTask, root: URL) throws -> [ProjectCheckCommand] {
        let cfg = t.runtimeConfig ?? .balanced
        let cwd = cfg.commandWorkingDirectory ?? "."
        guard PlanRules.validPath(cwd), let directory = ProjectTools.directory(in: root, relative: cwd) else {
            throw EngineError("验证工作目录不存在或位于任务工作区之外：\(cwd)")
        }
        let timeout = max(1, min(300, Double(cfg.maxSeconds ?? 3600) - elapsed(t)))
        if let commands = cfg.verificationCommands, !commands.isEmpty {
            return try commands.enumerated().map { index, argv in
                guard let name = argv.first, !name.isEmpty else { throw EngineError("验证命令不能为空。") }
                return ProjectCheckCommand(name: "Check \(index + 1) · \(name)", argv: argv, workingDirectory: cwd,
                                           timeout: timeout, environment: cfg.commandEnvironment ?? [:])
            }
        }
        var result = ProjectTools.detect(in: directory).checks.map { check in
            let subdir = [cwd,check.workingDirectory].filter { $0 != "." }.joined(separator: "/")
            return ProjectCheckCommand(name: check.name, argv: check.argv, required: check.required,
                                       workingDirectory: subdir.isEmpty ? "." : subdir,
                                       timeout: timeout, environment: cfg.commandEnvironment ?? [:])
        }
        // Removing a manifest or test suite must not silently erase the original checks.
        for baseline in t.verifications where baseline.name.hasPrefix("Baseline · ") {
            let name = String(baseline.name.dropFirst("Baseline · ".count))
            if !result.contains(where: { $0.name == name }), !baseline.command.isEmpty {
                result.append(ProjectCheckCommand(name: name, argv: baseline.command, workingDirectory: cwd, timeout: timeout, environment: cfg.commandEnvironment ?? [:]))
            }
        }
        return result
    }

    static func currentChecks(_ t: HubTask, snapshot: String) -> [String:HubVerification] {
        var latest: [String:HubVerification] = [:]
        for check in t.verifications where check.requirementRevision == t.requirementRevision &&
            check.snapshot == snapshot && (check.snapshotAfter == nil || check.snapshotAfter == snapshot) &&
            !check.name.hasPrefix("Baseline · ") {
            latest[check.name] = check
        }
        return latest
    }

    static func satisfied(_ check: HubVerification) -> Bool {
        check.state == .passed || check.state == .waived || check.state == .notApplicable
    }

    public func reverify(_ taskID: String) async throws {
        let t = try store.task(taskID)
        guard [.completed,.needsUser,.paused].contains(t.state), !held.contains(taskID),
              !jobs.values.contains(where: { $0.taskID == taskID }),
              t.plan?.items.isEmpty == false, t.plan?.items.allSatisfy({ $0.state == .integrated }) == true else {
            throw EngineError("请在任务完成整合并停止运行后重新验证。")
        }
        held.insert(taskID)
        defer { held.remove(taskID); kick() }
        await PreviewManager.shared.stop(taskID: taskID)
        guard !stopping, try store.task(taskID).state == t.state else { throw CancellationError() }
        let work = try workspace(t), git = try service()
        guard try git.head(of: work) == t.workspace?.snapshot else {
            throw EngineError("整合工作树的 HEAD 已被其他操作更改。请先检查任务分支，再进行验证。")
        }
        let head = try checkpointVerificationChange(t, work: work)
        let fresh = try store.task(taskID)
        let checks = Self.currentChecks(fresh, snapshot: head).values.filter { !$0.command.isEmpty && $0.state != .waived }
        try store.updateTask(taskID, kind: "verification.requested", detail: head) { task in
            task.attentionReason = nil
            task.phase = .verifying
            Self.transition(&task, to: .running)
            for check in checks {
                var invalidated = check
                invalidated.id = UUID().uuidString
                invalidated.state = .notRun
                invalidated.reason = "用户已要求重新验证。"
                invalidated.evidence = nil
                invalidated.endedAt = nil
                task.verifications.append(invalidated)
            }
        }
        kick()
    }

    public func recordHumanCheck(_ taskID: String, verificationID: String, waive: Bool = false, reason: String) async throws {
        let t = try store.task(taskID)
        guard t.state == .needsUser || t.state == .paused, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let original = t.verifications.first(where: { $0.id == verificationID }),
              original.requirementRevision == t.requirementRevision, let snapshot = t.workspace?.snapshot,
              original.snapshot == snapshot, Self.currentChecks(t, snapshot: snapshot)[original.name]?.id == original.id,
              !Self.satisfied(original), (waive || original.actor == "manual") else {
            throw EngineError("请选择当前版本的人工验收项并填写观察结果；如需豁免，请选择必需检查并填写原因。")
        }
        let git = try service(), work = try workspace(t)
        guard try git.head(of: work) == snapshot, try git.status(of: work).isEmpty else { throw EngineError("工作树已变化。请重新验证，再确认此项。") }
        var decision = original
        decision.id = UUID().uuidString
        decision.actor = NSUserName()
        decision.startedAt = Date()
        decision.endedAt = decision.startedAt
        decision.state = waive ? .waived : .passed
        decision.reason = reason
        decision.evidence = reason
        try store.updateTask(taskID, kind: waive ? "verification.waived" : "verification.confirmed", detail: "\(HubPresentation.verificationTitle(original.name)) · \(reason)") { task in
            guard task.requirementRevision == t.requirementRevision && task.workspace?.snapshot == snapshot else { throw EngineError("任务版本已变化，此次验证已过期。") }
            task.verifications.append(decision)
        }
        if t.state == .needsUser { try await resume(taskID) }
    }

    func verify(_ t: HubTask, work: GitWorkspace, baseline: Bool) async throws {
        guard try same(t) else { return }
        try Task.checkCancellation()
        let git = try service()
        let expected = try git.head(of: work)
        if !baseline {
            guard expected == t.workspace?.snapshot else { throw EngineError("整合工作树的 HEAD 已被其他操作更改。请先检查任务分支，再进行验证。") }
            try store.updateTask(t.id, kind: "verification.started", detail: expected) { $0.phase = .verifying }
            if !(try git.status(of: work)).isEmpty {
                throw EngineError("任务工作树有新的更改。请选择“重新验证”，为这些更改保存检查点并运行检查。")
            }
        }
        let checks = try Self.commands(t, root: work.path)
        var names = Set<String>()
        for check in checks {
            try Task.checkCancellation()
            guard try same(t) else { return }
            let current = try store.task(t.id)
            if !baseline, Self.elapsed(current) >= Double(current.runtimeConfig?.maxSeconds ?? 3600) {
                try attention(t.id, code: "time_budget", detail: "验证期间任务达到时限。验证记录已保存。")
                return
            }
            let name = (baseline ? "Baseline · " : "") + check.name
            names.insert(name)
            if !baseline, let valid = Self.currentChecks(current, snapshot: expected)[name], Self.satisfied(valid) { continue }
            let before = try git.snapshotID(of: work)
            let startCommit = try git.head(of: work)
            var record = HubVerification(name: name, required: !baseline && check.required, state: .notRun, requirementRevision: t.requirementRevision, snapshot: startCommit)
            record.command = check.argv
            record.directory = work.path.path
            let recordID = record.id
            try store.updateTask(t.id, kind: "verification.prepared", detail: HubPresentation.verificationTitle(name)) { $0.verifications.append(record) }
            let store = self.store
            let remaining = max(1, Double(current.runtimeConfig?.maxSeconds ?? 3600) - Self.elapsed(current))
            let bounded = ProjectCheckCommand(name: check.name, argv: check.argv, required: check.required,
                                              workingDirectory: check.workingDirectory, timeout: min(remaining, check.timeout),
                                              environment: check.environment)
            let output = try await ProjectTools.run(bounded, in: work.path, onStart: { identity in
                guard let active = try? store.task(t.id), active.state == .running && active.generation == t.generation else { throw CancellationError() }
                try store.appendEvent(taskID: t.id, kind: "verification.process", detail: "\(recordID) · PID \(identity.pid) · \(identity.workingDirectory)")
            })
            let after = try git.snapshotID(of: work)
            let end = try git.head(of: work)
            let evidence = HubRedaction.text(String((output.stdout + "\n" + output.stderr).suffix(12000)))
            try store.updateTask(t.id, kind: "verification.result", detail: "\(HubPresentation.verificationTitle(name)) · \(HubPresentation.verificationStateTitle(output.status))") { task in
                guard let ix = task.verifications.firstIndex(where: { $0.id == recordID }) else { throw EngineError("找不到此项验证记录。") }
                task.verifications[ix].state = output.status
                task.verifications[ix].snapshotAfter = before == after ? end : after
                task.verifications[ix].evidence = evidence
                task.verifications[ix].environment = "\(output.toolVersion) · 源代码树 \(before) → \(after)"
                task.verifications[ix].directory = output.directory
                task.verifications[ix].startedAt = output.startedAt
                task.verifications[ix].endedAt = output.finishedAt
                task.verifications[ix].exitCode = output.exitCode.flatMap(Int32.init(exactly:))
                task.verifications[ix].reason = output.reason
            }
            guard try same(t) else { return }
            if !baseline, before != after || startCommit != end {
                _ = try checkpointVerificationChange(t, work: work)
                if current.verifications.filter({ $0.requirementRevision == t.requirementRevision && $0.name == name &&
                        $0.snapshotAfter != nil && $0.snapshotAfter != $0.snapshot }).count >= 2 {
                    try attention(t.id, code: "verification_unstable", detail: "“\(HubPresentation.verificationTitle(name))”在验证时多次改动源文件。请检查任务工作树后重试。")
                }
                return
            }
        }
        if baseline { return }
        let fresh = try store.task(t.id)
        guard try same(t), (try git.head(of: work)) == expected, (try git.status(of: work)).isEmpty else {
            throw EngineError("验证期间工作树发生了变化，请重新运行检查。")
        }
        var human = Set(fresh.plan?.acceptance ?? fresh.acceptance)
        human.subtract(names)
        let old = Self.currentChecks(fresh, snapshot: expected)
        // Keep the names of already-recorded manual checks so existing decisions still apply.
        if checks.isEmpty && human.isEmpty {
            let previous = "Review the delivered result against the task goal"
            human.insert(old["Human · " + previous] == nil ? "对照任务目标检查交付结果" : previous)
        }
        if (try git.changedPaths(of: work, expectedHead: expected)).isEmpty {
            let previous = "Confirm that the goal is satisfied without a source change"
            human.insert(old["Human · " + previous] == nil ? "确认无需修改源文件即可满足任务目标" : previous)
        }
        for text in human.sorted() where !text.isEmpty {
            let name = "Human · " + text
            names.insert(name)
            if old[name] == nil {
                var check = HubVerification(name: name, state: .notRun, requirementRevision: t.requirementRevision, snapshot: expected)
                check.actor = "manual"
                check.reason = text
                check.directory = work.path.path
                try store.updateTask(t.id, kind: "verification.manual_requested", detail: text) { $0.verifications.append(check) }
            }
        }
        let task = try store.task(t.id)
        if let ready = connections[t.id], try addFollowUpIfNeeded(task, routes: routes(task.runtimeConfig ?? .balanced, ready)) { return }
        let current = Self.currentChecks(task, snapshot: expected)
        let pending = names.sorted().compactMap { current[$0] }.filter { $0.required && !Self.satisfied($0) }
        if let failed = pending.first(where: { $0.state == .failed }) {
            try repair(task, failed: failed, work: work)
        } else if !pending.isEmpty {
            let blocked = pending.contains { $0.state == .blocked }
            let description = pending.map { check in
                let title = HubPresentation.verificationTitle(check.name)
                guard let reason = check.reason, check.name != "Human · " + reason else { return "• " + title }
                return "• " + title + " — " + reason
            }.joined(separator: "\n")
            try attention(t.id, code: blocked ? "verification_blocked" : "manual_acceptance",
                          detail: "更改已保存在 \(work.branch) 分支。以下验收项仍需处理：\n\(description)")
        } else {
            guard !names.isEmpty, names.allSatisfy({ current[$0] != nil }), task.plan?.items.allSatisfy({ $0.state == .integrated }) == true,
                  let patch = task.artifacts.last(where: { $0.kind == "patch" && $0.snapshot == expected }),
                  FileManager.default.fileExists(atPath: patch.path) else { throw EngineError("缺少完成任务所需的验证记录或补丁。") }
            let changed = try git.changedPaths(of: work, expectedHead: expected)
            let waived = current.values.filter { $0.state == .waived }.count
            let summary = "共更改 \(changed.count) 个文件，完成验收 \(names.count) 项（其中 \(waived) 项已豁免）。结果保存在 \(work.branch) 分支。"
            try store.updateTask(t.id, kind: "task.completed", detail: summary) { result in
                guard result.state == .running, result.generation == t.generation,
                      result.workspace?.snapshot == expected else { throw CancellationError() }
                guard try store.pendingUserMessages(taskID: t.id, requirementRevision: t.requirementRevision, limit: 1).isEmpty else { return }
                Self.transition(&result, to: .completed)
                result.summary = summary
                result.attentionReason = nil
            }
        }
    }

    func checkpointVerificationChange(_ t: HubTask, work: GitWorkspace) throws -> String {
        let git = try service()
        let head = try git.checkpoint(work, message: "Record changes to verified sources")
        let directory = root.appendingPathComponent("results/" + work.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let patch = directory.appendingPathComponent(head + ".patch")
        if !FileManager.default.fileExists(atPath: patch.path) { try git.exportPatch(of: work, to: patch, expectedHead: head) }
        var artifact = HubArtifact(kind: "patch", title: "验证后的源文件差异", path: patch.path)
        artifact.snapshot = head
        try store.updateTask(t.id, kind: "verification.source_changed", detail: head) { task in
            task.workspace?.snapshot = head
            if !task.artifacts.contains(where: { $0.snapshot == head && $0.kind == "patch" }) { task.artifacts.append(artifact) }
        }
        return head
    }

    func repair(_ t: HubTask, failed: HubVerification, work: GitWorkspace) throws {
        let cfg = t.runtimeConfig ?? .balanced
        let global = HubConfiguration.balanced.overriding(with: try store.globalConfiguration())
        let earlier = t.verifications.filter { $0.id != failed.id && $0.requirementRevision == t.requirementRevision && $0.name == failed.name && $0.state == .failed }
        let fingerprint = Self.fingerprint(failed)
        let repeated = earlier.contains { $0.snapshot == failed.snapshot || Self.fingerprint($0) == fingerprint }
        guard t.repairCount < min(cfg.maxRepairs ?? 2, global.maxRepairs ?? 2), !repeated else {
            try attention(t.id, code: repeated ? "no_progress" : "repair_budget", detail: "已尝试修复 \(t.repairCount) 轮，“\(HubPresentation.verificationTitle(failed.name))”仍未通过。更改与失败记录已保存，请检查工作树或修改计划。")
            return
        }
        guard let prior = t.plan?.items.last, let ready = connections[t.id] else { throw EngineError("没有可执行修复的角色或连接。") }
        let assignment = routes(cfg, ready)
        let role = assignment[prior.role] != nil ? prior.role : (assignment.keys.sorted().first ?? prior.role)
        guard let provider = assignment[role] else { throw EngineError("没有已授权的连接可以修复此项检查。") }
        var item = WorkItem(id: "repair-\(t.repairCount + 1)", title: "修复“\(HubPresentation.verificationTitle(failed.name))”", role: role, provider: provider)
        item.dependencies = t.plan?.items.map(\.id) ?? []
        item.inputs = ["失败的命令：" + failed.command.joined(separator: " "), failed.reason ?? "", String((failed.evidence ?? "").suffix(5000))]
        item.deliverables = ["修复记录中所示故障的原因，并保留原有验收测试和用户要求。"]
        item.readScope = ["."]
        item.writeScope = ["."]
        try store.updateTask(t.id, kind: "repair.scheduled", detail: "\(item.id) · \(failed.id) · \(fingerprint)") { task in
            task.repairCount += 1
            task.planRevision += 1
            task.plan?.revision = task.planRevision
            task.phase = .repairing
            task.plan?.items.append(item)
        }
    }

    static func fingerprint(_ failed: HubVerification) -> String {
        let message = (failed.evidence ?? "").split(separator: "\n").suffix(4).joined(separator: "\n")
        let normalized = message.replacingOccurrences(of: #"[0-9a-fA-F]{8}-[0-9a-fA-F-]{27,}"#, with: "<worktree>", options: .regularExpression)
            .replacingOccurrences(of: #"[0-9]+\.[0-9]+s"#, with: "<time>", options: .regularExpression)
        return "\(failed.name)|\(failed.exitCode ?? -1)|\(normalized)"
    }
}
