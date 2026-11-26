import AppKit
import Foundation
import HubGit
import HubKit

struct ResultSnapshot: Sendable {
    var workspace: GitWorkspace
    var head: String
    var files: [String]
    var pending: [GitChange]
    var artifacts: [URL]
    var commandDirectory: URL?
    var directoryError: String?
    var project: ProjectInspection?
    var preview: PreviewConfiguration?
    var install: [String]?
    var environment: [String: String]

    static func read(task: HubTask, service: GitWorkspaceService) throws -> Self {
        guard let id = UUID(uuidString: task.id) else { throw WorkspaceIssue.unavailable("任务缺少受管 Git 工作区标识。") }
        let workspace = try service.workspace(id: id)
        let head = try service.head(of: workspace)
        let files = try service.changedPaths(of: workspace, expectedHead: head)
        let pending = try service.status(of: workspace)
        let config = task.runtimeConfig ?? task.overrides
        let relative = config.commandWorkingDirectory ?? "."
        let commandDirectory = ProjectTools.directory(in: workspace.path, relative: relative)
        let project = commandDirectory.map { ProjectTools.detect(in: $0) }
        let customPreview: PreviewConfiguration? = config.previewCommand.flatMap { $0.isEmpty ? nil : .command(argv: $0) }
        let preview = customPreview ?? project?.preview
        let artifacts = commandDirectory.map { ProjectTools.artifacts(in: $0) } ?? []
        guard try service.head(of: workspace) == head else { throw WorkspaceIssue.unavailable("读取期间任务分支发生变化，请刷新成果。") }
        return Self(workspace: workspace, head: head, files: files,
                    pending: pending, artifacts: artifacts, commandDirectory: commandDirectory,
                    directoryError: commandDirectory == nil ? "运行目录不存在或超出任务工作区：\(relative)" : nil,
                    project: project, preview: preview, install: config.installCommand ?? project?.installCommand,
                    environment: config.commandEnvironment ?? [:])
    }
}

enum ResultFileAction {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func reveal(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw WorkspaceIssue.unavailable("文件或目录已移动。") }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor static func openEditor(_ url: URL) async throws {
        let choices = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4", "com.apple.dt.Xcode"]
        let editor: URL
        if let installed = choices.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            editor = installed
        } else {
            let chooser = NSOpenPanel()
            chooser.title = "选择用于打开工作区的编辑器"
            chooser.allowedContentTypes = [.application]
            chooser.directoryURL = URL(fileURLWithPath: "/Applications")
            guard await chooser.begin() == .OK, let selection = chooser.url else { return }
            editor = selection
        }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: .init())
    }

    static func formattedCommand(_ argv: [String]) -> String {
        argv.map { value in
            guard !value.isEmpty, value.range(of: #"^[A-Za-z0-9_./:=+%-]+$"#, options: .regularExpression) != nil
            else { return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            return value
        }.joined(separator: " ")
    }
}
