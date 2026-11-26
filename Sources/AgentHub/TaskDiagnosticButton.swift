import AppKit
import HubKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskDiagnosticButton: View {
    @EnvironmentObject private var hub: HubController
    let taskID: String
    @State private var report: String?

    var body: some View {
        Button {
            do {
                guard let store = hub.store else { throw HubStoreError.invalid("本地数据库不可用。") }
                let task = try store.task(taskID)
                let events = try store.recentEvents(taskID: taskID, limit: 80)
                let data = try TaskDiagnostics.data(for: task, recentEvents: events,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                    versions: hub.connections.compactMapValues(\.version))
                report = String(decoding: data, as: UTF8.self)
            } catch { hub.showError(error) }
        } label: { Label("导出任务诊断…", systemImage: "stethoscope") }
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("任务诊断").font(.title2.bold())
                Text("包含应用和工具版本、任务状态、近期事件时间、尝试及验证退出码。请预览后选择保存或复制。")
                    .font(.callout).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    Text(report ?? "").font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(8).background(.background, in: RoundedRectangle(cornerRadius: 5))
                HStack {
                    Button("关闭") { report = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report ?? "", forType: .string)
                    }
                    Button("存储 JSON…") { save() }.buttonStyle(.borderedProminent)
                }
            }.padding(20).frame(minWidth: 440, idealWidth: 590, minHeight: 310, idealHeight: 430)
        }
    }

    private func save() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AgentHub-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(report.utf8).write(to: url, options: .atomic) }
        catch { hub.showError(error) }
    }
}
