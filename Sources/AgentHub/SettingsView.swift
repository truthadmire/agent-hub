import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case connections, team, project, general
    var id: Self { self }

    var title: String {
        switch self {
        case .connections: return "工具连接"
        case .team: return "团队与预算"
        case .project: return "项目设置"
        case .general: return "通用与版本"
        }
    }

    var icon: String {
        switch self {
        case .connections: return "cable.connector"
        case .team: return "person.3"
        case .project: return "folder"
        case .general: return "slider.horizontal.3"
        }
    }
}

struct HubSettingsView: View {
    @EnvironmentObject private var hub: HubController
    @AppStorage("settingsSection") private var section = SettingsSection.connections
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    HubMark(size: 29)
                    Text("Agent Hub").font(.headline)
                }.padding(.horizontal, 16).padding(.top, 20)
                List(selection: Binding<SettingsSection?>(
                    get: { section },
                    set: { if let newValue = $0 { section = newValue } }
                )) {
                    ForEach(SettingsSection.allCases) { item in
                        Label(item.title, systemImage: item.icon).tag(item)
                    }
                }.listStyle(.sidebar)
            }
            .frame(width: 158)
            .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(.system(size: 23, weight: .semibold))
                    .padding(.horizontal, 22).padding(.vertical, 18)
                    .accessibilityAddTraits(.isHeader)
                Divider()
                switch section {
                case .connections: SettingsConnectionsView()
                case .team: SettingsTeamView()
                case .project: SettingsProjectView()
                case .general: SettingsGeneralView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(HubDesign.surface)
        }
        .navigationTitle("Agent Hub 设置")
        .frame(minWidth: 728, idealWidth: 804, minHeight: 490, idealHeight: 604)
        .tint(HubDesign.accent)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .accessibilityIdentifier("hub-settings")
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .modifier(BoardCardSurface())
        }
    }
}
