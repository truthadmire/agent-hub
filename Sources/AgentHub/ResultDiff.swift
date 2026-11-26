import SwiftUI
import HubGit

struct ResultDiff: View {
    let snapshot: ResultSnapshot
    let service: GitWorkspaceService
    @Environment(\.dismiss) private var dismiss
    @State private var patch: Data?
    @State private var pageRanges: [Range<Int>] = []
    @State private var page = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("统一差异").font(.title2.weight(.semibold))
                    Text("\(snapshot.workspace.branch) · \(snapshot.workspace.baseline.prefix(10)) → \(snapshot.head.prefix(10))")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error {
                Text(error).foregroundStyle(HubDesign.amber).textSelection(.enabled)
                Spacer()
            } else if let patch, patch.isEmpty {
                WorkspaceEmpty(icon: "doc.on.doc", title: "此提交相对基线没有差异")
                Spacer()
            } else if let patch, pageRanges.indices.contains(page) {
                let text = String(decoding: patch[pageRanges[page]], as: UTF8.self)
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: text).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).padding(10)
                }.id(page).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .modifier(BoardCardSurface())
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(patch.count), countStyle: .file)).foregroundStyle(.secondary)
                    Spacer()
                    if pageRanges.count > 1 {
                        Button("上一页") { page -= 1 }.disabled(page == 0)
                        Text("\(page + 1) / \(pageRanges.count)").monospacedDigit()
                        Button("下一页") { page += 1 }.disabled(page + 1 == pageRanges.count)
                    }
                    Button("复制本页") { ResultFileAction.copy(text) }
                }.controlSize(.small)
            } else {
                ProgressView("读取 Git 差异…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(18).frame(minWidth: 480, idealWidth: 740, minHeight: 320, idealHeight: 540)
        .task {
            do {
                let (data, ranges) = try await Task.detached(priority: .userInitiated) {
                    let bytes = try service.diff(of: snapshot.workspace, expectedHead: snapshot.head)
                    return (bytes, Self.ranges(in: bytes))
                }.value
                if !Task.isCancelled { patch = data; pageRanges = ranges }
            } catch { self.error = error.localizedDescription }
        }
    }

    // One Text view per page bounds layout time for large changes and binary patches.
    private nonisolated static func ranges(in data: Data) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = data.startIndex
        while start < data.endIndex {
            var end = min(start + 32_768, data.endIndex)
            if end != data.endIndex {
                if let newline = data[end..<min(end + 2_048, data.endIndex)].firstIndex(of: 10) {
                    end = newline + 1
                } else {
                    while end < data.endIndex, data[end] & 0xC0 == 0x80 { end += 1 }
                }
            }
            result.append(start..<end)
            start = end
        }
        return result
    }
}
