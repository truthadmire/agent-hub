import AppKit
import SwiftUI
import HubKit
import HubGit

struct ResultView: View {
    let task: HubTask
    @EnvironmentObject private var hub: HubController
    @State private var snapshot: ResultSnapshot?
    @State private var error: String?
    @State private var refreshID = 0
    @State private var working = false
    @State private var showDiff = false
    @State private var adopt = false
    @State private var previewURL: URL?
    @State private var feedback: String?
    @State private var visibleFiles = 36
    @State private var fetching = false

    private var version: String {
        [task.id, task.workspace?.path ?? "", task.workspace?.snapshot ?? "", task.state.rawValue,
         task.phase.rawValue, String(task.requirementRevision), String(task.verifications.count),
         String(refreshID)].joined(separator: "|")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("交付工作区").font(.headline).foregroundStyle(HubDesign.ink)
                    Spacer()
                    Button { refreshID += 1 } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .controlSize(.small).disabled(fetching)
                }
                if let error { Text(error).foregroundStyle(HubDesign.amber).textSelection(.enabled) }
                if let feedback { Text(feedback).font(.caption).foregroundStyle(HubDesign.accent).textSelection(.enabled) }
                if let snapshot {
                    repository(snapshot)
                    fileList(snapshot)
                } else if task.workspace == nil {
                    WorkspaceEmpty(icon: "point.3.connected.trianglepath.dotted", title: "任务尚未建立成果分支",
                                   detail: "建立受管工作区后，可以在这里查看修改和分支。")
                        .modifier(BoardCardSurface())
                } else if fetching { ProgressView().controlSize(.small) }
                ResultVerification(task: task, commit: snapshot.flatMap { $0.pending.isEmpty ? $0.head : nil })
                if let snapshot { outputs(snapshot) }
                ResultHistory(task: task)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: version) { await load() }
        .task(id: task.id) {
            while !Task.isCancelled {
                previewURL = await PreviewManager.shared.url(for: task.id)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .sheet(isPresented: $showDiff) {
            if let snapshot, let service = hub.git {
                ResultDiff(snapshot: snapshot, service: service)
            }
        }
        .alert("将成果采用到原项目？", isPresented: $adopt, presenting: snapshot) { value in
            Button("返回检查", role: .cancel) {}
            Button("采用这个提交") { adoptResult(value) }
        } message: { value in
            let branch = value.workspace.project.branch ?? "分离的 HEAD"
            Text("原项目 \(branch) 将快进到 \(value.head.prefix(12))。原项目必须干净，并仍在创建任务时的分支和提交上。当前任务\(HubDesign.stateTitle(task.state))。")
        }
    }

    private func repository(_ value: ResultSnapshot) -> some View {
        WorkspaceSection(title: value.workspace.branch, icon: "point.3.connected.trianglepath.dotted") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow { Text("基线"); mono(value.workspace.baseline) }
                GridRow { Text("提交"); mono(value.head) }
                GridRow { Text("目录"); mono(value.workspace.path.path) }
            }.font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { repositoryButtons(value) }
                VStack(alignment: .leading, spacing: 6) {
                    HStack { deliveryButtons(value) }
                    filesMenu(value)
                }
            }.controlSize(.small)
        }
    }

    @ViewBuilder private func repositoryButtons(_ value: ResultSnapshot) -> some View {
        deliveryButtons(value)
        filesMenu(value)
    }

    @ViewBuilder private func deliveryButtons(_ value: ResultSnapshot) -> some View {
        Button("查看差异") { showDiff = true }
        Button("导出补丁…") { export(value) }.disabled(working)
        Button("采用成果…") { adopt = true }
            .disabled(working || value.files.isEmpty || !value.pending.isEmpty || [.running, .pausing].contains(task.state))
    }

    private func filesMenu(_ value: ResultSnapshot) -> some View {
        Menu("工作区操作") {
            Button("在编辑器中打开") { perform { try await ResultFileAction.openEditor(value.workspace.path) } }
            Button("在访达中显示") { perform { try ResultFileAction.reveal(value.workspace.path) } }
            Button("复制工作区路径") { ResultFileAction.copy(value.workspace.path.path) }
            Button("复制分支名") { ResultFileAction.copy(value.workspace.branch) }
        }.fixedSize()
    }

    private func mono(_ value: String) -> some View {
        Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2).help(value)
    }

    private func fileList(_ value: ResultSnapshot) -> some View {
        WorkspaceSection(title: "修改文件（\(value.files.count)）", icon: "doc.on.doc") {
            if value.files.isEmpty { Text("任务分支相对基线没有已提交的文件差异。").font(.callout).foregroundStyle(.secondary) }
            ForEach(value.files.prefix(visibleFiles), id: \.self) { path in
                HStack {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                    Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button { ResultFileAction.copy(path) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).accessibilityLabel("复制文件路径 \(path)")
                }
            }
            if value.files.count > visibleFiles { Button("显示更多文件") { visibleFiles += 36 }.buttonStyle(.link) }
            if !value.pending.isEmpty {
                DisclosureGroup("另有 \(value.pending.count) 项未提交变更") {
                    Text(value.pending.map { $0.code + "  " + $0.path }.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.foregroundStyle(HubDesign.amber)
            }
        }
    }

    private func outputs(_ value: ResultSnapshot) -> some View {
        WorkspaceSection(title: "预览与产物", icon: "macwindow") {
            if let problem = value.directoryError { Text(problem).foregroundStyle(HubDesign.amber) }
            if let url = previewURL {
                Text(url.absoluteString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("在浏览器中打开") { openPreview(expected: url) }
                    Button("停止预览进程") {
                        perform { await PreviewManager.shared.stop(taskID: task.id); previewURL = nil }
                    }
                }.controlSize(.small)
            } else if let configuration = value.preview, let root = value.commandDirectory {
                let previewHelp = previewRestriction(configuration)
                Button(working ? "正在处理…" : "启动本地预览") {
                    perform {
                        guard let engine = hub.engine else { throw WorkspaceIssue.unavailable("任务执行器未连接。") }
                        let url = try await engine.startPreview(task.id, root: root, configuration: configuration,
                                                                environment: value.environment)
                        guard url == (await PreviewManager.shared.url(for: task.id)) else { throw WorkspaceIssue.unavailable("预览进程已退出。") }
                        previewURL = url
                        guard NSWorkspace.shared.open(url) else { throw WorkspaceIssue.unavailable("无法打开默认浏览器。") }
                    }
                }.disabled(working || previewHelp != nil).controlSize(.small)
                if let previewHelp { Text(previewHelp).font(.caption).foregroundStyle(.secondary) }
            } else if let project = value.project {
                if project.checks.isEmpty { Text("当前项目未识别到可运行的预览或构建命令。").font(.caption).foregroundStyle(.secondary) }
                else {
                    Text(project.checks.map { ResultFileAction.formattedCommand($0.argv) }.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let install = value.install, !install.isEmpty, let directory = value.commandDirectory {
                DisclosureGroup("依赖准备命令") {
                    VStack(alignment: .leading, spacing: 5) {
                        mono(directory.path)
                        mono(ResultFileAction.formattedCommand(install))
                        Button("复制命令与目录") {
                            let cd = ResultFileAction.formattedCommand(["cd", directory.path])
                            ResultFileAction.copy(cd + " && " + ResultFileAction.formattedCommand(install))
                        }.controlSize(.small)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
            ForEach(value.artifacts, id: \.path) { url in
                Button { perform { try ResultFileAction.reveal(url) } } label: { Label(url.lastPathComponent, systemImage: "folder") }
                    .buttonStyle(.link).help(url.path)
            }
            ForEach(task.artifacts) { artifact in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(artifact.title).font(.callout.weight(.medium))
                        Spacer()
                        Button("显示产物") {
                            perform { try ResultFileAction.reveal(URL(fileURLWithPath: artifact.path)) }
                        }.buttonStyle(.link).font(.caption)
                    }
                    mono(artifact.path)
                }
            }
        }
    }

    private func previewRestriction(_ config: PreviewConfiguration) -> String? {
        switch task.state {
        case .needsUser, .completed: return nil
        case .paused:
            if case .staticSite = config { return nil }
            return "命令预览可在任务完成或等待你处理时启动。"
        default: return "这个任务当前无法启动预览。"
        }
    }

    private func load() async {
        error = nil
        guard task.workspace != nil, let service = hub.git else { snapshot = nil; return }
        fetching = true
        do {
            let updated = try await Task.detached(priority: .userInitiated) { try ResultSnapshot.read(task: task, service: service) }.value
            guard !Task.isCancelled else { return }
            snapshot = updated
        } catch {
            guard !Task.isCancelled else { return }
            snapshot = nil; self.error = error.localizedDescription
        }
        fetching = false
    }

    private func openPreview(expected: URL) {
        perform {
            guard let live = await PreviewManager.shared.url(for: task.id), expected == live else {
                previewURL = nil
                throw WorkspaceIssue.unavailable("此任务的预览已停止，请重新启动。")
            }
            guard NSWorkspace.shared.open(live) else { throw WorkspaceIssue.unavailable("无法打开默认浏览器。") }
        }
    }

    private func export(_ value: ResultSnapshot) {
        guard let service = hub.git else { return }
        perform {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "agent-hub-" + String(value.head.prefix(12)) + ".patch"
            panel.prompt = "导出"
            panel.canCreateDirectories = true
            guard await panel.begin() == .OK, let url = panel.url else { return }
            try await Task.detached { try service.exportPatch(of: value.workspace, to: url, expectedHead: value.head) }.value
            feedback = "补丁已导出到 " + url.path
        }
    }

    private func adoptResult(_ value: ResultSnapshot) {
        guard let service = hub.git else { return }
        let revision = task.requirementRevision
        perform {
            guard let latest = try hub.store?.task(task.id), latest.requirementRevision == revision,
                  ![.running, .pausing].contains(latest.state) else { throw WorkspaceIssue.unavailable("任务已变化，请刷新并重新检查成果。") }
            let head = try await Task.detached {
                try service.adopt(task: value.workspace, expectedTaskHead: value.head, expectedSourceHead: value.workspace.project.head)
            }.value
            feedback = "已将提交 \(head.prefix(12)) 采用到原项目。"
            try hub.store?.appendEvent(taskID: task.id, kind: "result.adopted", detail: "本地采用 " + head)
            hub.refresh()
        }
    }

    private func perform(_ body: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        feedback = nil
        Task { @MainActor in
            defer { working = false }
            do { try await body() } catch { hub.showError(error) }
        }
    }
}
