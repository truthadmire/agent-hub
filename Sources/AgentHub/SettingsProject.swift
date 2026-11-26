import AppKit
import Foundation
import HubKit
import HubProviders
import SwiftUI

enum SettingsArguments {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? String(decoding: encoder.encode(value), as: UTF8.self)) ?? ""
    }

    static func one(_ source: String, name: String) throws -> [String]? {
        let raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        guard let result = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else {
            throw SettingsFailure.invalidCommand("\(name)需要一个 JSON 字符串数组。")
        }
        return try validate(result, name: name)
    }

    static func many(_ source: String) throws -> [[String]]? {
        let raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let decoder = JSONDecoder()
        if let commands = try? decoder.decode([[String]].self, from: Data(raw.utf8)) {
            return try commands.enumerated().map { try validate($0.element, name: "第 \($0.offset + 1) 条检查命令") }
        }
        if let one = try? decoder.decode([String].self, from: Data(raw.utf8)) {
            return [try validate(one, name: "检查命令")]
        }
        return try raw.components(separatedBy: .newlines).enumerated().compactMap {
            try one($0.element, name: "检查命令第 \($0.offset + 1) 行")
        }
    }

    private static func validate(_ argv: [String], name: String) throws -> [String] {
        guard let executable = argv.first, !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              argv.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw SettingsFailure.invalidCommand("\(name)需要有效的可执行文件名和参数。")
        }
        return argv
    }

    static func quote(_ argv: [String]) -> String {
        argv.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}

struct SettingsProjectView: View {
    @EnvironmentObject private var hub: HubController

    var body: some View {
        if let id = hub.selectedProjectID, let project = hub.projects.first(where: { $0.id == id }) {
            SettingsProjectEditor(project: project).id(id)
        } else {
            ContentUnavailableView("尚未选择项目", systemImage: "folder",
                                   description: Text("在主窗口导入或选择项目后，可在这里设置运行命令与默认角色。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SettingsProjectEditor: View {
    let project: HubProject
    @EnvironmentObject private var hub: HubController
    @State private var directory: String
    @State private var checks: String
    @State private var preview: String
    @State private var install: String
    @State private var environment: String
    @State private var defaults: HubConfiguration
    @State private var global = HubConfiguration.balanced
    @State private var statusMessage = ""
    @State private var isError = false
    @State private var relocating = false
    @State private var loadingSuggestions = false
    @State private var copied = false

    init(project: HubProject) {
        self.project = project
        let settings = project.configuration
        _directory = State(initialValue: settings.commandWorkingDirectory ?? "")
        _checks = State(initialValue: (settings.verificationCommands ?? []).map(SettingsArguments.encode).joined(separator: "\n"))
        _preview = State(initialValue: settings.previewCommand.map(SettingsArguments.encode) ?? "")
        _install = State(initialValue: settings.installCommand.map(SettingsArguments.encode) ?? "")
        _environment = State(initialValue: settings.commandEnvironment.map(SettingsArguments.encode) ?? "")
        _defaults = State(initialValue: settings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(title: "项目目录") {
                    HStack {
                        Label(project.name, systemImage: "folder").font(.headline)
                        Spacer()
                        Button("重新定位…", action: relocate).disabled(relocating)
                    }
                    Text(project.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    if !FileManager.default.fileExists(atPath: project.path) {
                        Label("当前路径不可用", systemImage: "exclamationmark.triangle").foregroundStyle(HubDesign.amber)
                    }
                }
                SettingsGroup(title: "运行命令") {
                    HStack {
                        Text("工作目录相对于隔离任务目录。").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("读取项目建议", action: suggest).disabled(loadingSuggestions)
                    }
                    TextField("工作目录（默认 .）", text: $directory).textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Divider()
                    commandField("构建与检查", help: "每行一个 JSON 参数数组。例如 [\"swift\",\"test\"]。", value: $checks, height: 76)
                    commandField("预览", help: "输入单条命令，独立端口参数可写 {port}。", value: $preview, height: 48)
                    commandField("手动准备依赖", help: "复制后可在任务目录的终端中运行。", value: $install, height: 48)
                    if let argv = try? SettingsArguments.one(install, name: "依赖命令") {
                        Button {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(SettingsArguments.quote(argv), forType: .string)
                        } label: { Label(copied ? "已复制" : "复制依赖命令", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    }
                    DisclosureGroup("非敏感环境变量") {
                        let names = ProjectTools.allowedEnvironmentNames.sorted().joined(separator: "、")
                        commandField("JSON 对象", help: "可用变量：\(names)", value: $environment, height: 58)
                            .padding(.top, 6)
                    }
                }
                SettingsGroup(title: "项目默认角色") {
                    ForEach(SettingsRole.all) { role in
                        let provider = defaults.roles[role.id] ?? global.roles[role.id] ?? .codex
                        HStack {
                            Text(role.name).frame(width: 53, alignment: .leading)
                            Spacer()
                            Picker("\(role.name)工具", selection: Binding<ProviderID?>(
                                get: { defaults.roles[role.id] },
                                set: { defaults.roles[role.id] = $0; defaults.models[role.id] = nil }
                            )) {
                                Text("跟随全局（\(global.roles[role.id]?.displayName ?? "CLI")）").tag(nil as ProviderID?)
                                ForEach(ProviderID.allCases) { id in Text(id.displayName).tag(Optional(id)) }
                            }.labelsHidden().frame(maxWidth: 205)
                            SettingsModelPicker(roleName: role.name, models: hub.connections[provider]?.models ?? [],
                                selected: Binding(get: { defaults.models[role.id] ?? "" },
                                                  set: { defaults.models[role.id] = $0.isEmpty ? nil : $0 }),
                                defaultTitle: modelDefault(role: role.id, provider: provider))
                        }
                    }
                }
                SettingsGroup(title: "项目预算") {
                    DisclosureGroup("覆盖全局默认值") {
                        VStack(alignment: .leading, spacing: 10) {
                            budget("同时执行", \.maxConcurrent, range: 1...32, unit: "个")
                            budget("执行尝试总数", \.maxAttempts, range: 1...1000, unit: "次")
                            budget("总运行时长", \.maxSeconds, range: 60...604800, step: 60, unit: "秒")
                            budget("失败后重试", \.maxRetries, range: 0...20, unit: "次")
                            budget("自动修复", \.maxRepairs, range: 0...20, unit: "次")
                        }.padding(.top, 8)
                    }
                }
            }.padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(statusMessage).font(.callout).foregroundStyle(isError ? HubDesign.amber : .secondary)
                    .textSelection(.enabled)
                Spacer()
                Button("保存项目设置", action: save).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.vertical, 11).background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
        }
        .onAppear {
            do { if let store = hub.store { global = .balanced.overriding(with: try store.globalConfiguration()) } }
            catch { report(error) }
        }
        .onChange(of: install) { _, _ in copied = false }
    }

    private func budget(_ title: String, _ key: WritableKeyPath<HubConfiguration, Int?>,
                        range: ClosedRange<Int>, step: Int = 1, unit: String) -> some View {
        let inherited = global[keyPath: key] ?? range.lowerBound
        return HStack {
            Toggle(title, isOn: Binding(get: { defaults[keyPath: key] != nil },
                                        set: { defaults[keyPath: key] = $0 ? inherited : nil }))
            Spacer()
            if let value = defaults[keyPath: key] {
                Stepper("\(value) \(unit)", value: Binding(get: { defaults[keyPath: key] ?? inherited },
                                                       set: { defaults[keyPath: key] = $0 }), in: range, step: step)
                    .accessibilityLabel(title)
            } else {
                Text("继承 \(inherited) \(unit)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modelDefault(role: String, provider: ProviderID) -> String {
        if global.roles[role] == provider, let model = global.models[role] { return "继承 \(model)" }
        return "CLI 默认模型"
    }

    private func commandField(_ title: String, help: String, value: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            Text(help).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: value).font(.caption.monospaced())
                .frame(height: height)
                .scrollContentBackground(.hidden).padding(4)
                .background(HubDesign.surface, in: RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(HubDesign.border).allowsHitTesting(false) }
                .accessibilityLabel(title)
        }
    }

    private func relativeDirectory() throws -> String? {
        let input = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        let root = URL(fileURLWithPath: project.path).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(input).standardizedFileURL.resolvingSymlinksInPath()
        guard !input.hasPrefix("/"), !input.utf8.contains(0),
              !input.split(separator: "/").contains(".."),
              candidate.path == root.path || candidate.path.hasPrefix(root.path + "/"),
              (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw SettingsFailure.invalidCommand("工作目录必须是项目内已存在的相对目录。")
        }
        return input
    }

    private func save() {
        do {
            guard let store = hub.store else { throw SettingsFailure.unavailable }
            var fresh = try store.project(project.id)
            fresh.configuration.commandWorkingDirectory = try relativeDirectory()
            let rawEnvironment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawEnvironment.isEmpty { fresh.configuration.commandEnvironment = nil }
            else {
                guard let fields = try? JSONDecoder().decode([String: String].self, from: Data(rawEnvironment.utf8)),
                      Set(fields.keys).isSubset(of: ProjectTools.allowedEnvironmentNames) else {
                    throw SettingsFailure.invalidCommand("环境变量必须是仅包含允许名称和字符串值的 JSON 对象。")
                }
                fresh.configuration.commandEnvironment = fields
            }
            fresh.configuration.verificationCommands = try SettingsArguments.many(checks)
            fresh.configuration.previewCommand = try SettingsArguments.one(preview, name: "预览命令")
            fresh.configuration.installCommand = try SettingsArguments.one(install, name: "依赖命令")
            fresh.configuration.roles = defaults.roles
            fresh.configuration.models = defaults.models
            fresh.configuration.maxConcurrent = defaults.maxConcurrent
            fresh.configuration.maxAttempts = defaults.maxAttempts
            fresh.configuration.maxSeconds = defaults.maxSeconds
            fresh.configuration.maxRetries = defaults.maxRetries
            fresh.configuration.maxRepairs = defaults.maxRepairs
            try store.saveProject(fresh)
            hub.refresh()
            isError = false
            statusMessage = "项目设置已保存，将用于后续任务。"
        } catch { report(error) }
    }

    private func suggest() {
        do {
            let root = URL(fileURLWithPath: project.path).appendingPathComponent(try relativeDirectory() ?? ".")
            loadingSuggestions = true
            Task {
                defer { loadingSuggestions = false }
                let suggestion = await Task.detached(priority: .userInitiated) { ProjectTools.detect(in: root) }.value
                checks = suggestion.checks.map { SettingsArguments.encode($0.argv) }.joined(separator: "\n")
                if case .command(let argv, _) = suggestion.preview { preview = SettingsArguments.encode(argv) }
                else { preview = "" }
                install = suggestion.installCommand.map(SettingsArguments.encode) ?? ""
                isError = false
                statusMessage = "已读取项目建议。保存后生效。"
            }
        } catch { report(error) }
    }

    private func relocate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "使用此目录"
        panel.message = "选择项目移动后的目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        relocating = true
        Task {
            defer { relocating = false }
            do {
                try await hub.relocateProject(projectID: project.id, at: url)
                isError = false
                statusMessage = "已更新项目路径。"
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        isError = true
        statusMessage = error.localizedDescription
    }
}
