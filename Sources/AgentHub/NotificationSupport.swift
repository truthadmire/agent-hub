import AppKit
import Combine
import HubKit
import UserNotifications

@MainActor
final class HubApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private weak var hub: HubController?
    private weak var mainWindow: NSWindow?
    private var subscription: AnyCancellable?
    private var previous: [String: TaskState]?
    private var openMain: (() -> Void)?
    private var pendingDestination: (project: String, task: String)?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if canNotify { UNUserNotificationCenter.current().delegate = self }
    }

    func attach(to hub: HubController, mainWindow: NSWindow, openMain: @escaping () -> Void) {
        self.mainWindow = mainWindow
        self.openMain = openMain
        if self.hub !== hub {
            self.hub = hub
            subscription = hub.$tasks.sink { [weak self] tasks in self?.checkTransitions(tasks) }
        }
        openPendingDestination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        revealMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let hub else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        if hub.hasActiveTasks {
            let alert = NSAlert()
            alert.messageText = "退出 Agent Hub？"
            alert.informativeText = "正在执行的任务将停止。任务记录和已保存的成果会保留，可在下次打开时检查并继续。"
            alert.addButton(withTitle: "返回应用")
            alert.addButton(withTitle: "停止任务并退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        isTerminating = true
        Task {
            await hub.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private var canNotify: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private func checkTransitions(_ tasks: [HubTask]) {
        openPendingDestination(using: tasks)
        let snapshot = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.state) })
        defer { previous = snapshot }
        guard let previous, canNotify, !isTerminating,
              hub?.preferences.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }
        for task in tasks where previous[task.id] != task.state && !task.isArchived {
            guard task.state == .completed || task.state == .needsUser else { continue }
            if NSApp.isActive, NSApp.keyWindow != nil, NSApp.keyWindow === mainWindow, hub?.selectedTaskID == task.id { continue }
            let ident = "task.\(task.id).\(task.generation).\(task.requirementRevision).\(task.state.rawValue)"
            let content = UNMutableNotificationContent()
            content.title = task.state == .completed ? "任务已完成" : "任务需要你处理"
            content.subtitle = task.title
            content.body = task.state == .needsUser ? (task.attentionReason.map(HubPresentation.attentionTitle) ?? "打开工作区查看详情。") : "打开工作区查看成果和验证记录。"
            content.userInfo = ["project": task.projectID, "task": task.id]
            Task {
                let center = UNUserNotificationCenter.current()
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
                try? await center.add(UNNotificationRequest(identifier: ident, content: content, trigger: nil))
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        guard let project = info["project"] as? String, let task = info["task"] as? String else {
            completionHandler()
            return
        }
        Task { @MainActor in
            self.pendingDestination = (project, task)
            self.revealMainWindow()
            NSApp.activate(ignoringOtherApps: true)
            self.openPendingDestination()
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    private func revealMainWindow() {
        if let mainWindow, mainWindow.isVisible || mainWindow.isMiniaturized {
            if mainWindow.isMiniaturized { mainWindow.deminiaturize(nil) }
            mainWindow.makeKeyAndOrderFront(nil)
        } else { openMain?() }
    }

    private func openPendingDestination(using tasks: [HubTask]? = nil) {
        guard let hub, let destination = pendingDestination,
              (tasks ?? hub.tasks).contains(where: { $0.id == destination.task && $0.projectID == destination.project }) else { return }
        pendingDestination = nil
        hub.selectedProjectID = destination.project
        hub.selectedTaskID = destination.task
    }
}
