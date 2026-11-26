import HubProviders
import SwiftUI

struct BoardWelcome: View {
    @EnvironmentObject private var hub: HubController
    let importing: Bool
    let importProject: () -> Void
    let newProject: () -> Void
    let connections: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 620
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("项目工作台").font(.system(size: 29, weight: .bold)).foregroundStyle(HubDesign.ink)
                        Text("在本机管理开发任务、协作工具和验证结果。").foregroundStyle(HubDesign.muted)
                    }
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 15).fill(LinearGradient(
                            colors: [HubDesign.hero, HubDesign.heroEnd], startPoint: .leading, endPoint: .trailing))
                        if !compact {
                            BoardBranchDrawing()
                                .frame(width: min(geometry.size.width * 0.27, 285))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityHidden(true).allowsHitTesting(false)
                        }
                        VStack(alignment: .leading, spacing: 13) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 23, weight: .medium))
                            Text("从一个本地项目开始").font(.system(size: compact ? 22 : 27, weight: .bold))
                            Text("导入已有仓库，或从空目录创建新的 Git 项目。")
                                .font(.body).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 14) {
                                Button(action: importProject) { Label("导入项目", systemImage: "folder") }
                                    .buttonStyle(BoardPrimaryStyle()).accessibilityIdentifier("board.import")
                                Button(action: newProject) { Text("新建项目…").fontWeight(.medium) }
                                    .buttonStyle(.link).foregroundStyle(HubDesign.heroInk)
                                    .accessibilityIdentifier("board.newProject")
                                if importing { ProgressView().controlSize(.small) }
                            }.disabled(importing).padding(.top, 6)
                        }.foregroundStyle(HubDesign.heroInk).padding(compact ? 20 : 28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(HubDesign.accent.opacity(0.14)) }
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("编码工具").font(.title3.bold()).foregroundStyle(HubDesign.ink)
                            Spacer()
                            Button(action: connections) {
                                HStack(spacing: 4) { Text("管理连接"); Image(systemName: "arrow.up.right").font(.caption2.bold()) }
                            }.buttonStyle(.link).foregroundStyle(HubDesign.accent)
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(ProviderID.allCases.enumerated()), id: \.element) { index, provider in
                                connectionRow(provider)
                                if index < ProviderID.allCases.count - 1 { Divider().padding(.leading, 58) }
                            }
                        }.modifier(BoardCardSurface())
                    }
                }
                .padding(compact ? 20 : 34)
                .frame(maxWidth: 1080, alignment: .leading)
                .frame(maxWidth: .infinity)
            }.background(HubDesign.surface)
        }
    }

    private func connectionRow(_ provider: ProviderID) -> some View {
        let connection = hub.connections[provider]
        let checking = hub.detectingProviders.contains(provider)
        let description: String
        if checking { description = "正在检测" }
        else if let connection {
            if connection.configured { description = "已配置" }
            else if connection.executable == nil { description = "未安装" }
            else if !connection.compatible { description = "版本不兼容" }
            else { description = "需要配置" }
        } else { description = "待检测" }
        return Button(action: connections) {
            HStack(spacing: 13) {
                Image(systemName: provider == .codex ? "terminal" : provider == .antigravity ? "sparkles" : "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(HubDesign.accent)
                    .frame(width: 33, height: 33).background(HubDesign.lane, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.displayName).font(.body.weight(.semibold))
                    Text(provider == .dsh ? "DeepSeek API 密钥" : "本机 CLI 账号")
                        .font(.caption).foregroundStyle(HubDesign.muted)
                }
                Spacer()
                Label(description, systemImage: connection?.configured == true ? "checkmark.circle.fill" : "circle")
                    .font(.caption.weight(.medium)).foregroundStyle(connection?.configured == true ? HubDesign.accent : HubDesign.muted)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 14).padding(.vertical, 11).contentShape(Rectangle())
        }.buttonStyle(.plain).help("打开 \(provider.displayName) 连接设置")
    }
}

private struct BoardBranchDrawing: View {
    var body: some View {
        Canvas { canvas, size in
            let w = size.width, h = size.height
            let top = h * 0.2, middle = h * 0.5, low = h * 0.8
            let color = HubDesign.accent
            for row in stride(from: CGFloat(9), to: h - 5, by: 14) {
                for column in stride(from: CGFloat(3), to: w - 5, by: 14) {
                    let opacity = Double(column / w) * 0.20
                    canvas.fill(Path(ellipseIn: CGRect(x: column, y: row, width: 1.4, height: 1.4)), with: .color(color.opacity(opacity)))
                }
            }
            let start = CGPoint(x: w * 0.10, y: middle), end = CGPoint(x: w * 0.9, y: middle)
            for (index, y) in [top, middle, low].enumerated() {
                let center = CGPoint(x: w * 0.55, y: y)
                var path = Path()
                path.move(to: start)
                path.addCurve(to: center, control1: CGPoint(x: w * 0.40, y: middle), control2: CGPoint(x: w * 0.24, y: y))
                path.addCurve(to: end, control1: CGPoint(x: w * 0.74, y: y), control2: CGPoint(x: w * 0.75, y: middle))
                canvas.stroke(path, with: .color(color.opacity(index == 1 ? 0.64 : 0.38)), lineWidth: 1.6)
                let node = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
                canvas.fill(Path(roundedRect: node, cornerRadius: 3), with: .color(index == 0 ? HubDesign.amber : color))
            }
            for p in [start, end] {
                let rect = CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)
                canvas.fill(Path(ellipseIn: rect), with: .color(HubDesign.heroEnd))
                canvas.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.6)
                canvas.fill(Path(ellipseIn: rect.insetBy(dx: 4.5, dy: 4.5)), with: .color(color))
            }
        }
    }
}
