import AppKit
import HubKit
import HubProviders
import SwiftUI

enum BoardLane: String, CaseIterable, Identifiable {
    case queued, active, attention, done
    var id: Self { self }
    var title: String {
        switch self { case .queued: return "待开始"; case .active: return "进行中"; case .attention: return "需要你"; case .done: return "已完成" }
    }
    var emptyText: String {
        switch self { case .queued: return "没有待开始任务"; case .active: return "没有进行中的任务"; case .attention: return "没有待处理事项"; case .done: return "还没有完成的任务" }
    }
    var symbol: String {
        switch self { case .queued: return "circle.dashed"; case .active: return "bolt.circle"; case .attention: return "exclamationmark.bubble"; case .done: return "checkmark.circle" }
    }
    var color: Color {
        switch self { case .queued: return HubDesign.muted; case .active, .done: return HubDesign.accent; case .attention: return HubDesign.amber }
    }
    func includes(_ state: TaskState) -> Bool {
        switch self { case .queued: return state == .queued; case .active: return [.running, .pausing, .paused].contains(state); case .attention: return state == .needsUser; case .done: return state == .completed }
    }
}

struct BoardDashboard: View {
    var project: HubProject
    var tasks: [HubTask]
    var history: Bool
    @Binding var query: String
    @Binding var stateFilter: String
    @Binding var providerFilter: String
    let create: () -> Void
    let open: (HubTask) -> Void
    let relocate: () -> Void
    @State private var compactLane = BoardLane.queued
    @State private var missingDirectory = false

    private var scoped: [HubTask] { tasks.filter { history == ($0.isArchived || $0.state == .cancelled) } }
    private var filtered: [HubTask] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return scoped.filter { task in
            (key.isEmpty || [task.title, task.goal, task.summary, task.attentionReason.map(HubPresentation.attentionTitle) ?? ""].contains { $0.localizedCaseInsensitiveContains(key) })
            && (stateFilter.isEmpty || task.state.rawValue == stateFilter)
            && (providerFilter.isEmpty || BoardTaskCard.providers(in: task).contains { $0.rawValue == providerFilter })
        }
    }
    private var hasFilters: Bool { !query.isEmpty || !stateFilter.isEmpty || !providerFilter.isEmpty }

    var body: some View {
        GeometryReader { proxy in
            let items = filtered
            let byLane = Dictionary(grouping: items) { task in
                BoardLane.allCases.first { $0.includes(task.state) } ?? .queued
            }
            let narrow = proxy.size.width < 748
            let margin: CGFloat = narrow ? 18 : 26
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(history ? "历史归档" : "任务看板").font(.system(size: 28, weight: .bold)).foregroundStyle(HubDesign.ink)
                            HStack(spacing: 10) {
                                Label(project.name, systemImage: "folder")
                                if let branch = project.branch {
                                    Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                                }
                                if project.isDirty { Label("有未提交更改", systemImage: "pencil.circle").foregroundStyle(HubDesign.amber) }
                            }.font(.caption).foregroundStyle(HubDesign.muted)
                        }
                        Spacer(minLength: 6)
                        if !history {
                            Button(action: create) { Label("新建任务", systemImage: "plus") }
                                .buttonStyle(BoardPrimaryStyle()).accessibilityIdentifier("board.createTask")
                        }
                    }
                    if missingDirectory {
                        HStack {
                            Label("项目目录不可用", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(HubDesign.amber)
                            Spacer()
                            Button("重新定位…", action: relocate)
                        }.padding(9).background(HubDesign.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    filters
                }.padding(.horizontal, margin).padding(.top, margin).padding(.bottom, 17)
                Divider()
                if hasFilters && items.isEmpty {
                    ContentUnavailableView {
                        Label("没有匹配的任务", systemImage: "magnifyingglass")
                    } actions: { Button("清除筛选", action: clearFilters) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if history {
                    if items.isEmpty {
                        ContentUnavailableView("历史记录为空", systemImage: "archivebox", description: Text("已取消和归档的任务将显示在这里。"))
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(items.sorted { $0.updatedAt > $1.updatedAt }) { task in
                                    BoardTaskCard(task: task, open: { open(task) })
                                }
                            }.padding(margin)
                        }
                    }
                } else {
                    if narrow {
                        Picker("看板列", selection: $compactLane) {
                            ForEach(BoardLane.allCases) { lane in
                                Text("\(lane.title) \(byLane[lane, default: []].count)").tag(lane)
                            }
                        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, margin).padding(.top, 13)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(narrow ? [compactLane] : BoardLane.allCases) { lane in
                            column(lane, items: sortedTasks(byLane[lane] ?? [], in: lane))
                        }
                    }.padding(margin)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(HubDesign.surface)
        }
        .onAppear { checkDirectory() }
        .onChange(of: project.path) { _, _ in checkDirectory() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in checkDirectory() }
        .onChange(of: stateFilter) { _, value in
            guard let state = TaskState(rawValue: value), let lane = BoardLane.allCases.first(where: { $0.includes(state) }) else { return }
            compactLane = lane
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) { searchBox.frame(minWidth: 125, maxWidth: 340); filterMenus; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { searchBox; HStack(spacing: 8) { filterMenus } }
        }
    }

    private var searchBox: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(HubDesign.muted)
            TextField("搜索任务", text: $query).textFieldStyle(.plain).accessibilityLabel("搜索任务")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
            }
        }.padding(.horizontal, 9).frame(height: 29)
            .background(HubDesign.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(HubDesign.border).allowsHitTesting(false) }
    }

    @ViewBuilder private var filterMenus: some View {
        Picker("状态", selection: $stateFilter) {
            Text("全部状态").tag("")
            ForEach(TaskState.allCases.filter { history || $0 != .cancelled }, id: \.self) { state in
                Text(HubDesign.stateTitle(state)).tag(state.rawValue)
            }
        }.labelsHidden().fixedSize().accessibilityLabel("按任务状态筛选")
        Picker("工具", selection: $providerFilter) {
            Text("全部工具").tag("")
            ForEach(ProviderID.allCases, id: \.self) { id in Text(id.displayName).tag(id.rawValue) }
        }.labelsHidden().fixedSize().accessibilityLabel("按参与工具筛选")
        if hasFilters {
            Button(action: clearFilters) { Image(systemName: "xmark.circle") }.buttonStyle(.plain)
                .help("清除全部筛选").accessibilityLabel("清除全部筛选")
        }
    }

    private func clearFilters() { query = ""; stateFilter = ""; providerFilter = "" }
    private func checkDirectory() {
        let path = project.path
        Task {
            let exists = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
            if project.path == path { missingDirectory = !exists }
        }
    }

    private func sortedTasks(_ items: [HubTask], in lane: BoardLane) -> [HubTask] {
        items.sorted {
            if lane == .queued && $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func column(_ lane: BoardLane, items: [HubTask]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: lane.symbol).foregroundStyle(lane.color)
                Text(lane.title).font(.headline)
                Spacer(minLength: 0)
                Text("\(items.count)").font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(HubDesign.muted).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(HubDesign.panel, in: Capsule())
            }.padding(.horizontal, 11).padding(.vertical, 13)
            if lane == .active && items.contains(where: { $0.state == .paused || $0.state == .pausing }) {
                Text("正在运行 \(items.filter { $0.state == .running }.count) · 暂停中或已暂停 \(items.filter { $0.state == .paused || $0.state == .pausing }.count)")
                    .font(.caption2).foregroundStyle(HubDesign.muted)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text(lane.emptyText).font(.caption).foregroundStyle(HubDesign.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 21)
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(HubDesign.border, style: StrokeStyle(lineWidth: 1, dash: [3, 4])) }
                    }
                    ForEach(items) { task in BoardTaskCard(task: task, open: { open(task) }) }
                }.padding(.horizontal, 7).padding(.bottom, 8)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(HubDesign.lane, in: RoundedRectangle(cornerRadius: 11))
    }
}
