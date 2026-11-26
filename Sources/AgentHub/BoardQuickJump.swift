import HubKit
import SwiftUI

struct BoardQuickJump: View {
    @EnvironmentObject private var hub: HubController
    @Environment(\.dismiss) private var dismiss
    let open: (String, String?) -> Void
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool

    private struct Entry: Identifiable {
        var project: String
        var task: String?
        var title: String
        var detail: String
        var id: String { task.map { "task." + $0 } ?? ("project." + project) }
    }

    private var entries: [Entry] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortedProjects = hub.projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let projects = sortedProjects.map { Entry(project: $0.id, task: nil, title: $0.name, detail: "项目") }
        let names = Dictionary(uniqueKeysWithValues: sortedProjects.map { ($0.id, $0.name) })
        let tasks = hub.tasks.sorted { $0.updatedAt > $1.updatedAt }.map {
            Entry(project: $0.projectID, task: $0.id, title: $0.title,
                  detail: (names[$0.projectID] ?? "") + " · " + HubDesign.stateTitle($0.state))
        }
        return Array((projects + tasks).lazy.filter { key.isEmpty || $0.title.localizedCaseInsensitiveContains(key) || $0.detail.localizedCaseInsensitiveContains(key) }.prefix(100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(HubDesign.accent)
                TextField("搜索项目或任务", text: $query).textFieldStyle(.plain).font(.title3)
                    .focused($focused).onSubmit(activate).accessibilityIdentifier("jump.query")
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭")
                    .accessibilityLabel("关闭快速跳转").keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(query.isEmpty ? "尚未添加项目" : "没有匹配结果", systemImage: "magnifyingglass")
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(entries) { item in
                                Button { open(item.project, item.task) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.task == nil ? "folder" : "rectangle.on.rectangle")
                                            .foregroundStyle(HubDesign.accent).frame(width: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title).fontWeight(.medium).lineLimit(1)
                                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if item.id == selection { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(item.id == selection ? HubDesign.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(item.id)
                            }
                        }.padding(8)
                    }.onChange(of: selection) { _, id in if let id { reader.scrollTo(id) } }
                }
            }
        }.frame(width: 440, height: 340)
            .onAppear { focused = true; selection = entries.first?.id }
            .onChange(of: query) { _, _ in selection = entries.first?.id }
    }

    private func activate() {
        guard let item = entries.first(where: { $0.id == selection }) ?? entries.first else { return }
        open(item.project, item.task)
    }
    private func move(_ offset: Int) {
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == selection } ?? 0
        selection = entries[min(max(current + offset, 0), entries.count - 1)].id
    }
}
