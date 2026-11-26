import AppKit
import Foundation
import HubProviders
import SwiftUI

private struct PublishedVersion: Decodable {
    let tag_name: String
}

private enum SettingsRelease {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
    }

    static var repository: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "AgentHubRepositoryURL") as? String,
              let components = URLComponents(string: raw),
              components.scheme == "https", components.host?.lowercased() == "github.com",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path.split(separator: "/").count == 2 else { return nil }
        return components.url
    }

    static func latest(from repository: URL) async throws -> String {
        let endpoint = URL(string: "https://api.github.com/repos")!
            .appendingPathComponent(repository.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
            .appendingPathComponent("releases/latest")
        var request = URLRequest(url: endpoint, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        if status == 404 { return "未找到可公开访问的正式版本。" }
        guard status == 200 else { return "GitHub 返回 HTTP \(status)。请稍后重试。" }
        let tag = try JSONDecoder().decode(PublishedVersion.self, from: data).tag_name
        let latest = tag.first == "v" ? String(tag.dropFirst()) : tag
        let isNumericVersion = { (value: String) in
            !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        }
        guard isNumericVersion(latest), isNumericVersion(version) else { return "最新正式版本为 \(tag)。" }
        switch latest.compare(version, options: .numeric) {
        case .orderedDescending: return "发现新版本 \(tag)，可前往发布页下载。"
        case .orderedSame: return "当前版本已是最新。最新发布为 \(tag)。"
        case .orderedAscending: return "本地版本高于最新正式版 \(tag)。"
        }
    }
}

struct SettingsGeneralView: View {
    @EnvironmentObject private var hub: HubController
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @State private var checking = false
    @State private var versionResult = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(title: "外观与提醒") {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }.pickerStyle(.segmented)
                    Divider()
                    Toggle("任务完成或需要我处理时通知", isOn: $notificationsEnabled)
                }
                SettingsGroup(title: "版本与来源") {
                    HStack(spacing: 12) {
                        HubMark(size: 43)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Agent Hub").font(.headline)
                            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                            Text(build.map { "\(SettingsRelease.version) (\($0))" } ?? SettingsRelease.version)
                                .foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    if let repository = SettingsRelease.repository {
                        Divider()
                        Link(destination: repository) { Label(repository.path, systemImage: "chevron.left.forwardslash.chevron.right") }
                        HStack {
                            Button("检查更新") {
                                guard !checking else { return }
                                checking = true
                                Task {
                                    defer { checking = false }
                                    do { versionResult = try await SettingsRelease.latest(from: repository) }
                                    catch { versionResult = "查询失败：\(error.localizedDescription)" }
                                }
                            }.disabled(checking)
                            Link("打开发布页", destination: repository.appendingPathComponent("releases"))
                            if checking { ProgressView().controlSize(.small) }
                        }
                        if !versionResult.isEmpty { Text(versionResult).font(.callout).textSelection(.enabled) }
                    } else {
                        Text("此构建尚未配置官方发布仓库。").font(.callout).foregroundStyle(.secondary)
                    }
                }
                SettingsGroup(title: "诊断") {
                    Text("复制应用版本、系统版本、架构和已检测的 CLI 版本。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        #if arch(arm64)
                        let architecture = "arm64"
                        #elseif arch(x86_64)
                        let architecture = "x86_64"
                        #else
                        let architecture = "unknown"
                        #endif
                        var lines = ["Agent Hub \(SettingsRelease.version)",
                                     "\(ProcessInfo.processInfo.operatingSystemVersionString) (\(architecture))"]
                        for id in ProviderID.allCases {
                            let version = hub.connections[id]?.version ?? "未检出"
                            lines.append("\(id.displayName)  \(version)")
                        }
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    } label: {
                        Label(copied ? "已复制诊断信息" : "复制诊断信息", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
