import AppKit
import HubKit
import HubProviders
import SwiftUI

enum BoardDestination: String { case board, history }
private enum BoardSheet: String, Identifiable {
    case create, jump
    var id: Self { self }
}

struct BoardRoot: View {
    @EnvironmentObject private var hub: HubController
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsSection") private var settingsSection = "connections"
    @SceneStorage("board.destination") private var destination = BoardDestination.board.rawValue
    @SceneStorage("board.search") private var query = ""
    @SceneStorage("board.state") private var stateFilter = ""
    @SceneStorage("board.provider") private var providerFilter = ""
    @State private var visibility = NavigationSplitViewVisibility.automatic
    @State private var sheet: BoardSheet?
    @State private var importing = false

    private var project: HubProject? { hub.projects.first { $0.id == hub.selectedProjectID } }
    private var projectTasks: [HubTask] { hub.tasks.filter { $0.projectID == project?.id } }
    private var showingHistory: Bool { destination == BoardDestination.history.rawValue }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar.navigationSplitViewColumnWidth(min: 167, ideal: 196, max: 260)
        } detail: {
            ZStack {
                if let project {
                    BoardDashboard(project: project, tasks: projectTasks,
                                   history: showingHistory, query: $query,
                                   stateFilter: $stateFilter, providerFilter: $providerFilter,
                                   create: { sheet = .create }, open: { hub.selectedTaskID = $0.id },
                                   relocate: { chooseDirectory(.relocate(project.id)) })
                        .id(project.id)
                        .opacity(hub.selectedTaskID == nil ? 1 : 0)
                        .allowsHitTesting(hub.selectedTaskID == nil)
                        .disabled(hub.selectedTaskID != nil)
                        .accessibilityHidden(hub.selectedTaskID != nil)
                    if let selected = hub.selectedTaskID {
                        WorkspaceView(taskID: selected).id(selected)
                            .background(HubDesign.surface)
                    }
                } else {
                    BoardWelcome(importing: importing, importProject: { chooseDirectory(.open) },
                                 newProject: { chooseDirectory(.initialize) }, connections: showConnections)
                }
            }
            .navigationTitle(project?.name ?? "Agent Hub")
            .toolbar {
                if hub.selectedTaskID != nil {
                    ToolbarItem(placement: .navigation) {
                        Button { hub.selectedTaskID = nil } label: { Label("返回看板", systemImage: "chevron.left") }
                            .help("返回任务列表")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { sheet = .jump } label: { Label("快速跳转", systemImage: "magnifyingglass") }
                        .help("快速跳转（⌘K）")
                    if project != nil {
                        Button { sheet = .create } label: { Label("新建任务", systemImage: "plus") }
                            .help("新建任务（⌘N）").accessibilityIdentifier("board.newTask")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 650, minHeight: 495)
        .focusedSceneValue(\.boardMenu, sheet == nil ? BoardMenuActions(newTask: { sheet = .create },
            importProject: { chooseDirectory(.open) }, quickJump: { sheet = .jump }, canCreateTask: project != nil) : nil)
        .sheet(item: $sheet) { item in
            switch item {
            case .create:
                if let project {
                    BoardNewTask(project: project) { task, start in
                        sheet = nil
                        destination = BoardDestination.board.rawValue
                        hub.selectedTaskID = task.id
                        if start { Task { await handle { try await hub.perform(.start, taskID: task.id) } } }
                    }
                }
            case .jump:
                BoardQuickJump { projectID, taskID in
                    sheet = nil
                    selectProject(projectID)
                    if let taskID { hub.selectedTaskID = taskID }
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { hub.errorMessage != nil && sheet == nil }, set: { if !$0 { hub.errorMessage = nil } })) {
            Button("好") { hub.errorMessage = nil }
        } message: { Text(hub.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                HubMark(size: 32)
                Text("Agent Hub").font(.system(size: 18, weight: .bold)).tracking(-0.6)
            }.padding(.horizontal, 17).padding(.top, 17).padding(.bottom, 21)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    sidebarItem("任务看板", icon: "square.grid.2x2", selected: !showingHistory && hub.selectedTaskID == nil) {
                        destination = BoardDestination.board.rawValue; hub.selectedTaskID = nil
                        if stateFilter == TaskState.cancelled.rawValue { stateFilter = "" }
                    }
                    sidebarItem("历史归档", icon: "archivebox", selected: showingHistory && hub.selectedTaskID == nil) {
                        destination = BoardDestination.history.rawValue; hub.selectedTaskID = nil
                    }.disabled(project == nil)

                    HStack {
                        Text("项目").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            Button("导入 Git 项目…") { chooseDirectory(.open) }
                            Button("新建 Git 项目…") { chooseDirectory(.initialize) }
                        } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("添加项目").help("添加项目")
                    }.padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 4)
                    if hub.projects.isEmpty {
                        Button { chooseDirectory(.open) } label: {
                            Label("导入项目…", systemImage: "folder.badge.plus")
                                .foregroundStyle(HubDesign.muted).padding(.horizontal, 9).padding(.vertical, 6)
                        }.buttonStyle(.plain)
                    }
                    ForEach(hub.projects) { item in
                        Button { selectProject(item.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.id == project?.id ? "folder.fill" : "folder")
                                    .foregroundStyle(item.id == project?.id ? HubDesign.accent : HubDesign.muted)
                                Text(item.name).lineLimit(1)
                                Spacer(minLength: 0)
                                if item.id == project?.id { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(HubDesign.accent) }
                            }.padding(.vertical, 7).padding(.horizontal, 10).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(item.path)
                            .accessibilityValue(item.id == project?.id ? "当前项目" : "")
                            .contextMenu {
                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                                Button("重新定位项目…") { chooseDirectory(.relocate(item.id)) }
                            }
                    }
                }.padding(.horizontal, 9)
            }
            Divider().padding(.horizontal, 13)
            HStack {
                SettingsLink { Label("设置", systemImage: "gearshape") }
                    .buttonStyle(.plain).help("设置（⌘,）")
                Spacer()
                Button(action: showConnections) {
                    HStack(spacing: 5) {
                        Circle().fill(readyCount > 0 ? HubDesign.accent : HubDesign.muted).frame(width: 6, height: 6)
                        Text("连接 \(readyCount)/3").font(.caption.monospacedDigit())
                    }
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("已配置 \(readyCount) 个编码工具，打开连接设置")
            }.padding(.horizontal, 17).padding(.vertical, 15)
        }
    }

    private var readyCount: Int { hub.connections.values.filter(\.configured).count }

    private func sidebarItem(_ title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) { Image(systemName: icon).frame(width: 17); Text(title); Spacer() }
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .padding(.vertical, 8).padding(.horizontal, 10)
                .foregroundStyle(selected ? HubDesign.accent : Color.primary)
                .background(selected ? HubDesign.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func showConnections() { settingsSection = "connections"; openSettings() }

    private func selectProject(_ id: String) {
        if hub.selectedProjectID != id { query = ""; stateFilter = ""; providerFilter = "" }
        hub.selectedTaskID = nil
        hub.selectedProjectID = id
        destination = BoardDestination.board.rawValue
    }

    private enum DirectoryAction { case open, initialize, relocate(String) }

    private func chooseDirectory(_ action: DirectoryAction) {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        switch action {
        case .open:
            panel.title = "导入本地 Git 项目"
            panel.prompt = "导入项目"
            panel.message = "选择仓库根目录。Agent Hub 将读取 Git 状态和项目配置。"
        case .initialize:
            panel.title = "新建 Git 项目"
            panel.canCreateDirectories = true
            panel.prompt = "初始化 Git"
            panel.message = "选择一个空目录，或使用“新建文件夹”创建目录。Agent Hub 将在所选目录初始化 Git 仓库。"
        case .relocate:
            panel.title = "重新定位已有项目"
            panel.prompt = "使用此位置"
            panel.message = "选择项目移动后的仓库根目录。"
        }
        let complete: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            importing = true
            Task { @MainActor in
                defer { importing = false }
                await handle {
                    switch action {
                    case .open: selectProject(try await hub.importProject(at: url, initialize: false).id)
                    case .initialize: selectProject(try await hub.importProject(at: url, initialize: true).id)
                    case .relocate(let id): try await hub.relocateProject(projectID: id, at: url); selectProject(id)
                    }
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }

    @MainActor private func handle(_ action: () async throws -> Void) async {
        do { try await action() } catch { hub.errorMessage = error.localizedDescription }
    }
}
