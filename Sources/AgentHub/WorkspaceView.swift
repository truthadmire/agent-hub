import SwiftUI
import HubKit

struct WorkspaceView: View {
    let taskID: String
    @EnvironmentObject private var hub: HubController

    var body: some View {
        if let task = hub.tasks.first(where: { $0.id == taskID }) {
            WorkspaceDetail(task: task).id(taskID)
        } else {
            WorkspaceEmpty(icon: "tray", title: "任务不可用", detail: "请返回看板，重新选择任务。")
        }
    }
}

private struct WorkspaceDetail: View {
    let task: HubTask
    @EnvironmentObject private var hub: HubController
    @AppStorage private var tab: String
    @AppStorage private var doublePane: Bool
    @AppStorage private var left: String
    @AppStorage private var right: String
    @AppStorage private var selectedPane: Int
    @AppStorage private var splitRatio: Double
    @State private var modal: WorkspaceModal?
    @State private var confirmCancel = false
    @State private var busy = false
    @GestureState private var dragDistance: CGFloat = 0

    init(task: HubTask) {
        self.task = task
        let prefix = "workspace.\(task.id)."
        _tab = AppStorage(wrappedValue: "collaboration", prefix + "tab")
        _left = AppStorage(wrappedValue: "", prefix + "left")
        _right = AppStorage(wrappedValue: "", prefix + "right")
        _selectedPane = AppStorage(wrappedValue: 0, prefix + "activePane")
        _doublePane = AppStorage(wrappedValue: true, prefix + "doublePane")
        _splitRatio = AppStorage(wrappedValue: 0.5, prefix + "splitRatio")
    }

    private var roles: [String] { WorkspaceRole.roles(in: task) }
    private var leftRole: String {
        if roles.contains(left) { return left }
        return roles.contains("frontend") ? "frontend" : roles.first ?? "lead"
    }
    private var rightRole: String {
        if roles.contains(right) && right != leftRole { return right }
        if roles.contains("backend") && leftRole != "backend" { return "backend" }
        return roles.first(where: { $0 != leftRole }) ?? leftRole
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 675
            VStack(alignment: .leading, spacing: 0) {
                header(narrow: narrow)
                HStack(spacing: 16) {
                    tabButton("协作", icon: "bubble.left.and.bubble.right", value: "collaboration")
                    tabButton("成果与验证", icon: "checkmark.rectangle.stack", value: "results")
                    Spacer()
                    if tab == "collaboration", roles.count > 1 {
                        if narrow || !doublePane {
                            Picker("当前面板", selection: $selectedPane) {
                                Text(WorkspaceRole.title(leftRole)).tag(0)
                                Text(WorkspaceRole.title(rightRole)).tag(1)
                            }
                            .labelsHidden().pickerStyle(.segmented).fixedSize()
                            .accessibilityLabel("切换当前角色面板")
                        }
                        if !narrow {
                            Button {
                                doublePane.toggle()
                            } label: {
                                Image(systemName: doublePane ? "rectangle" : "rectangle.split.2x1")
                            }.buttonStyle(.plain)
                            .help(doublePane ? "使用单面板" : "并排查看两个角色")
                            .accessibilityLabel(doublePane ? "使用单面板" : "并排查看两个角色")
                        }
                    }
                }.padding(.horizontal, 22)
                Divider()
                if tab == "results" {
                    ResultView(task: task)
                } else {
                    phaseStrip
                    let both = !narrow && doublePane && roles.count > 1
                    if both {
                        let usable = max(1, geometry.size.width - 40)
                        let leading = min(usable - 260, max(260, usable * splitRatio + dragDistance))
                        HStack(spacing: 0) {
                            pane(0).frame(width: leading)
                            Rectangle().fill(Color.clear).overlay {
                                Capsule().fill(HubDesign.border).frame(width: 3, height: 32)
                            }
                            .frame(width: 12).contentShape(Rectangle())
                            .gesture(DragGesture().updating($dragDistance) { value, state, _ in
                                state = value.translation.width
                            }.onEnded { value in
                                splitRatio = min(1 - 260 / usable, max(260 / usable, splitRatio + value.translation.width / usable))
                            })
                            .accessibilityLabel("调整面板宽度")
                            .accessibilityAdjustableAction { direction in
                                splitRatio = min(1 - 260 / usable, max(260 / usable, splitRatio + (direction == .increment ? 0.05 : -0.05)))
                            }
                            pane(1)
                        }.padding(.horizontal, 14).padding(.bottom, 14)
                    } else {
                        pane(roles.count > 1 ? selectedPane : 0).padding(.horizontal, narrow ? 12 : 18).padding(.bottom, 14)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(HubDesign.surface)
        }
        .sheet(item: $modal) { modal in WorkspaceSheet(taskID: task.id, modal: modal) }
        .alert("取消这个任务？", isPresented: $confirmCancel) {
            Button("保留任务", role: .cancel) {}
            Button("取消任务", role: .destructive) { run(.cancel) }
        } message: { Text("调度器将停止派发工作并结束正在执行的尝试。已有修改和记录可在成果页查看。") }
    }

    private func header(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { title; Spacer(minLength: 12); controls }
                VStack(alignment: .leading, spacing: 8) { title; controls }
            }
            if task.goal != task.title {
                Text(task.goal).font(.callout).lineLimit(2).foregroundStyle(.secondary).textSelection(.enabled).help(task.goal)
            }
            if !task.summary.isEmpty {
                Text("\(HubDesign.phaseTitle(task.phase))摘要 · \(task.summary)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(task.summary).textSelection(.enabled)
            }
            if let reason = task.attentionReason, !reason.isEmpty {
                Label(HubPresentation.attentionTitle(reason), systemImage: "exclamationmark.circle").font(.callout)
                    .foregroundStyle(HubDesign.amber).lineLimit(2).help(reason).textSelection(.enabled)
            }
        }.padding(.horizontal, narrow ? 14 : 22).padding(.top, 16).padding(.bottom, 8)
    }

    private var title: some View {
        HStack(spacing: 9) {
            Text(task.title).font(.system(size: 23, weight: .semibold)).foregroundStyle(HubDesign.ink)
                .lineLimit(2).help(task.title).accessibilityAddTraits(.isHeader)
            HubStateBadge(state: task.state)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            switch task.state {
            case .queued: Button { run(.start) } label: { Label("开始任务", systemImage: "play.fill") }
            case .running: Button { run(.pause) } label: { Label("暂停", systemImage: "pause.fill") }
            case .pausing: Label("正在暂停", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
            case .paused: Button { run(.resume) } label: { Label("继续", systemImage: "play.fill") }
            case .needsUser: Button { run(.resume) } label: { Label("继续处理", systemImage: "arrow.clockwise") }
            case .completed, .cancelled: EmptyView()
            }
            Menu {
                Button("查看分工与团队…") { modal = .team }
                Button("查看计划与依赖…") { modal = .plan }
                Divider()
                Button("修订任务需求…") { modal = .revision }.disabled(task.isArchived || task.state == .cancelled)
                Button("记录共享决策…") { modal = .decision }.disabled(task.isArchived || task.state == .cancelled)
                if task.state != .completed && task.state != .cancelled {
                    Divider()
                    Button("取消任务…", role: .destructive) { confirmCancel = true }
                }
            } label: { Label("任务操作", systemImage: "ellipsis.circle") }
        }.controlSize(.small).fixedSize().disabled(busy)
    }

    private func run(_ action: TaskAction) {
        guard !busy else { return }
        busy = true
        let id = task.id
        Task { @MainActor in
            defer { busy = false }
            do { try await hub.perform(action, taskID: id) } catch { hub.showError(error) }
        }
    }

    private func tabButton(_ title: String, icon: String, value: String) -> some View {
        Button { tab = value } label: {
            Label(title, systemImage: icon).font(.callout.weight(tab == value ? .semibold : .regular))
                .padding(.vertical, 10)
                .foregroundStyle(tab == value ? HubDesign.accent : HubDesign.muted)
                .overlay(alignment: .bottom) {
                    if tab == value { Capsule().fill(HubDesign.accent).frame(height: 2) }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
    }

    private var phaseStrip: some View {
        HStack(spacing: 6) {
            ForEach(TaskPhase.allCases, id: \.self) { phase in
                Text(HubDesign.phaseTitle(phase)).font(.caption.weight(phase == task.phase ? .semibold : .regular))
                    .foregroundStyle(phase == task.phase ? HubDesign.accent : HubDesign.muted)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(phase == task.phase ? HubDesign.accent.opacity(0.10) : .clear, in: Capsule())
                    .accessibilityLabel("\(HubDesign.phaseTitle(phase))\(phase == task.phase ? "，当前阶段" : "")")
                if phase != .repairing {
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
            Spacer(minLength: 2)
            Button { modal = .plan } label: { Label("计划", systemImage: "list.bullet.indent") }
                .buttonStyle(.plain).font(.caption).foregroundStyle(HubDesign.accent)
        }.padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func pane(_ index: Int) -> some View {
        let role = index == 0 ? leftRole : rightRole
        return WorkspacePane(task: task, role: role, roles: roles, select: { newRole in
            let oldLeft = leftRole
            let oldRight = rightRole
            if index == 0 {
                if newRole == oldRight { right = oldLeft }
                left = newRole
            } else {
                if newRole == oldLeft { left = oldRight }
                right = newRole
            }
        })
        .id(task.id + "/" + role)
    }
}
