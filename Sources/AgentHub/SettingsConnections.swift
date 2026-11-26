import AppKit
import HubProviders
import SwiftUI

struct SettingsConnectionsView: View {
    @EnvironmentObject private var hub: HubController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("本机 CLI 与认证").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await hub.refreshConnections() }
                    } label: {
                        Label("重新检测全部", systemImage: "arrow.clockwise")
                    }.disabled(!hub.detectingProviders.isEmpty)
                }
                ForEach(ProviderID.allCases) { id in SettingsConnectionRow(id: id) }
            }.padding(20)
        }
        .task { if hub.connections.isEmpty { await hub.refreshConnections() } }
    }
}

private enum ConnectionPrompt: String, Identifiable {
    case login, test, removeKey
    var id: Self { self }
}

private struct SettingsConnectionRow: View {
    let id: ProviderID
    @EnvironmentObject private var hub: HubController
    @State private var expanded = false
    @State private var key = ""
    @State private var prompt: ConnectionPrompt?
    private var testing: Bool { hub.testingProviders.contains(id) }
    @State private var statusMessage = ""
    @State private var enabled = true
    @State private var hasKey = false
    @State private var checkedKeychain = false
    @State private var cachedInspection: CachedCLIInspection?
    @AppStorage private var lastTest: String
    @AppStorage private var lastTestDate: Double

    init(id: ProviderID) {
        self.id = id
        _lastTest = AppStorage(wrappedValue: "", "connectionTestResult.\(id.rawValue)")
        _lastTestDate = AppStorage(wrappedValue: 0, "connectionTestTime.\(id.rawValue)")
    }

    private var connection: ProviderConnection? { hub.connections[id] }
    private var detecting: Bool { hub.detectingProviders.contains(id) }

    private var authLabel: String {
        switch connection?.auth {
        case .subscription: return "官方账号"
        case .apiKeySaved: return "API key 已保存"
        case .externalAPIKey: return "外部 API key"
        case .signedOut: return id == .dsh ? "尚未保存密钥" : "未登录"
        case .unknown, .none: return "尚未确认"
        }
    }

    private var status: (label: String, icon: String, color: Color) {
        if !enabled { return ("已停用", "pause.circle", .secondary) }
        if detecting { return ("检测中", "clock", .secondary) }
        guard let connection else { return ("待检测", "circle.dashed", .secondary) }
        guard connection.executable != nil else { return ("未安装", "arrow.down.circle", HubDesign.amber) }
        guard connection.compatible else { return ("版本不兼容", "exclamationmark.triangle", HubDesign.amber) }
        switch connection.auth {
        case .signedOut: return (id == .dsh ? "待保存密钥" : "未登录", "person.crop.circle.badge.exclamationmark", HubDesign.amber)
        case .subscription: return ("已登录", "checkmark.circle", HubDesign.accent)
        case .apiKeySaved: return ("密钥已保存", "key", HubDesign.accent)
        case .externalAPIKey: return ("需要官方账号", "key", HubDesign.amber)
        case .unknown: return ("认证待验证", "questionmark.circle", HubDesign.amber)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                expanded.toggle()
                if !expanded { key = "" }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: id == .codex ? "terminal" : id == .antigravity ? "sparkles" : "cpu")
                        .font(.title3).foregroundStyle(HubDesign.accent)
                        .frame(width: 35, height: 35)
                        .background(HubDesign.hero, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(id.displayName).font(.headline).foregroundStyle(.primary)
                        Text(connection?.version ?? (connection == nil ? cachedInspection?.version : nil) ?? id.executableName).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(status.label, systemImage: status.icon).font(.caption.weight(.semibold)).foregroundStyle(status.color)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(id.displayName)，\(status.label)，\(expanded ? "收起" : "展开")连接详情")
            if expanded {
                Divider()
                details
            }
        }
        .padding(14).modifier(BoardCardSurface())
        .onAppear {
            cachedInspection = hub.cachedInspection(id)
            do {
                enabled = !(try hub.store?.globalConfiguration().disabledProviders?.contains(id) ?? false)
                try readKeychainState()
            } catch { statusMessage = error.localizedDescription }
        }
        .onDisappear { key = "" }
        .sheet(item: $prompt) { item in
            actionSheet(item)
        }
    }

    @ViewBuilder private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
            if connection == nil, let cachedInspection {
                detailLine("上次检出路径", cachedInspection.path ?? "未找到", mono: true)
            } else {
                detailLine("可执行文件", connection?.executable?.path ?? "未找到", mono: true)
            }
            detailLine("认证方式", id == .dsh ? "自己的 DeepSeek API key" : "官方 CLI 账号")
            detailLine("认证状态", authLabel)
            detailLine("协议兼容性", connection.map { $0.executable == nil ? "待检测" : $0.compatible ? "兼容" : "不兼容" } ?? "待检测")
            detailLine("最后检测", (connection?.checkedAt ?? cachedInspection?.checkedAt)?.formatted(date: .abbreviated, time: .shortened) ?? "尚未检测")
            if let detail = connection?.detail, !detail.isEmpty {
                detailLine("检测结果", detail)
            }
            if let models = connection?.models, !models.isEmpty {
                detailLine("可用模型", models.joined(separator: "、"), mono: true)
            }
            if lastTestDate > 0 {
                let date = Date(timeIntervalSince1970: lastTestDate).formatted(date: .abbreviated, time: .shortened)
                detailLine("上次短请求", "\(lastTest) · \(date)")
            }
        }.font(.callout)
        Toggle("允许用于任务", isOn: Binding(get: { enabled }, set: { value in
            do {
                try hub.updateGlobalSettings { config in
                    var ids = (config.disabledProviders ?? []).filter { $0 != id }
                    if !value { ids.append(id) }
                    config.disabledProviders = ids
                }
                enabled = value
            } catch { statusMessage = error.localizedDescription }
        }))
        ViewThatFits(in: .horizontal) {
            HStack { discoveryButtons }
            VStack(alignment: .leading, spacing: 8) { discoveryButtons }
        }
        if id == .dsh {
            Divider()
            Text(checkedKeychain ? (hasKey ? "钥匙串中已保存 DeepSeek API key。" : "钥匙串中还没有 DeepSeek API key。") : "钥匙串状态未知。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                SecureField(hasKey ? "输入新的 API key" : "输入 DeepSeek API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button("保存到钥匙串") { changeKey(save: true) }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing || detecting)
                if hasKey {
                    Button("移除…", role: .destructive) { prompt = .removeKey }
                        .disabled(testing || detecting)
                }
            }
        }
        HStack {
            if id != .dsh {
                Button("登录 / 重新登录…") { prompt = .login }
            }
            Button("测试连接…") { prompt = .test }
                .disabled(testing || detecting || connection?.configured != true || connection?.executable == nil ||
                          (id == .dsh && !hasKey))
            if testing { ProgressView().controlSize(.small); Text("等待短请求结果…").font(.caption) }
        }
        if !statusMessage.isEmpty { Text(statusMessage).font(.callout).foregroundStyle(HubDesign.amber).textSelection(.enabled) }
    }

    @ViewBuilder private var discoveryButtons: some View {
        Button("检测安装") { Task { await hub.refreshConnection(id) } }.disabled(detecting || testing)
        Button("选择 CLI…", action: chooseCLI).disabled(detecting || testing)
        if hub.cliOverride(id) != nil {
            Button("恢复自动查找") { changeCLI(nil) }.disabled(detecting || testing)
        }
        Link("官方安装说明", destination: id.installURL)
    }

    private func detailLine(_ title: String, _ value: String, mono: Bool = false) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: value).font(mono ? .caption.monospaced() : .callout)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func actionSheet(_ item: ConnectionPrompt) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch item {
            case .login:
                Text("\(id.displayName) 账号登录").font(.title2.weight(.semibold))
                Text(id.loginInstructions)
                Text(loginCommand).font(.body.monospaced()).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Link("官方说明", destination: id.installURL)
                    Spacer()
                    Button("完成") { prompt = nil }.keyboardShortcut(.cancelAction)
                    Button("复制命令并打开终端") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(loginCommand, forType: .string)
                        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                            NSWorkspace.shared.openApplication(at: terminal, configuration: .init()) { _, _ in }
                        }
                        prompt = nil
                    }.keyboardShortcut(.defaultAction)
                }
            case .test:
                Text("测试 \(id.displayName) 连接？").font(.title2.weight(.semibold))
                Text("将从独立临时目录发送一次简短的模型测试。运行时间上限为 30 秒。")
                Text(id == .dsh ? "这次调用将使用你保存在钥匙串中的 DeepSeek API key，费用由对应 API 账户承担。" :
                        "这次调用将使用此 CLI 的官方账号，可能消耗该账号的可用额度。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("取消") { prompt = nil }.keyboardShortcut(.cancelAction)
                    Button("发送一次测试") { prompt = nil; testConnection() }
                }
            case .removeKey:
                Text("移除 DeepSeek API key？").font(.title2.weight(.semibold))
                Text("将删除 Agent Hub 存在本机钥匙串中的这项凭据。后续 DSH 任务需要重新保存 API key。")
                HStack { Spacer(); Button("取消") { prompt = nil }.keyboardShortcut(.cancelAction)
                    Button("移除密钥", role: .destructive) { prompt = nil; changeKey(save: false) }
                }
            }
        }.padding(24).frame(width: 425)
    }

    private var loginCommand: String {
        let path = connection?.executable?.path ?? id.executableName
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return id == .codex ? quoted + " login" : quoted
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 \(id.displayName) 的可执行文件"
        panel.prompt = "使用此 CLI"
        if panel.runModal() == .OK, let url = panel.url { changeCLI(url) }
    }

    private func changeCLI(_ url: URL?) {
        Task {
            do {
                try await hub.setCLIOverride(url, for: id)
                lastTestDate = 0
                statusMessage = ""
            } catch { statusMessage = error.localizedDescription }
        }
    }

    private func readKeychainState() throws {
        if id == .dsh {
            hasKey = try DeepSeekKeychain.hasKey()
            checkedKeychain = true
        }
    }

    private func changeKey(save: Bool) {
        do {
            if save { try DeepSeekKeychain.save(key) } else { try DeepSeekKeychain.remove() }
            key = ""
            lastTestDate = 0
            try readKeychainState()
            statusMessage = ""
            Task { await hub.refreshConnection(id) }
        } catch { statusMessage = error.localizedDescription }
    }

    private func testConnection() {
        guard connection?.configured == true, let executable = connection?.executable,
              hub.testingProviders.insert(id).inserted else { return }
        statusMessage = ""
        Task {
            defer { hub.testingProviders.remove(id) }
            do {
                _ = try await ProviderDiscovery.testConnection(id, executable: executable)
                lastTest = "连接就绪"
            } catch let error as ProviderProbeError {
                switch error.kind {
                case .authentication: lastTest = "认证失效"
                case .quota: lastTest = "限额或冷却中"
                case .network: lastTest = "网络异常"
                case .permission: lastTest = "权限不足"
                case .protocolError: lastTest = "协议异常"
                case .incompatible: lastTest = "版本不兼容"
                case .execution: lastTest = "执行异常"
                case .cancelled: lastTest = "已取消"
                case .waiting: lastTest = "等待用户处理"
                }
                statusMessage = error.localizedDescription
            } catch {
                lastTest = "执行异常"
                statusMessage = error.localizedDescription
            }
            lastTestDate = Date().timeIntervalSince1970
        }
    }
}
