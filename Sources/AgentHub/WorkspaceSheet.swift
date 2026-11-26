import SwiftUI
import HubKit
import HubProviders

struct WorkspaceSheet: View {
    let taskID: String
    let modal: WorkspaceModal
    @EnvironmentObject private var hub: HubController
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @State private var criteria = ""
    @State private var decision = ""
    @State private var saving = false
    @State private var error: String?
    @State private var selectedRole = "lead"
    @State private var selectedProvider: ProviderID = .codex
    @State private var history: [PlanRevision] = []
    private var task: HubTask? { hub.tasks.first { $0.id == taskID } }

    private var title: String {
        switch modal {
        case .revision: return "修订任务需求"
        case .decision: return "共享决策"
        case .team: return "任务团队"
        case .plan: return "计划与依赖"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(title).font(.title2.weight(.semibold)); Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            if let task {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch modal {
                        case .revision:
                            Text("当前为第 \(task.requirementRevision) 版。保存后将重新规划分工，并按新版本复核验收结果。")
                                .foregroundStyle(.secondary).font(.callout)
                            Text("任务目标").font(.headline)
                            TextEditor(text: $goal).frame(minHeight: 72).accessibilityLabel("新任务目标")
                            Text("验收条件（每行一项）").font(.headline)
                            TextEditor(text: $criteria).frame(minHeight: 78).accessibilityLabel("修订验收条件")
                            impact(task)
                        case .decision:
                            if !task.decisions.isEmpty { WorkspaceSection(title: "已达成的决策", icon: "person.2") {
                                ForEach(Array(task.decisions.enumerated()), id: \.offset) { _, value in Text(value).textSelection(.enabled) }
                            } }
                            Text("新增共享决策").font(.headline)
                            Text("填写影响接口、数据或多个角色的约定。保存后，负责人将把它带入新一版计划。")
                                .foregroundStyle(.secondary).font(.callout)
                            TextEditor(text: $decision).frame(minHeight: 90).accessibilityLabel("共享决策内容")
                            impact(task)
                        case .team:
                            roster(task)
                            if !task.isArchived && task.state != .cancelled {
                                Divider()
                                Text("调整角色连接").font(.headline)
                                HStack {
                                    Picker("角色", selection: $selectedRole) {
                                        ForEach(["lead", "frontend", "backend", "test", "review"], id: \.self) { Text(WorkspaceRole.title($0)).tag($0) }
                                    }
                                    Picker("连接", selection: $selectedProvider) {
                                        ForEach(ProviderID.allCases) { Text($0.displayName).tag($0) }
                                    }
                                }.onChange(of: selectedRole) { _, role in
                                    if let provider = configured(role, task: task) { selectedProvider = provider }
                                }
                                Text("改派会保存交接记录并重新规划。新的尝试使用所选连接及其账号的额度。")
                                    .foregroundStyle(.secondary).font(.callout)
                            }
                        case .plan:
                            if let plan = task.plan { planDetails(plan) }
                            else { WorkspaceEmpty(icon: "list.bullet.rectangle", title: "还没有当前版本的计划") }
                            let older = history.filter { $0.revision != task.plan?.revision }
                            if !older.isEmpty {
                                DisclosureGroup("历史计划（\(older.count)）") {
                                    VStack(alignment: .leading, spacing: 12) {
                                        ForEach(older.reversed(), id: \.revision) { value in planDetails(value) }
                                    }.padding(.top, 8)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error { Text(error).font(.caption).foregroundStyle(HubDesign.amber).textSelection(.enabled) }
                if modal != .plan {
                    HStack {
                        Spacer()
                        if saving { ProgressView().controlSize(.small) }
                        Button(modal == .team ? "确认改派" : (modal == .revision ? "保存新版本" : "共享并重新规划")) {
                            submit()
                        }.keyboardShortcut(.defaultAction).disabled(!canSave(task) || saving)
                    }
                }
            }
        }.padding(22).frame(minWidth: 475, idealWidth: 540, minHeight: 350, idealHeight: 455)
        .onAppear {
            guard let task else { return }
            goal = task.goal
            criteria = task.acceptance.joined(separator: "\n")
            selectedProvider = configured(selectedRole, task: task) ?? .codex
            if modal == .plan {
                do { history = try hub.store?.planHistory(taskID: task.id) ?? [] }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    private func configured(_ role: String, task: HubTask) -> ProviderID? {
        WorkspaceRole.provider(role, task: task) ?? (try? hub.store?.effectiveConfiguration(for: task).roles[role]) ?? nil
    }

    @ViewBuilder private func impact(_ task: HubTask) -> some View {
        let items = task.plan?.items ?? []
        if !items.isEmpty || !task.verifications.isEmpty {
            DisclosureGroup("需要重新评估的工作（\(items.count) 项分工，\(task.verifications.count) 条验证记录）") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { Text("• " + $0.title) }
                    ForEach(task.verifications.filter { $0.requirementRevision == task.requirementRevision }) { Text("• " + HubPresentation.verificationTitle($0.name)) }
                }.frame(maxWidth: .infinity, alignment: .leading).font(.caption)
            }
        }
    }

    private func roster(_ task: HubTask) -> some View {
        let roles = WorkspaceRole.roles(in: task)
        return VStack(alignment: .leading, spacing: 9) {
            ForEach(roles, id: \.self) { role in
                HStack {
                    Label(WorkspaceRole.title(role), systemImage: WorkspaceRole.icon(role))
                    Spacer()
                    Text(configured(role, task: task)?.displayName ?? "尚未分配").foregroundStyle(.secondary)
                }
                ForEach(task.plan?.items.filter { $0.role == role } ?? []) { item in
                    Text(item.title).font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                }
            }
        }
    }

    private func planDetails(_ plan: PlanRevision) -> some View {
        WorkspaceSection(title: "计划 \(plan.revision) · 需求 \(plan.requirementRevision)", icon: "list.bullet.indent") {
            Text(plan.goal).textSelection(.enabled)
            ForEach(plan.items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.callout.weight(.semibold)).textSelection(.enabled)
                    Text("\(WorkspaceRole.title(item.role)) · \(item.provider.displayName) · \(WorkspaceRole.itemState(item.state))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !item.dependencies.isEmpty {
                        let titles = item.dependencies.map { id in plan.items.first(where: { $0.id == id })?.title ?? id }
                        Text("依赖 " + titles.joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                    }
                    if !item.deliverables.isEmpty { Text("交付 " + item.deliverables.joined(separator: "、")).font(.caption) }
                }
            }
            planLines(plan.interfaces, title: "接口约定")
            planLines(plan.acceptance, title: "验收条件")
            planLines(plan.checks, title: "验证方案")
            planLines(plan.questions, title: "待确认")
        }
    }

    @ViewBuilder private func planLines(_ values: [String], title: String) -> some View {
        if !values.isEmpty { DisclosureGroup(title) {
            Text(values.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        } }
    }

    private var acceptance: [String] {
        criteria.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func canSave(_ task: HubTask) -> Bool {
        guard !task.isArchived, task.state != .cancelled else { return false }
        switch modal {
        case .revision: return !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (goal != task.goal || acceptance != task.acceptance)
        case .decision: return !decision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .team: return selectedProvider != configured(selectedRole, task: task)
        case .plan: return false
        }
    }

    private func submit() {
        guard let engine = hub.engine, let task, canSave(task) else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                switch modal {
                case .revision: try await engine.changeRequirements(taskID, goal: goal, acceptance: acceptance)
                case .decision: try await engine.addDecision(taskID, text: decision)
                case .team: try await engine.reassign(taskID, role: selectedRole, provider: selectedProvider)
                case .plan: break
                }
                hub.refresh()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
