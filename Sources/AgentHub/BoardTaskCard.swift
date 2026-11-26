import HubKit
import HubProviders
import SwiftUI

struct BoardTaskCard: View {
    @EnvironmentObject private var hub: HubController
    let task: HubTask
    let open: () -> Void
    @State private var busy = false
    @State private var confirmCancel = false

    static func providers(in task: HubTask) -> [ProviderID] {
        let used = task.attempts.map(\.provider) + (task.plan?.items.map(\.provider) ?? [])
        let known = used.isEmpty ? Array(task.overrides.roles.values) : used
        return ProviderID.allCases.filter { known.contains($0) }
    }

    private var roleSummary: String {
        var roles = task.plan?.items.map(\.role) ?? []
        if roles.isEmpty { roles = task.attempts.map(\.role) }
        if roles.isEmpty { roles = Array(task.overrides.roles.keys.sorted()) }
        var seen = Set<String>()
        return roles.filter { seen.insert($0).inserted }.map(boardRoleName).joined(separator: "、")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 3) {
                Button(action: open) { HubStateBadge(state: task.state) }.buttonStyle(.plain)
                    .help("打开工作区")
                if task.state == .queued && task.priority != 0 {
                    Image(systemName: task.priority > 0 ? "arrow.up" : "arrow.down").font(.caption2)
                        .foregroundStyle(HubDesign.muted).help("队列优先级 " + String(task.priority))
                        .accessibilityLabel("队列优先级 " + String(task.priority))
                }
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
                Menu { actions } label: {
                    Image(systemName: "ellipsis").frame(width: 18, height: 18)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("任务操作").help("任务操作")
            }
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(task.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(HubDesign.ink)
                        .multilineTextAlignment(.leading).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    if task.state != .queued {
                        Text("阶段 · " + HubDesign.phaseTitle(task.phase)).font(.caption).foregroundStyle(HubDesign.muted)
                    }
                    if let reason = task.attentionReason, !reason.isEmpty, task.state != .completed {
                        Label(HubPresentation.attentionTitle(reason), systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(HubDesign.amber).lineLimit(3)
                    } else if !task.summary.isEmpty {
                        Text(task.summary).font(.caption).foregroundStyle(HubDesign.muted).lineLimit(2)
                    }
                    if !roleSummary.isEmpty {
                        Label(roleSummary, systemImage: "person.2").font(.caption).foregroundStyle(HubDesign.muted).lineLimit(2)
                    }
                    let providers = Self.providers(in: task)
                    if !providers.isEmpty {
                        Text(providers.map(\.displayName).joined(separator: " · "))
                            .lineLimit(2).font(.caption.weight(.medium)).foregroundStyle(HubDesign.accent)
                    }
                    Divider()
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                        Text(task.updatedAt, style: .relative)
                            .help(task.updatedAt.formatted(date: .complete, time: .standard))
                        if task.isArchived { Spacer(); Image(systemName: "archivebox").accessibilityLabel("已归档") }
                    }.font(.caption2).foregroundStyle(HubDesign.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(task.goal).accessibilityLabel("打开任务，" + task.title)
        }
        .padding(10).modifier(BoardCardSurface())
        .contextMenu { actions }
        .alert("取消这项任务？", isPresented: $confirmCancel) {
            Button("返回", role: .cancel) {}
            Button("取消任务", role: .destructive) { perform(.cancel) }
        } message: { Text("当前执行将停止。取消后的任务和已保存的成果可在历史归档查看。") }
    }

    @ViewBuilder private var actions: some View {
        Button("打开工作区", action: open)
        if !busy {
            Divider()
            if task.isArchived {
                Button("取消归档") { perform(.unarchive) }
            } else {
                switch task.state {
                case .queued:
                    Button("开始任务") { perform(.start) }
                    Button("提高队列优先级") { changePriority(by: 1) }.disabled(task.priority >= Int.max - 1)
                    Button("降低队列优先级") { changePriority(by: -1) }.disabled(task.priority <= Int.min + 1)
                    Button("取消任务…", role: .destructive) { confirmCancel = true }
                case .running:
                    Button("暂停") { perform(.pause) }
                    Button("取消任务…", role: .destructive) { confirmCancel = true }
                case .pausing:
                    Button("正在暂停") {}.disabled(true)
                case .paused:
                    Button("继续") { perform(.resume) }
                    Button("取消任务…", role: .destructive) { confirmCancel = true }
                case .needsUser:
                    Button("打开并处理", action: open)
                    Button("重试") { perform(.retry) }
                    Button("取消任务…", role: .destructive) { confirmCancel = true }
                case .cancelled, .completed:
                    EmptyView()
                }
                if [.queued, .paused, .needsUser, .cancelled, .completed].contains(task.state) {
                    Button("归档") { perform(.archive) }
                }
            }
        }
    }

    private func perform(_ action: TaskAction) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await hub.perform(action, taskID: task.id) }
            catch { hub.errorMessage = error.localizedDescription }
        }
    }

    private func changePriority(by amount: Int) {
        do { try hub.setPriority(taskID: task.id, priority: task.priority + amount) }
        catch { hub.errorMessage = error.localizedDescription }
    }
}

func boardRoleName(_ role: String) -> String {
    switch role {
    case "lead": return "负责人"
    case "frontend": return "前端"
    case "backend": return "后端"
    case "test": return "测试"
    case "review": return "审查"
    default: return role
    }
}
