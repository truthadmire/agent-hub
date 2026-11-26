import AppKit
import CoreGraphics
import ScreenCaptureKit

// This process belongs to the terminal invoking the UI suite. XCTest may not have
// screen capture access even when the developer's terminal does.
struct Request: Decodable { let title: String; let name: String }
struct CaptureError: Error, CustomStringConvertible { let description: String }

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else { exit(2) }
let appURL = URL(fileURLWithPath: arguments[0]).resolvingSymlinksInPath()
let inbox = URL(fileURLWithPath: arguments[1])
let evidence = URL(fileURLWithPath: arguments[2])
let files = FileManager.default

func capture(_ request: Request) async throws {
    guard !request.title.isEmpty, request.name.range(of: #"^[0-9a-z-]+$"#, options: .regularExpression) != nil else {
        throw CaptureError(description: "Invalid window screenshot request.")
    }
    let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "org.agenthub.desktop").filter {
        $0.bundleURL?.resolvingSymlinksInPath() == appURL
    }
    guard instances.count == 1, let app = instances.first else { throw CaptureError(description: "Expected one matching test instance.") }
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let matches = info.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier &&
        ($0[kCGWindowLayer as String] as? Int) == 0 &&
        ($0[kCGWindowName as String] as? String) == request.title
    }
    guard matches.count == 1, let id = matches[0][kCGWindowNumber as String] as? UInt32 else {
        throw CaptureError(description: "Could not identify one application window with the requested title.")
    }
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let selected = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == app.processIdentifier }) else {
        throw CaptureError(description: "The requested application window closed before capture.")
    }
    let filter = SCContentFilter(desktopIndependentWindow: selected)
    let configuration = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    configuration.width = Int((filter.contentRect.width * scale).rounded())
    configuration.height = Int((filter.contentRect.height * scale).rounded())
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw CaptureError(description: "macOS could not encode the application window.")
    }
    try png.write(to: evidence.appendingPathComponent(request.name + ".png"), options: .atomic)

}
while true {
    do {
        let requests = (try? files.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []
        for item in requests where item.pathExtension == "request" {
            let status: String
            do {
                try await capture(JSONDecoder().decode(Request.self, from: Data(contentsOf: item)))
                status = "ok"
            } catch { status = String(describing: error) }
            try? status.write(to: item.deletingPathExtension().appendingPathExtension("status"), atomically: true, encoding: .utf8)
            try? files.removeItem(at: item)
        }
    }
    try await Task.sleep(nanoseconds: 80_000_000)
}
