import SwiftUI
import HubKit
import HubProviders

enum WorkspaceRole {
    static func title(_ role: String) -> String {
        HubPresentation.roleTitle(role)
    }

    static func icon(_ role: String) -> String {
        switch role {
        case "lead", "task": return "point.3.connected.trianglepath.dotted"
        case "frontend": return "rectangle.on.rectangle"
        case "backend": return "server.rack"
        case "test", "review": return "checkmark.shield"
        default: return "terminal"
        }
    }

    static func roles(in task: HubTask) -> [String] {
        let assigned = (task.plan?.items.map(\.role) ?? []) + task.attempts.map(\.role)
        var seen = Set<String>()
        return (["lead"] + assigned).filter { seen.insert($0).inserted }
    }

    static func attempt(_ role: String, task: HubTask) -> HubAttempt? {
        task.attempts.last(where: { $0.role == role && $0.requirementRevision == task.requirementRevision &&
            $0.planRevision == task.planRevision && $0.state.isActive })
        ?? task.attempts.last(where: { $0.role == role })
    }

    static func currentItem(_ role: String, task: HubTask) -> WorkItem? {
        guard let plan = task.plan, plan.requirementRevision == task.requirementRevision else { return nil }
        let items = plan.items.filter { $0.role == role }
        return items.first(where: { $0.state == .running }) ?? items.first(where: { $0.state == .pending })
    }

    static func provider(_ role: String, task: HubTask) -> ProviderID? {
        if let attempt = attempt(role, task: task), attempt.requirementRevision == task.requirementRevision,
           attempt.state.isActive { return attempt.provider }
        if let item = currentItem(role, task: task) { return item.provider }
        if let attempt = attempt(role, task: task), attempt.requirementRevision == task.requirementRevision { return attempt.provider }
        return task.runtimeConfig?.roles[role] ?? task.overrides.roles[role] ?? task.plan?.items.first(where: { $0.role == role })?.provider
    }

    static func attemptState(_ state: AttemptState) -> String {
        switch state {
        case .queued: return "排队中"
        case .starting: return "启动中"
        case .running: return "运行中"
        case .succeeded: return "本轮已结束"
        case .failed: return "本轮失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        }
    }

    static func itemState(_ state: WorkItemState) -> String {
        switch state {
        case .pending: return "待执行"
        case .running: return "执行中"
        case .delivered: return "已交付"
        case .integrated: return "已整合"
        }
    }

    static func delivery(_ state: MessageDelivery) -> String {
        switch state {
        case .queued: return "待送达"
        case .delivered: return "已送达"
        case .processed: return "已处理"
        }
    }
}

struct WorkspaceEmpty: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 22, weight: .light))
                .foregroundStyle(HubDesign.accent).accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: .infinity).padding(20)
    }
}

struct WorkspaceSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(HubDesign.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .modifier(BoardCardSurface())
    }
}

enum WorkspaceIssue: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let detail): return detail }
    }
}

enum WorkspaceModal: String, Identifiable {
    case revision, decision, team, plan
    var id: Self { self }
}
