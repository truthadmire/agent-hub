import AppKit
import HubKit
import SwiftUI

enum HubDesign {
    static let accent = adaptive(0x087C74, 0x67D3C2)
    static let amber = adaptive(0x985911, 0xF1BA71)
    static let muted = adaptive(0x5F6A69, 0xA8B2B0)
    static let surface = adaptive(0xF8F9F7, 0x1C211F)
    static let panel = adaptive(0xFFFFFF, 0x272D2A)
    static let border = adaptive(0xDCE1DC, 0x3F4843)
    static let ink = adaptive(0x182C29, 0xE2EBE7)
    static let lane = adaptive(0xEEF1ED, 0x222824)
    static let hero = adaptive(0xDCEEE5, 0x233E34)
    static let heroEnd = adaptive(0xEBF3E9, 0x29382D)
    static let heroInk = adaptive(0x164B40, 0xC8E8DA)

    private static func adaptive(_ light: Int, _ dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255,
                           alpha: 1)
        })
    }

    static func stateColor(_ state: TaskState) -> Color {
        switch state {
        case .running, .completed: return accent
        case .pausing, .paused, .needsUser: return amber
        case .queued, .cancelled: return muted
        }
    }

    static func stateTitle(_ state: TaskState) -> String {
        switch state {
        case .queued: return "待开始"
        case .running: return "进行中"
        case .pausing: return "正在暂停"
        case .paused: return "已暂停"
        case .needsUser: return "需要你"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        }
    }

    static func stateIcon(_ state: TaskState) -> String {
        switch state {
        case .queued: return "circle.dashed"
        case .running: return "play.circle.fill"
        case .pausing, .paused: return "pause.circle.fill"
        case .needsUser: return "exclamationmark.bubble.fill"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    static func phaseTitle(_ phase: TaskPhase) -> String {
        switch phase {
        case .planning: return "规划"
        case .implementing: return "开发"
        case .integrating: return "整合"
        case .verifying: return "验证"
        case .repairing: return "修复"
        }
    }
}

struct HubMark: View {
    var size: CGFloat = 34
    private static let bundleIcon = Bundle.main.url(forResource: "AgentHub", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        Group {
            if let icon = Self.bundleIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Canvas { context, box in
                    let u = box.width / 32
                    let tile = CGRect(origin: .zero, size: box)
                    let shape = Path(roundedRect: tile, cornerRadius: 7 * u)
                    context.fill(shape, with: .linearGradient(Gradient(colors: [
                        Color(red: 0.16, green: 0.39, blue: 0.40), Color(red: 0.08, green: 0.19, blue: 0.23)
                    ]), startPoint: .zero, endPoint: CGPoint(x: 32*u, y: 32*u)))
                    var lanes = Path()
                    for y: CGFloat in [9, 23] {
                        lanes.move(to: CGPoint(x: 7*u, y: y*u))
                        lanes.addLine(to: CGPoint(x: 10.5*u, y: y*u))
                        lanes.addLine(to: CGPoint(x: 17*u, y: 16*u))
                    }
                    lanes.move(to: CGPoint(x: 7*u, y: 16*u))
                    lanes.addLine(to: CGPoint(x: 25*u, y: 16*u))
                    context.stroke(lanes, with: .color(.white.opacity(0.93)),
                                   style: StrokeStyle(lineWidth: 1.8*u, lineCap: .round, lineJoin: .round))
                    let junction = Path(ellipseIn: CGRect(x: 14.5*u, y: 13.5*u, width: 5*u, height: 5*u))
                    context.fill(junction, with: .color(Color(red: 0.15, green: 0.30, blue: 0.32)))
                    context.stroke(junction, with: .color(Color(red: 0.92, green: 0.74, blue: 0.41)), lineWidth: 1.3*u)
                }
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct HubStateBadge: View {
    let state: TaskState
    var body: some View {
        Label(HubDesign.stateTitle(state), systemImage: HubDesign.stateIcon(state))
            .font(.caption.weight(.medium))
            .foregroundStyle(HubDesign.stateColor(state))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(HubDesign.stateColor(state).opacity(0.10), in: Capsule())
    }
}

struct BoardPrimaryStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.fontWeight(.semibold)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(Color.white)
            .background(Color(red: 0.035, green: 0.39, blue: 0.345).opacity(configuration.isPressed ? 0.78 : 1),
                        in: RoundedRectangle(cornerRadius: 7))
    }
}

struct BoardCardSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(HubDesign.panel, in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(HubDesign.border, lineWidth: 1).allowsHitTesting(false) }
    }
}
