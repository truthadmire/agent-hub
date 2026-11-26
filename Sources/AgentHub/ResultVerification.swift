import SwiftUI
import HubKit

struct ResultVerification: View {
    let task: HubTask
    let commit: String?
    @EnvironmentObject private var hub: HubController
    @State private var confirmRerun = false
    @State private var rerunning = false
    @State private var selected: HubVerification?
    @State private var waive = false
    @State private var history = false

    private var current: [HubVerification] {
        guard let commit else { return [] }
        var names = Set<String>()
        return task.verifications.reversed().filter {
            !$0.name.hasPrefix("Baseline ·") && $0.requirementRevision == task.requirementRevision && $0.snapshot == commit &&
            ($0.snapshotAfter == nil || $0.snapshotAfter == commit) && names.insert($0.name).inserted
        }.reversed()
    }

    private var older: [HubVerification] {
        let ids = Set(current.map(\.id))
        return task.verifications.filter { !ids.contains($0.id) }
    }

    var body: some View {
        WorkspaceSection(title: "验证与验收", icon: "checkmark.shield") {
            if !task.isArchived, task.workspace != nil,
               [.completed, .needsUser, .paused].contains(task.state),
               let items = task.plan?.items, !items.isEmpty, items.allSatisfy({ $0.state == .integrated }) {
                Button("重新验证…") { confirmRerun = true }.controlSize(.small).disabled(rerunning)
            }
            if let commit {
                Text("需求 \(task.requirementRevision) · 源码快照 \(commit.prefix(12))")
                    .font(.caption).foregroundStyle(.secondary).help(commit)
            }
            if current.isEmpty {
                Text(commit == nil && !task.verifications.isEmpty ? "尚未核对当前源码快照。既有记录可在历史中查看。" : "当前需求与源码快照还没有有效的验证记录。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(current) { check in
                ResultCheckRow(check: check)
                if task.state == .needsUser || task.state == .paused {
                    if ![.passed, .waived, .notApplicable].contains(check.state) {
                        HStack {
                            if check.actor == "manual" {
                                Button("记录人工验收…") { waive = false; selected = check }
                            }
                            if check.required { Button("豁免此项…") { waive = true; selected = check } }
                        }.controlSize(.small)
                    }
                }
            }
            let remaining = current.filter { $0.required && ![.passed, .notApplicable, .waived].contains($0.state) }
            if !remaining.isEmpty {
                Label("还有 \(remaining.count) 项必需验收待完成", systemImage: "exclamationmark.circle")
                    .font(.callout.weight(.medium)).foregroundStyle(HubDesign.amber)
            }
            if current.contains(where: { $0.state == .waived }) {
                Label("当前成果包含用户豁免项", systemImage: "person.crop.circle.badge.checkmark").font(.caption)
            }
            if !older.isEmpty {
                DisclosureGroup("历史验证（\(older.count)）", isExpanded: $history) {
                    LazyVStack(alignment: .leading, spacing: 9) {
                        ForEach(older.reversed()) { ResultCheckRow(check: $0) }
                    }.padding(.top, 6)
                }
            }
        }
        .alert("重新验证受管工作区？", isPresented: $confirmRerun) {
            Button("返回", role: .cancel) {}
            Button("保存工作区并重新验证") {
                guard let engine = hub.engine else { return }
                rerunning = true
                Task { @MainActor in
                    defer { rerunning = false }
                    do { try await engine.reverify(task.id); hub.refresh() }
                    catch { hub.showError(error) }
                }
            }
        } message: {
            Text("当前受管分支中的未提交更改会保存为任务提交。应用将重新运行适用的项目检查，源码版本变化时需重新确认人工验收。")
        }
        .sheet(item: $selected) { check in ResultHumanCheck(taskID: task.id, check: check, waive: waive) }
    }
}

private struct ResultCheckRow: View {
    let check: HubVerification
    private var status: (String, String, Color) {
        switch check.state {
        case .passed: return ("通过", "checkmark.circle.fill", HubDesign.accent)
        case .failed: return ("失败", "xmark.circle", .red)
        case .notRun: return ("未运行", "circle.dashed", HubDesign.muted)
        case .blocked: return ("受阻", "exclamationmark.circle", HubDesign.amber)
        case .notApplicable: return ("不适用", "minus.circle", HubDesign.muted)
        case .waived: return ("已豁免", "person.crop.circle.badge.checkmark", HubDesign.amber)
        }
    }

    var body: some View {
        let info = status
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                Text("需求 \(check.requirementRevision) · \(check.required ? "必需" : "可选")")
                detail("源码快照", check.snapshot)
                if let after = check.snapshotAfter, after != check.snapshot { detail("结束快照", after) }
                if !check.command.isEmpty { detail("命令", ResultFileAction.formattedCommand(check.command)) }
                detail("工作目录", check.directory)
                detail("环境", check.environment)
                detail("开始", check.startedAt.formatted(date: .numeric, time: .standard))
                detail("结束", check.endedAt?.formatted(date: .numeric, time: .standard))
                detail("退出码", check.exitCode.map(String.init))
                detail("记录人", check.actor)
                detail("说明", check.reason)
                if let evidence = check.evidence, !evidence.isEmpty {
                    DisclosureGroup("执行证据") {
                        Text(evidence).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
        } label: {
            HStack {
                Text(HubPresentation.verificationTitle(check.name)).font(.callout.weight(.medium)).textSelection(.enabled)
                Spacer()
                Label(info.0, systemImage: info.1).foregroundStyle(info.2).font(.caption)
            }
        }
    }

    @ViewBuilder private func detail(_ name: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { Text(name + "  " + value).textSelection(.enabled) }
    }
}

private struct ResultHumanCheck: View {
    let taskID: String
    let check: HubVerification
    let waive: Bool
    @EnvironmentObject private var hub: HubController
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(waive ? "豁免此项验收" : "记录人工验收").font(.title2.weight(.semibold))
            Text(HubPresentation.verificationTitle(check.name)).font(.headline)
            Text("需求 \(check.requirementRevision) · 源码快照 \(check.snapshot.prefix(12))").font(.caption).foregroundStyle(.secondary)
            Text(waive ? "填写豁免原因。成果和历史会记录本次决定。" : "说明你实际操作的步骤、观察到的结果及证据。")
                .font(.callout)
            TextEditor(text: $reason).frame(minHeight: 85).accessibilityLabel(waive ? "豁免原因" : "人工验收证据")
            if let error { Text(error).foregroundStyle(HubDesign.amber) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(waive ? "确认豁免" : "确认通过") { record() }
                    .keyboardShortcut(.defaultAction).disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
            }
        }.padding(20).frame(width: 445)
    }

    private func record() {
        guard let engine = hub.engine, !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                try await engine.recordHumanCheck(taskID, verificationID: check.id, waive: waive, reason: reason)
                hub.refresh()
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
