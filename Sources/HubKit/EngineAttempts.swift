import Foundation
import HubGit
import HubProcess
import HubProviders

private struct AttemptProblem: LocalizedError {
    var kind: String
    var detail: String
    var errorDescription: String? { detail }
}

/// The process runner serializes callbacks and drains both streams before returning.
private final class AttemptJournal: @unchecked Sendable {
    let store: HubStore
    let taskID: String
    let attempt: HubAttempt
    var decoder: ProviderStreamDecoder
    var inputTokens: Int?
    var outputTokens: Int?
    var lastFailure: String?
    var journalError: Error?
    var lastTextAt = Date.distantPast
    var diagnostics = 0

    init(store: HubStore, taskID: String, attempt: HubAttempt, secrets: [String]) {
        self.store = store
        self.taskID = taskID
        self.attempt = attempt
        decoder = ProviderStreamDecoder(attempt.provider, sensitiveValues: secrets)
    }

    func consume(_ events: [ProviderEvent]) {
        for event in events {
            var detail = event.text
            switch event.kind {
            case .usage:
                inputTokens = event.inputTokens
                outputTokens = event.outputTokens
                detail = "Token 用量：输入 \(inputTokens.map(String.init) ?? "?")，输出 \(outputTokens.map(String.init) ?? "?")"
            case .failure: lastFailure = detail
            case .text:
                // Snapshots replace one another. Preserve the authoritative final answer separately.
                guard Date().timeIntervalSince(lastTextAt) >= 0.2 else { continue }
                lastTextAt = Date()
                detail = String(detail.suffix(5000))
            case .diagnostic:
                diagnostics += 1
                if diagnostics > 100, diagnostics % 50 != 0 { continue }
            default: break
            }
            var eventID = UUID().uuidString
            if event.kind == .text {
                let key = Data((event.itemID ?? "message").utf8.prefix(128)).base64EncodedString()
                eventID = "text/" + attempt.id + "/" + key + "/" + eventID
            }
            if event.kind == .permission { lastFailure = detail }
            do { try store.appendEvent(taskID: taskID, kind: "provider." + event.kind.rawValue, detail: detail, attemptID: attempt.id, eventID: eventID) }
            catch { journalError = error }
        }
    }

    func feed(_ stream: ProcessStream, _ bytes: Data) { consume(decoder.feed(bytes, stderr: stream == .stderr)) }
    func finish(_ code: Int32) { consume(decoder.finish(exitCode: code)) }
}

extension HubEngine {
    func runAttempt(_ t: HubTask, item: WorkItem, attempt: HubAttempt, work: GitWorkspace, connection: EngineConnection,
                    routes: [String:ProviderID], prompt: String, messages: [HubMessage]) async throws {
        let id = attempt.id
        var journal: AttemptJournal?
        var problem: AttemptProblem?
        var plan: PlanRevision?
        let store = self.store
        do {
            try Task.checkCancellation()
            guard try same(t) else { throw CancellationError() }
            let adapter: ProviderAdapter
            if fixtures != nil {
                adapter = ProviderAdapter(attempt.provider, stateDirectory: root.appendingPathComponent("fixture-provider-state"), deepSeekKey: { "fixture-only" })
            } else {
                adapter = ProviderAdapter(attempt.provider)
            }
            let cmd = try adapter.command(executable: connection.url, workspace: work.path, prompt: prompt, model: attempt.model, readOnly: item.writeScope.isEmpty)
            let sink = AttemptJournal(store: store, taskID: t.id, attempt: attempt, secrets: [cmd.environment["DEEPSEEK_API_KEY"]].compactMap { $0 })
            journal = sink
            let timeout = max(1, Double(t.runtimeConfig?.maxSeconds ?? 3600) - Self.elapsed(t))
            let request = ProcessRequest(executable: cmd.executable, arguments: cmd.arguments, workingDirectory: cmd.workingDirectory,
                                         environment: cmd.environment, stdin: cmd.stdin, timeout: timeout, inactivityWarningAfter: 90)
            let result = try await ProcessRunner.run(request, onStart: { identity in
                try store.updateTask(t.id, kind: "attempt.started", detail: "\(HubPresentation.roleTitle(attempt.role)) · PID \(identity.pid)") { task in
                    guard task.state == .running, task.generation == t.generation, task.requirementRevision == t.requirementRevision,
                          task.planRevision == t.planRevision, let ix = task.attempts.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                    task.attempts[ix].state = .running
                    task.attempts[ix].pid = identity.pid
                    task.attempts[ix].processGroup = identity.processGroup
                    task.attempts[ix].executable = identity.executablePath
                    task.attempts[ix].processStartedAt = Date(timeIntervalSince1970: Double(identity.startSeconds) + Double(identity.startMicroseconds) / 1_000_000)
                    task.attempts[ix].processIdentity = try JSONEncoder().encode(identity)
                }
                for m in messages { try store.setDelivery(messageID: m.id, to: .delivered) }
            }, onInactivity: { seconds in
                try? store.appendEvent(taskID: t.id, kind: "process.quiet", detail: "进程仍在运行，已连续 \(Int(seconds)) 秒没有输出。", attemptID: id)
            }, onOutput: { sink.feed($0, $1) })
            sink.finish(result.exitCode ?? -1)
            if let error = sink.journalError { throw error }
            if result.cancelled || Task.isCancelled { throw CancellationError() }
            if result.timedOut { throw AttemptProblem(kind: "time_budget", detail: "本次执行已用完任务的剩余时间。") }
            if result.outputDrainIncomplete { throw AttemptProblem(kind: "process_incomplete", detail: "子进程仍占用输出通道，本次输出可能不完整。请检查执行记录。") }
            guard sink.decoder.succeeded else {
                throw AttemptProblem(kind: sink.decoder.failure?.rawValue ?? "execution", detail: sink.lastFailure ?? "CLI 已退出，但未返回成功结束事件。")
            }
            if item.id == "@plan" {
                do { plan = try PlanRules.decode(sink.decoder.finalText, task: t, routes: routes) }
                catch { throw AttemptProblem(kind: "invalid_plan", detail: error.localizedDescription) }
            }
        } catch is CancellationError {
            problem = AttemptProblem(kind: "interrupted", detail: "执行已中断。可以在新会话中从保存的检查点继续。")
        } catch let failure as AttemptProblem { problem = failure }
        catch { problem = AttemptProblem(kind: "execution", detail: error.localizedDescription) }

        var paths: [String] = []
        var ref = attempt.workspace
        do {
            let git = try service()
            _ = try git.checkpoint(work, message: "Agent Hub · " + item.title)
            ref = try reference(work)
            paths = try git.changedPaths(of: work, expectedHead: ref?.snapshot)
            // A checkpoint brought forward from a prior attempt is held to the same work order.
            let previous = t.attempts.filter { $0.itemID == item.id && $0.requirementRevision == t.requirementRevision && $0.planRevision == t.planRevision }
            let allPaths = Set(paths + previous.flatMap(\.changedPaths))
            let outside = allPaths.filter { p in !item.writeScope.contains(where: { PlanRules.covers($0, p) }) }
            if !outside.isEmpty { throw AttemptProblem(kind: "write_scope", detail: "以下更改超出了分配的写入范围：" + outside.sorted().joined(separator: ", ")) }
        } catch {
            problem = AttemptProblem(kind: (error as? AttemptProblem)?.kind ?? "checkpoint", detail: error.localizedDescription)
        }

        let answer = String((journal?.decoder.finalText ?? "").prefix(64000))
        let failure = problem
        let fresh = try store.updateTask(t.id, kind: "attempt.finished", detail: failure?.detail ?? "已记录本轮执行结果和检查点。") { current in
            guard let ix = current.attempts.firstIndex(where: { $0.id == id }) else { throw EngineError("找不到本次尝试的记录。") }
            let valid = current.generation == t.generation && current.requirementRevision == t.requirementRevision && current.planRevision == t.planRevision
            let cancelled = current.state == .cancelled
            let interrupt = !valid || cancelled || current.state == .pausing || failure?.kind == "interrupted"
            // Simultaneous siblings can finish while another asks for input. Retain valid independent deliveries.
            current.attempts[ix].state = cancelled ? .cancelled : (interrupt ? .interrupted : (failure == nil ? .succeeded : .failed))
            current.attempts[ix].endedAt = Date()
            current.attempts[ix].workspace = ref
            current.attempts[ix].changedPaths = paths
            current.attempts[ix].summary = answer.isEmpty ? nil : answer
            current.attempts[ix].failureKind = interrupt ? "interrupted" : failure?.kind
            current.attempts[ix].failure = failure?.detail ?? (interrupt ? "本次执行已被后续操作取代，检查点已保留。" : nil)
            current.attempts[ix].providerSessionID = journal?.decoder.sessionID
            current.attempts[ix].inputTokens = journal?.inputTokens
            current.attempts[ix].outputTokens = journal?.outputTokens
            if journal?.inputTokens != nil || journal?.outputTokens != nil {
                current.attempts[ix].usageSource = "CLI 报告的 Token 用量"
                current.attempts[ix].usageObservedAt = Date()
            }
            guard valid, !cancelled else { return }
            if let wi = current.plan?.items.firstIndex(where: { $0.id == item.id }) {
                current.plan?.items[wi].state = (failure == nil && !interrupt) ? .delivered : .pending
                current.plan?.items[wi].workspace = ref
            }
            if let plan, !interrupt && failure == nil { current.plan = plan; current.phase = .implementing }
        }
        if !answer.isEmpty {
            var message = HubMessage(taskID: t.id, sender: item.role, recipient: "user", text: answer, requirementRevision: t.requirementRevision)
            message.itemID = item.id
            message.sessionID = journal?.decoder.sessionID
            message.delivery = .processed
            try store.saveMessage(message)
        }
        guard fresh.generation == t.generation && fresh.requirementRevision == t.requirementRevision &&
                fresh.planRevision == t.planRevision && fresh.state == .running && !Task.isCancelled else { return }
        if let problem {
            try handleFailure(fresh, item: item, attemptID: id, failureKind: problem.kind, detail: problem.detail)
        } else {
            for m in messages { try store.setDelivery(messageID: m.id, to: .processed) }
        }
    }

    func handleFailure(_ t: HubTask, item: WorkItem, attemptID: String, failureKind: String, detail: String) throws {
        let cfg = t.runtimeConfig ?? .balanced
        let global = HubConfiguration.balanced.overriding(with: try store.globalConfiguration())
        let retryable = ["network","quota","invalid_plan"].contains(failureKind)
        if retryable && t.retryCount < min(cfg.maxRetries ?? 2, global.maxRetries ?? 2) {
            let delay = failureKind == "invalid_plan" ? 0 : min(60, pow(2.0,Double(t.retryCount+1)))
            let when = Date().addingTimeInterval(delay)
            try store.updateTask(t.id, kind: "retry.scheduled", detail: "\(detail)\n将在 \(Int(delay)) 秒后重试。") { task in
                guard let ix = task.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
                task.attempts[ix].retryAfter = when
                task.retryCount += 1
            }
        } else if ["network","quota"].contains(failureKind), !(cfg.allowedFallbacks ?? []).isEmpty {
            try store.updateTask(t.id, kind: "handoff.requested", detail: detail) { task in
                guard let ix = task.attempts.firstIndex(where: { $0.id == attemptID }) else { return }
                task.attempts[ix].failureKind = "switch"
                task.handoffs.append(Self.handoff(task, from: task.attempts[ix], next: "使用已授权的备用连接继续“\(item.title)”。"))
            }
        } else {
            try attention(t.id, code: failureKind, detail: "\(item.title)：\(detail)\n本次尝试的工作树已保留。请查看执行记录，处理问题后继续。连接有误时可修复连接或重新分配角色。")
        }
    }

    func integrate(_ t: HubTask, item: WorkItem, work: GitWorkspace) throws {
        guard try same(t), let attempt = t.attempts.last(where: {
            $0.itemID == item.id && $0.state == .succeeded && $0.requirementRevision == t.requirementRevision &&
                $0.planRevision == t.planRevision && ($0.generation == t.generation || $0.revalidatedGeneration == t.generation)
        }), let expected = attempt.workspace?.snapshot, let taskHead = t.workspace?.snapshot else {
            throw EngineError("保存的交付结果与当前计划、执行轮次或工作区不符。")
        }
        let git = try service()
        let worker = try attemptWorkspace(attempt, task: t)
        guard worker.baseline == attempt.workspace?.baseCommit, work.id.uuidString == t.workspace?.id else { throw EngineError("工作区的基线或身份已变化。") }
        try store.updateTask(t.id, kind: "integration.started", detail: "\(item.id) · \(expected) → \(taskHead)") { $0.phase = .integrating }
        if try git.head(of: work) != taskHead,
           try git.hasIntegrated(attempt: worker, into: work, expectedAttemptHead: expected, previousTaskHead: taskHead) {
            try markIntegrated(t, item: item, attempt: attempt, work: work, head: git.head(of: work))
            return
        }
        let result = try git.integrate(attempt: worker, into: work, expectedAttemptHead: expected, expectedTaskHead: taskHead)
        switch result {
        case .conflict(let paths):
            try attention(t.id, code: "merge_conflict", detail: "请在任务工作树中解决合并冲突并暂存更改，然后继续。冲突文件：" + paths.joined(separator: ", "))
        case .integrated(let head): try markIntegrated(t, item: item, attempt: attempt, work: work, head: head)
        }
    }

    func markIntegrated(_ t: HubTask, item: WorkItem, attempt: HubAttempt, work: GitWorkspace, head: String) throws {
        let git = try service()
        let paths = try git.changedPaths(of: work, expectedHead: head)
        let patchDir = root.appendingPathComponent("results/" + work.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: patchDir, withIntermediateDirectories: true)
        let patch = patchDir.appendingPathComponent(head + ".patch")
        if !FileManager.default.fileExists(atPath: patch.path) { try git.exportPatch(of: work, to: patch, expectedHead: head) }
        var artifact = HubArtifact(kind: "patch", title: "整合差异 · \(paths.count) 个文件", path: patch.path)
        artifact.snapshot = head
        try store.updateTask(t.id, kind: "integration.finished", detail: paths.joined(separator: "\n")) { task in
            guard task.generation == t.generation && task.requirementRevision == t.requirementRevision && task.planRevision == t.planRevision,
                  task.state == .running, let i = task.plan?.items.firstIndex(where: { $0.id == item.id }),
                  let a = task.attempts.firstIndex(where: { $0.id == attempt.id }) else { throw CancellationError() }
            task.plan?.items[i].state = .integrated
            task.attempts[a].integratedCommit = head
            task.workspace?.snapshot = head
            if !task.artifacts.contains(where: { $0.kind == "patch" && $0.snapshot == head }) { task.artifacts.append(artifact) }
            task.handoffs.append(Self.handoff(task, from: task.attempts[a], next: "执行后续依赖项，或验证已整合的结果。"))
        }
    }
}
