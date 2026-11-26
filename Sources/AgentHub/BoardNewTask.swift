import AppKit
import HubKit
import HubProviders
import SwiftUI

struct BoardNewTask: View {
    @EnvironmentObject private var hub: HubController
    @Environment(\.dismiss) private var dismiss
    let project: HubProject
    let created: (HubTask, Bool) -> Void
    @State private var goal = ""
    @State private var criteria = ""
    @State private var priority = 0
    @State private var selectedRoles: [String: String] = [:]
    @State private var references: [String] = []
    @State private var concurrency = 0
    @State private var attempts = 0
    @State private var budget = ""
    @State private var reservation = ""
    @State private var advanced = false
    @State private var baseline = false
    @State private var changePreview: String?
    @State private var checking = false
    @State private var includeChanges = false
    @State private var creating = false
    @State private var error = ""
    @FocusState private var goalFocused: Bool

    private var budgetError: String? {
        for text in [budget, reservation] where !text.isEmpty {
            guard let value = Double(text), value.isFinite, value > 0 else { return "费用阈值和预留金额必须为大于零的美元数值。" }
        }
        if let maximum = Double(budget), let hold = Double(reservation), hold > maximum {
            return "单次预留不能超过整个任务的费用阈值。"
        }
        return nil
    }

    private var valid: Bool { !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && budgetError == nil && !creating }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "square.and.pencil").font(.title3).foregroundStyle(HubDesign.accent)
                    .frame(width: 36, height: 36).background(HubDesign.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text("新建任务").font(.title2.bold())
                    Text(project.name).font(.caption).foregroundStyle(HubDesign.muted)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭（Esc）")
                    .accessibilityLabel("关闭新建任务").keyboardShortcut(.cancelAction).disabled(creating)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("任务目标").font(.headline)
                        TextField("描述你想实现或修复的功能", text: $goal, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(3...7).focused($goalFocused)
                            .accessibilityLabel("任务目标").accessibilityIdentifier("task.goal")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("验收标准").font(.headline); Text("选填，每行一项").font(.caption).foregroundStyle(.secondary) }
                        TextField("怎样判断任务已经完成？", text: $criteria, axis: .vertical)
                            .lineLimit(2...6).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("验收标准").accessibilityIdentifier("task.acceptance")
                    }
                    HStack {
                        Picker("优先级", selection: $priority) {
                            Text("低").tag(-1); Text("普通").tag(0); Text("高").tag(1)
                        }.fixedSize()
                        Spacer()
                        Button { chooseReferences() } label: { Label("添加项目参考文件…", systemImage: "paperclip") }
                    }
                    ForEach(references, id: \.self) { item in
                        HStack {
                            Label(item, systemImage: "doc").lineLimit(2).font(.caption)
                            Spacer()
                            Button { references.removeAll { $0 == item } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).accessibilityLabel("移除参考文件 " + item)
                        }
                    }
                    Divider()
                    DisclosureGroup(isExpanded: $baseline) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("默认锁定创建任务时的 Git 提交，执行时创建独立工作区。")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                Button("检查未提交更改", action: loadChanges).disabled(checking)
                                if checking { ProgressView().controlSize(.small) }
                            }
                            if let changePreview {
                                if changePreview.isEmpty || changePreview == "工作区干净。" {
                                    Text("没有检测到未提交更改。").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    ScrollView([.horizontal, .vertical]) {
                                        Text(changePreview).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 110)
                                        .padding(7).background(HubDesign.lane, in: RoundedRectangle(cornerRadius: 6))
                                    Toggle("将未提交的更改纳入任务快照", isOn: $includeChanges)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    } label: {
                        Text(includeChanges ? "执行基线 · 包含未提交更改" : "执行基线 · Git 提交").font(.callout.weight(.semibold))
                    }
                    DisclosureGroup(isExpanded: $advanced) {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(["lead", "frontend", "backend", "test", "review"], id: \.self) { role in
                                HStack {
                                    Text(boardRoleName(role))
                                    Spacer()
                                    Picker(boardRoleName(role), selection: Binding(get: { selectedRoles[role] ?? "" }, set: { selectedRoles[role] = $0 })) {
                                        Text("继承设置").tag("")
                                        ForEach(ProviderID.allCases, id: \.self) { id in Text(id.displayName).tag(id.rawValue) }
                                    }.labelsHidden().frame(width: 150)
                                }
                            }
                            Divider()
                            HStack {
                                Text("同时运行上限")
                                Spacer()
                                Picker("同时运行上限", selection: $concurrency) {
                                    Text("继承设置").tag(0)
                                    ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
                                }.labelsHidden().frame(width: 150)
                            }
                            HStack {
                                Text("总尝试上限")
                                Spacer()
                                Stepper(attempts == 0 ? "继承设置" : "\(attempts) 次", value: $attempts, in: 0...100)
                            }
                            HStack {
                                Text("任务费用阈值（USD）")
                                Spacer()
                                TextField("继承设置", text: $budget).textFieldStyle(.roundedBorder)
                                    .frame(width: 150).accessibilityLabel("任务费用阈值，美元")
                            }
                            HStack {
                                Text("单次尝试预留（USD）")
                                Spacer()
                                TextField("继承设置", text: $reservation).textFieldStyle(.roundedBorder)
                                    .frame(width: 150).accessibilityLabel("单次尝试预留，美元")
                            }
                            if let budgetError { Text(budgetError).font(.caption).foregroundStyle(HubDesign.amber) }
                        }.padding(.top, 7)
                    } label: { Text("团队分工与执行上限").font(.callout.weight(.semibold)) }
                    if !error.isEmpty { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(HubDesign.amber).textSelection(.enabled) }
                }.padding(20)
            }
            Divider()
            HStack {
                if creating { ProgressView().controlSize(.small); Text("正在创建…").font(.caption) }
                Spacer()
                Button("创建并待开始") { submit(start: false) }.disabled(!valid).accessibilityIdentifier("task.create")
                Button("创建并开始") { submit(start: true) }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command).disabled(!valid).accessibilityIdentifier("task.start")
            }.padding(16)
        }
        .frame(minWidth: 440, idealWidth: 535, maxWidth: 650, minHeight: 410, idealHeight: 535, maxHeight: 760)
        .onAppear { goalFocused = true }
        .interactiveDismissDisabled(creating)
    }

    private func loadChanges() {
        checking = true; error = ""; includeChanges = false; changePreview = nil
        Task {
            defer { checking = false }
            do { changePreview = try await hub.workingChanges(projectID: project.id) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func chooseReferences() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: project.path)
        panel.title = "选择项目内参考文件或截图"
        panel.prompt = "添加参考"
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().standardizedFileURL.path + "/"
            for file in panel.urls {
                let path = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(root) else { error = "参考文件需位于当前项目内。"; continue }
                let relative = String(path.dropFirst(root.count))
                if !references.contains(relative) { references.append(relative) }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: apply) }
        else { panel.begin(completionHandler: apply) }
    }

    private func submit(start: Bool) {
        guard valid else { return }
        creating = true; error = ""
        var config = HubConfiguration()
        for (role, raw) in selectedRoles { config.roles[role] = ProviderID(rawValue: raw) }
        if concurrency > 0 { config.maxConcurrent = concurrency }
        if attempts > 0 { config.maxAttempts = attempts }
        config.maxCostUSD = Double(budget)
        config.reservedCostUSD = Double(reservation)
        var fullGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        if !references.isEmpty { fullGoal += "\n\n参考文件（项目相对路径）\n" + references.joined(separator: "\n") }
        let acceptance = criteria.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            defer { creating = false }
            do {
                let task = try await hub.createTask(projectID: project.id, goal: fullGoal, acceptance: acceptance,
                                                    priority: priority, overrides: config, includeUncommitted: includeChanges)
                created(task, start)
            } catch { self.error = error.localizedDescription }
        }
    }
}
