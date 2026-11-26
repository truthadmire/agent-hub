import AppKit
import SwiftUI

@main
@MainActor
struct AgentHubApp: App {
    @NSApplicationDelegateAdaptor(HubApplicationDelegate.self) private var delegate
    @StateObject private var hub = HubController()
    @AppStorage("appearance", store: HubController.settingsDefaults) private var appearance = "system"

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        Window("Agent Hub", id: "hub-main") {
            BoardMainScene(delegate: delegate)
                .environmentObject(hub)
                .defaultAppStorage(hub.preferences)
                .preferredColorScheme(scheme)
                .tint(HubDesign.accent)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
        .defaultSize(width: 1280, height: 805)
        .windowResizability(.contentMinSize)
        .commands { BoardCommands() }

        Settings {
            HubSettingsView()
                .environmentObject(hub)
                .defaultAppStorage(hub.preferences)
                .preferredColorScheme(scheme)
                .tint(HubDesign.accent)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
        }
    }
}

private struct BoardMainScene: View {
    let delegate: HubApplicationDelegate
    @EnvironmentObject private var hub: HubController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        BoardRoot()
            .background(BoardWindowReader { window in
                delegate.attach(to: hub, mainWindow: window) { openWindow(id: "hub-main") }
            })
    }
}

/// The notification delegate needs the actual main window to distinguish it from Settings.
private struct BoardWindowReader: NSViewRepresentable {
    let attach: (NSWindow) -> Void
    final class ReaderView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) }
        }
    }
    func makeNSView(context: Context) -> ReaderView {
        let reader = ReaderView()
        reader.attach = attach
        return reader
    }
    func updateNSView(_ nsView: ReaderView, context: Context) { nsView.attach = attach }
}

struct BoardMenuActions {
    var newTask: () -> Void
    var importProject: () -> Void
    var quickJump: () -> Void
    var canCreateTask: Bool
}

private struct BoardMenuKey: FocusedValueKey { typealias Value = BoardMenuActions }
extension FocusedValues {
    var boardMenu: BoardMenuActions? {
        get { self[BoardMenuKey.self] }
        set { self[BoardMenuKey.self] = newValue }
    }
}

private struct BoardCommands: Commands {
    @FocusedValue(\.boardMenu) private var actions
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建任务…") { actions?.newTask() }
                .keyboardShortcut("n").disabled(actions?.canCreateTask != true)
            Button("导入项目…") { actions?.importProject() }
                .keyboardShortcut("o").disabled(actions == nil)
        }
        CommandMenu("导航") {
            Button("快速跳转…") { actions?.quickJump() }
                .keyboardShortcut("k").disabled(actions == nil)
        }
        SidebarCommands()
    }
}
