import SwiftUI
import HubKit

private struct FeedCursor: Codable, Equatable, Sendable {
    var messages: Int64?
    var events: Int64?
    static var latest: Self { .init() }
}

private enum FeedEntry: Identifiable, Equatable, Sendable {
    case message(HubMessage), event(HubEvent)
    var id: String {
        switch self {
        case .message(let m): return "m-" + m.id
        case .event(let e):
            if e.kind == "provider.text", e.id.hasPrefix("text/"), let separator = e.id.lastIndex(of: "/") {
                return "e-" + e.id[..<separator]
            }
            return "e-" + e.id
        }
    }
    var date: Date {
        switch self { case .message(let m): return m.createdAt; case .event(let e): return e.createdAt }
    }
}

private struct FeedPage: Equatable, Sendable {
    var entries: [FeedEntry] = []
    var older: FeedCursor?

    static func load(store: HubStore, task: HubTask, role: String, cursor: FeedCursor) throws -> Self {
        let count = 60
        let messages = try store.recentConversation(taskID: task.id, role: role, before: cursor.messages, limit: count + 1)
        let attempts = task.attempts.filter { $0.role == role }.map(\.id)
        let events = try store.recentRoleEvents(taskID: task.id, attemptIDs: attempts, includeTaskEvents: role == "lead",
                                                before: cursor.events, limit: count + 1)
        // Consume the end of each ordered stream. Their sequence numbers are independent;
        // preserving each stream's order also handles identical timestamps and a clock adjustment.
        var messageCount = messages.count
        var eventCount = events.count
        var newestFirst: [FeedEntry] = []
        while newestFirst.count < count, messageCount > 0 || eventCount > 0 {
            if messageCount > 0 && (eventCount == 0 || messages[messageCount - 1].createdAt >= events[eventCount - 1].createdAt) {
                messageCount -= 1
                newestFirst.append(.message(messages[messageCount]))
            } else {
                eventCount -= 1
                newestFirst.append(.event(events[eventCount]))
            }
        }
        let rawPage = newestFirst.reversed()
        var seen = Set<String>()
        let replies = messages.filter { $0.sender != "user" }
        let attemptsByID = Dictionary(task.attempts.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let displayed = rawPage.reversed().filter { entry in
            guard seen.insert(entry.id).inserted else { return false }
            if case .event(let event) = entry {
                if event.kind.hasPrefix("message.") { return false }
                if event.kind == "provider.text", let id = event.attemptID, let attempt = attemptsByID[id],
                   let session = attempt.providerSessionID, !event.detail.isEmpty,
                   replies.contains(where: { $0.sessionID == session && $0.itemID == attempt.itemID &&
                       $0.requirementRevision == attempt.requirementRevision && $0.text.hasSuffix(event.detail) }) { return false }
            }
            return true
        }.reversed()
        let entries = Array(displayed)
        guard messageCount > 0 || eventCount > 0 else { return Self(entries: entries) }
        var next = FeedCursor(messages: cursor.messages ?? (messages.last.map { $0.sequence + 1 } ?? 0),
                              events: cursor.events ?? (events.last.map { $0.sequence + 1 } ?? 0))
        for entry in rawPage {
            switch entry {
            case .message(let message): next.messages = min(next.messages ?? .max, message.sequence)
            case .event(let event): next.events = min(next.events ?? .max, event.sequence)
            }
        }
        return Self(entries: entries, older: next)
    }
}

private struct FeedBottom: PreferenceKey {
    static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct WorkspaceFeed: View {
    let task: HubTask
    let role: String
    @EnvironmentObject private var hub: HubController
    @AppStorage private var savedAnchor: String
    @AppStorage private var savedCursor: Data
    @State private var page = FeedPage()
    @State private var pending: FeedPage?
    @State private var cursor = FeedCursor.latest
    @State private var loaded = false
    @State private var atBottom = true
    @State private var position: String?
    @State private var clock = 0
    @State private var loadError: String?
    @State private var scrollRequest = 0
    @State private var requestedAnchor = ""

    init(task: HubTask, role: String) {
        self.task = task
        self.role = role
        let key = "workspace.\(task.id).\(role)."
        _savedAnchor = AppStorage(wrappedValue: "", key + "anchor")
        _savedCursor = AppStorage(wrappedValue: Data(), key + "page")
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        VStack(spacing: 0) {
                            if page.older != nil {
                                Button("查看更早记录") { navigate(to: page.older ?? .latest) }
                                    .font(.caption).buttonStyle(.link).padding(.vertical, 8)
                            }
                            if let loadError {
                                Text(loadError).font(.caption).foregroundStyle(HubDesign.amber).padding()
                            } else if !loaded {
                                ProgressView().controlSize(.small).padding()
                            } else if page.entries.isEmpty {
                                WorkspaceEmpty(icon: "bubble.left.and.text.bubble.right",
                                               title: "等待\(WorkspaceRole.title(role))的第一条活动",
                                               detail: "对话、工具操作和文件变更会显示在这里。")
                            } else {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(page.entries) { entry in
                                        FeedRow(entry: entry, role: role, currentRevision: task.requirementRevision)
                                            .id(entry.id)
                                    }
                                }.scrollTargetLayout()
                            }
                            Color.clear.frame(height: 1).id("end")
                                .background(GeometryReader { bottom in
                                    Color.clear.preference(key: FeedBottom.self, value: bottom.frame(in: .named("feed")).maxY)
                                })
                        }.frame(maxWidth: .infinity)
                    }
                    .coordinateSpace(name: "feed")
                    .scrollPosition(id: $position, anchor: .top)
                    .onPreferenceChange(FeedBottom.self) { y in
                        guard loaded, y.isFinite, y < .greatestFiniteMagnitude else { return }
                        atBottom = y <= geometry.size.height + 14
                    }
                    if pending != nil || cursor != .latest {
                        Button {
                            if cursor != .latest { navigate(to: .latest) }
                            else if let pending {
                                page = pending; self.pending = nil; savedAnchor = ""; requestedAnchor = ""; scrollRequest += 1
                            }
                        } label: {
                            Label(cursor == .latest ? "有新消息" : "返回最新记录", systemImage: "arrow.down")
                                .font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 4)
                        }
                        .buttonStyle(.plain).background(.regularMaterial, in: Capsule())
                        .overlay { Capsule().strokeBorder(HubDesign.border) }.padding(.bottom, 5)
                    }
                }
                .onChange(of: scrollRequest) { _, _ in
                    Task { @MainActor in
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if !requestedAnchor.isEmpty, page.entries.contains(where: { $0.id == requestedAnchor }) {
                            proxy.scrollTo(requestedAnchor, anchor: .top)
                        } else { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                .onChange(of: position) { _, newValue in
                    if loaded, !atBottom, let newValue { savedAnchor = newValue }
                }
                .onChange(of: atBottom) { _, value in
                    if value { savedAnchor = "" }
                }
                .onAppear {
                    requestedAnchor = savedAnchor
                    if let saved = try? JSONDecoder().decode(FeedCursor.self, from: savedCursor), saved != cursor {
                        cursor = saved
                        clock += 1
                    }
                }
                .task(id: "\(hub.revisionClock).\(clock)") {
                    await reload()
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func navigate(to next: FeedCursor) {
        cursor = next
        savedCursor = (try? JSONEncoder().encode(next)) ?? Data()
        savedAnchor = ""
        requestedAnchor = ""
        pending = nil
        loaded = false
        clock += 1
    }

    private func reload() async {
        guard let store = hub.store else { loadError = "任务数据库未连接。"; return }
        if cursor != .latest && loaded { return }
        let observedCursor = cursor
        let task = task, role = role
        do {
            let next = try await Task.detached(priority: .userInitiated) {
                try FeedPage.load(store: store, task: task, role: role, cursor: observedCursor)
            }.value
            guard !Task.isCancelled, observedCursor == cursor else { return }
            loadError = nil
            if !loaded {
                loaded = true; page = next; scrollRequest += 1
            } else if page != next {
                if atBottom {
                    savedAnchor = ""; requestedAnchor = ""; page = next; pending = nil; scrollRequest += 1
                } else {
                    pending = next
                }
            }
        } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
    }
}

private struct FeedRow: View {
    let entry: FeedEntry
    let role: String
    let currentRevision: Int
    @State private var expanded = false

    private var label: (String, String, Color) {
        switch entry {
        case .message(let message):
            if message.sender == "user" { return ("arrow.up.right", "你 → " + WorkspaceRole.title(message.recipient), HubDesign.ink) }
            return (WorkspaceRole.icon(role), WorkspaceRole.title(message.sender), HubDesign.accent)
        case .event(let event):
            let kind = event.kind.components(separatedBy: ".").last ?? event.kind
            switch kind {
            case "tool": return ("terminal", "工具操作", HubDesign.muted)
            case "file": return ("doc.text", "文件变更", HubDesign.accent)
            case "text": return (WorkspaceRole.icon(role), WorkspaceRole.title(role), HubDesign.accent)
            case "failure", "failed": return ("exclamationmark.circle", "运行问题", HubDesign.amber)
            case "permission": return ("hand.raised", "权限请求", HubDesign.amber)
            case "diagnostic", "usage", "session": return ("text.alignleft", "运行详情", HubDesign.muted)
            default: return ("circle.dotted", eventTitle(event.kind), HubDesign.muted)
            }
        }
    }

    private func eventTitle(_ kind: String) -> String {
        switch kind {
        case "task.created": return "任务已创建"
        case "task.started": return "任务已开始"
        case "task.resumed": return "任务已继续"
        case "task.pausing": return "任务正在暂停"
        case "task.paused": return "任务已暂停"
        case "task.cancelled": return "任务已取消"
        case "task.completed": return "任务已完成"
        case "task.needs_user": return "需要你处理"
        case "plan.created": return "分工计划已生成"
        case "attempt.started": return "角色已开始执行"
        case "attempt.finished": return "角色执行已结束"
        case "integration.started": return "开始整合交付"
        case "requirements.revised": return "需求已更新"
        case "verification.started", "verification.prepared": return "准备验证"
        case "verification.result": return "验证结果"
        case "provider.completed": return "本轮 CLI 已结束"
        case "result.adopted": return "已采用成果"
        default: return "任务活动"
        }
    }

    var body: some View {
        let info = label
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Label(info.1, systemImage: info.0).foregroundStyle(info.2).font(.caption.weight(.semibold))
                if case .message(let message) = entry, message.sender == "user" {
                    Text(message.requirementRevision != currentRevision && message.delivery == .queued ? "旧版未送达" : WorkspaceRole.delivery(message.delivery)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 3)
                Text(entry.date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                    .help(entry.date.formatted(date: .abbreviated, time: .standard))
            }
            switch entry {
            case .message(let message):
                bodyText(message.text, diagnostic: false)
                revision(message.requirementRevision)
            case .event(let event):
                let diagnostic = ["diagnostic", "usage", "session"].contains(event.kind.components(separatedBy: ".").last ?? "")
                bodyText(event.detail, diagnostic: diagnostic)
                revision(event.requirementRevision)
            }
        }.padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 12).opacity(0.45) }
    }

    @ViewBuilder private func bodyText(_ body: String, diagnostic: Bool) -> some View {
        if diagnostic || body.count > 900 {
            DisclosureGroup(isExpanded: $expanded) {
                Text(body).font(diagnostic ? .system(.caption, design: .monospaced) : .callout)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(diagnostic ? "查看详细记录" : String(body.prefix(160))).font(.callout).lineLimit(3)
            }
        } else { Text(body).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }

    @ViewBuilder private func revision(_ number: Int) -> some View {
        if number != currentRevision { Text("历史需求 · 第 \(number) 版").font(.caption2).foregroundStyle(.secondary) }
    }
}
