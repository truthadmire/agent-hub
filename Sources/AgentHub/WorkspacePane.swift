import SwiftUI
import HubKit
import HubProviders

struct WorkspacePane: View {
    let task: HubTask
    let role: String
    let roles: [String]
    let select: (String) -> Void
    @AppStorage private var toTask: Bool

    init(task: HubTask, role: String, roles: [String], select: @escaping (String) -> Void) {
        self.task = task
        self.role = role
        self.roles = roles
        self.select = select
        _toTask = AppStorage(wrappedValue: role == "lead", "workspace.\(task.id).\(role).taskComposer")
    }

    var body: some View {
        let attempt = WorkspaceRole.attempt(role, task: task)
        let provider = WorkspaceRole.provider(role, task: task)
        let activeItem = WorkspaceRole.currentItem(role, task: task)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: WorkspaceRole.icon(role))
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(HubDesign.accent)
                    .frame(width: 32, height: 32)
                    .background(HubDesign.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Menu {
                        ForEach(roles, id: \.self) { candidate in
                            Button { select(candidate) } label: {
                                Label(WorkspaceRole.title(candidate), systemImage: candidate == role ? "checkmark" : WorkspaceRole.icon(candidate))
                            }
                        }
                    } label: {
                        Text(WorkspaceRole.title(role)).font(.headline)
                    }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("切换角色，当前为\(WorkspaceRole.title(role))")
                    .accessibilityIdentifier("workspace.role.\(role)")
                    Text([provider?.displayName ?? "等待分配连接",
                          attempt?.requirementRevision == task.requirementRevision && attempt?.provider == provider ? attempt?.model : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 3)
                if let attempt {
                    Text(attempt.requirementRevision == task.requirementRevision ? WorkspaceRole.attemptState(attempt.state) : "历史尝试")
                        .font(.caption2.weight(.medium)).foregroundStyle(attempt.state.isActive ? HubDesign.accent : HubDesign.muted)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
            if let activeItem {
                Label(activeItem.title, systemImage: "list.bullet.rectangle").lineLimit(2)
                    .help(activeItem.title).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            WorkspaceFeed(task: task, role: role)
            Divider()
            HStack {
                Menu {
                    Button("任务级 · 发给负责人") { toTask = true }
                    Button("角色级 · 发给\(WorkspaceRole.title(role))") { toTask = false }
                } label: {
                    Label(toTask ? "任务级 · 发给负责人" : "发给\(WorkspaceRole.title(role))" + (provider.map { " · " + $0.displayName } ?? ""),
                          systemImage: toTask ? "flag" : "person.crop.circle")
                }.menuStyle(.borderlessButton).fixedSize().font(.caption.weight(.medium))
                    .accessibilityLabel("选择消息接收对象")
                Spacer(minLength: 0)
            }.padding(.horizontal, 12).padding(.top, 9)
            WorkspaceComposer(task: task, role: role, recipient: toTask ? "task" : role)
                .id(task.id + "/" + (toTask ? "task" : role))
        }.modifier(BoardCardSurface())
    }
}

private struct WorkspaceComposer: View {
    let task: HubTask
    let role: String
    let recipient: String
    @EnvironmentObject private var hub: HubController
    @State private var text = ""
    @State private var ready = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: Binding(get: { text }, set: { value in
                text = value
                guard ready else { return }
                do { try hub.store?.saveDraft(taskID: task.id, recipient: recipient, text: value) }
                catch { hub.showError(error) }
            }))
            .font(.body).scrollContentBackground(.hidden).focused($focused)
            .frame(minHeight: 38, idealHeight: 52, maxHeight: 64)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(recipient == "task" ? "补充任务优先级或验收条件…" : "补充这个角色需要的细节…")
                        .font(.body).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .accessibilityLabel("发给\(WorkspaceRole.title(recipient))的草稿").accessibilityIdentifier("workspace.draft.\(recipient)")
            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.plain).foregroundStyle(HubDesign.accent)
                .disabled(!canSend).accessibilityLabel("发送给\(WorkspaceRole.title(recipient))")
                .accessibilityIdentifier("workspace.send.\(recipient)").help(sendHelp)
        }
        .onKeyPress(.return, phases: .down) { press in
            guard focused && press.modifiers == .command else { return .ignored }
            if canSend { send() }
            return .handled
        }
        .onAppear { loadDraft() }
        .onReceive(NotificationCenter.default.publisher(for: .workspaceDraftDidChange)) { note in
            guard note.userInfo?["task"] as? String == task.id,
                  note.userInfo?["recipient"] as? String == recipient else { return }
            loadDraft()
        }
        .onChange(of: text) { _, _ in
            guard ready else { return }
            NotificationCenter.default.post(name: .workspaceDraftDidChange, object: nil,
                                            userInfo: ["task": task.id, "recipient": recipient])
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var sendHelp: String {
        if task.isArchived { return "从历史中恢复任务后可以继续协作。" }
        if task.state == .cancelled { return "任务已取消。" }
        if task.state == .completed { return "需要继续工作时，可在任务操作中修订需求。" }
        return "发送给\(WorkspaceRole.title(recipient))（⌘↩）"
    }

    private var canSend: Bool {
        ready && !task.isArchived && task.state != .cancelled && task.state != .completed &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadDraft() {
        do {
            guard let store = hub.store else { throw WorkspaceIssue.unavailable("任务数据库未连接。") }
            text = try store.draft(taskID: task.id, recipient: recipient)
            ready = true
        } catch { ready = false; hub.showError(error) }
    }

    private func send() {
        guard canSend, let store = hub.store else { return }
        var message = HubMessage(taskID: task.id, sender: "user", recipient: recipient,
                                 text: text, requirementRevision: task.requirementRevision)
        if recipient != "task" {
            if let item = WorkspaceRole.currentItem(role, task: task) {
                message.itemID = item.id
                message.sessionID = task.attempts.last(where: {
                    $0.itemID == item.id && $0.requirementRevision == task.requirementRevision && $0.state.isActive
                })?.providerSessionID
            }
        }
        do {
            try store.saveMessage(message, clearDraft: true)
            text = ""
            hub.refresh()
        } catch { hub.showError(error) }
    }
}

private extension Notification.Name {
    static let workspaceDraftDidChange = Notification.Name("AgentHub.WorkspaceDraftDidChange")
}
