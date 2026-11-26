import SwiftUI
import HubKit
import HubGit

struct ResultHistory: View {
    let task: HubTask
    @EnvironmentObject private var hub: HubController
    @State private var revisions: [(revision: Int, goal: String, acceptance: [String])] = []
    @State private var historyError: String?
    @State private var cleanupCandidate: HubAttempt?
    @State private var cleaning = false
    @State private var cleanedFolders = Set<String>()

    var body: some View {
        WorkspaceSection(title: "执行与交接记录", icon: "clock.arrow.circlepath") {
            if task.attempts.isEmpty, task.handoffs.isEmpty { Text("尚无实际执行记录。").font(.caption).foregroundStyle(.secondary) }
            if !task.attempts.isEmpty {
                DisclosureGroup("执行尝试（\(task.attempts.count)）") {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(task.attempts.reversed()) { attempt in
                            DisclosureGroup("\(WorkspaceRole.title(attempt.role)) · \(attempt.provider.displayName) · \(WorkspaceRole.attemptState(attempt.state))") {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("需求 \(attempt.requirementRevision) · 计划 \(attempt.planRevision)")
                                    Text(attempt.startedAt.formatted(date: .numeric, time: .standard))
                                    if let value = attempt.model { Text("模型  " + value) }
                                    if let value = attempt.providerSessionID { Text("会话  " + value).textSelection(.enabled) }
                                    if let value = attempt.summary { Text(value).textSelection(.enabled) }
                                    if let value = attempt.failure { Text(value).foregroundStyle(HubDesign.amber).textSelection(.enabled) }
                                    if let workspace = attempt.workspace {
                                        Text(workspace.branch).textSelection(.enabled)
                                        Text(workspace.path).textSelection(.enabled)
                                        if !cleanedFolders.contains(attempt.id), FileManager.default.fileExists(atPath: workspace.path) {
                                            HStack {
                                                Button("在访达中显示此尝试") {
                                                    do { try ResultFileAction.reveal(URL(fileURLWithPath: workspace.path)) } catch { hub.showError(error) }
                                                }
                                                if task.isArchived, workspace.snapshot != nil, !attempt.state.isActive {
                                                    Button("清理尝试工作区…") { cleanupCandidate = attempt }.disabled(cleaning)
                                                }
                                            }.controlSize(.small)
                                        } else {
                                            Text("工作目录当前不可用").font(.caption).foregroundStyle(.secondary)
                                            Button("复制尝试分支") { ResultFileAction.copy(workspace.branch) }.buttonStyle(.link)
                                        }
                                    }
                                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(.top, 6)
                }
            }
            if !task.handoffs.isEmpty {
                DisclosureGroup("交接记录（\(task.handoffs.count)）") {
                    ForEach(task.handoffs.reversed()) { handoff in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("需求 \(handoff.requirementRevision) · 计划 \(handoff.planRevision)").font(.caption.weight(.semibold))
                            Text(handoff.nextAction).textSelection(.enabled)
                            let sections = [("已完成", handoff.completed), ("待办", handoff.remaining),
                                            ("决策", handoff.decisions), ("接口", handoff.interfaces), ("问题", handoff.issues)]
                            ForEach(sections, id: \.0) { name, values in
                                if !values.isEmpty { Text(name + "  " + values.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                            }
                            if let failure = handoff.lastFailure { Text(failure).font(.caption).textSelection(.enabled) }
                            if let work = handoff.workspace { Text(work.branch + " · " + work.baseCommit).font(.caption).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                    }
                }
            }
            if !task.decisions.isEmpty {
                DisclosureGroup("共享决策（\(task.decisions.count)）") {
                    Text(task.decisions.joined(separator: "\n")).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !revisions.isEmpty {
                DisclosureGroup("需求修订（\(revisions.count)）") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(revisions.reversed(), id: \.revision) { version in
                            Text("第 \(version.revision) 版").font(.caption.weight(.semibold))
                            Text(version.goal).textSelection(.enabled)
                            if !version.acceptance.isEmpty { Text(version.acceptance.joined(separator: "\n")).font(.caption).textSelection(.enabled) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                }
            }
            TaskDiagnosticButton(taskID: task.id)
            if let historyError { Text(historyError).font(.caption).foregroundStyle(HubDesign.amber) }
        }
        .alert("清理已整合的尝试工作区？", isPresented: Binding(
            get: { cleanupCandidate != nil }, set: { if !$0 { cleanupCandidate = nil } }
        ), presenting: cleanupCandidate) { attempt in
            Button("保留工作区", role: .cancel) {}
            Button("清理工作目录", role: .destructive) { cleanup(attempt) }
        } message: { attempt in
            Text("将移除这个尝试的受管工作目录。Git 会核对目录归属、完整整合状态以及本地文件，保留分支和提交。\n" + (attempt.workspace?.path ?? ""))
        }
        .task(id: task.requirementRevision) {
            do { revisions = try hub.store?.requirementHistory(taskID: task.id) ?? []; historyError = nil }
            catch { historyError = error.localizedDescription }
        }
    }
    private func cleanup(_ attempt: HubAttempt) {
        guard !cleaning, let service = hub.git, let store = hub.store,
              let work = attempt.workspace, let id = UUID(uuidString: work.id), let head = work.snapshot else { return }
        cleaning = true
        Task { @MainActor in
            defer { cleaning = false }
            do {
                try await Task.detached {
                    let current = try store.task(task.id)
                    guard current.isArchived, !current.attempts.contains(where: { $0.state.isActive }) else {
                        throw WorkspaceIssue.unavailable("请先归档已停止的任务，再清理尝试工作区。")
                    }
                    let managed = try service.workspace(id: id)
                    guard managed.kind == .attempt, managed.taskID.uuidString == current.id, managed.path.path == work.path else {
                        throw WorkspaceIssue.unavailable("尝试目录与受管记录不符。")
                    }
                    try service.removeWorkspace(managed, expectedHead: head)
                    try store.appendEvent(taskID: current.id, kind: "workspace.cleaned",
                                          detail: "已清理尝试目录；保留分支 " + work.branch, attemptID: attempt.id)
                }.value
                cleanedFolders.insert(attempt.id)
                hub.refresh()
            } catch { hub.showError(error) }
        }
    }

}
