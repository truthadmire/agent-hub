import AppKit
import ApplicationServices

/// Native open panels are hosted by an AppKit service. Drive only the panel of
/// the verified application; never enumerate the file list or use the clipboard.
struct NativeImport {
    let application: NSRunningApplication
    let repository: URL

    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    func string(_ element: AXUIElement, _ key: String) -> String {
        attribute(element, key) as? String ?? ""
    }

    private func find(_ id: String, in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if string(element, kAXIdentifierAttribute) == id { return element }
        let omitted = [kAXTableRole, kAXOutlineRole, kAXBrowserRole, kAXListRole]
        guard depth < 18, !omitted.contains(string(element, kAXRoleAttribute)) else { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = find(id, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    func wait(_ id: String) async throws -> AXUIElement {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        let end = Date().addingTimeInterval(12)
        repeat {
            for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                if let found = find(id, in: window) { return found }
            }
            try await Task.sleep(nanoseconds: 80_000_000)
        } while Date() < end
        throw CaptureError(description: "Missing native control " + id)
    }

    private func pressKey(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw CaptureError(description: "The target application lost focus.")
        }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    func configureWindow(_ action: String) async throws {
        let root = AXUIElementCreateApplication(application.processIdentifier)
        guard let main = (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { string($0, kAXIdentifierAttribute) == "hub-main" }) else {
            throw CaptureError(description: "No main Agent Hub window.")
        }
        if action == "wide" || action == "narrow" {
            var size = action == "wide" ? CGSize(width: 1280, height: 805) : CGSize(width: 760, height: 650)
            guard AXUIElementSetAttributeValue(main,kAXSizeAttribute as CFString,AXValueCreate(.cgSize,&size)!) == .success else {
                throw CaptureError(description: "The operating system rejected the test window size.")
            }
            return
        }
        let title = action == "collaboration" ? "协作" : "成果与验证"
        func locate(_ item: AXUIElement, _ depth: Int) -> AXUIElement? {
            if string(item, kAXRoleAttribute) == kAXButtonRole &&
               [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { string(item, $0) == title }) { return item }
            guard depth < 22 else { return nil }
            for child in attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let hit = locate(child, depth + 1) { return hit }
            }
            return nil
        }
        guard let tab = locate(main, 0), AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success else {
            throw CaptureError(description: "The requested workspace tab did not accept a press.")
        }
    }

    func perform() async throws {
        guard application.activate(options: []) else { throw CaptureError(description: "Could not activate Agent Hub.") }
        let button = try await wait("board.import")
        let pressed = AXUIElementPerformAction(button, kAXPressAction as CFString)
        guard pressed == .success || pressed == .cannotComplete else {
            throw CaptureError(description: "The import action returned AX error " + String(pressed.rawValue))
        }
        print("Import control action returned AX", pressed.rawValue)
        _ = try await wait("open-panel")
        try pressKey(5, flags: [.maskCommand, .maskShift])
        let input = try await wait("PathTextField")
        let path = repository.path + "/"
        guard AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, path as CFString) == .success,
              string(input, kAXValueAttribute) == path else { throw CaptureError(description: "Directory input mismatch.") }
        try await Task.sleep(nanoseconds: 800_000_000)
        try pressKey(36)
        let end = Date().addingTimeInterval(8)
        var matched = false
        repeat {
            if string(try await wait("where popup"), kAXValueAttribute) == repository.lastPathComponent {
                matched = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < end
        guard matched else { throw CaptureError(description: "Open panel did not select the requested test folder.") }
        let confirm = try await wait("OKButton")
        guard AXUIElementPerformAction(confirm, kAXPressAction as CFString) == .success else {
            throw CaptureError(description: "Could not confirm import.")
        }
        _ = try await wait("board.newTask")
    }
}
