import HubKit
import HubProviders
import SwiftUI

struct SettingsRole: Identifiable {
    let id: String
    let name: String
    let responsibility: String
    static let all = [
        Self(id: "lead", name: "负责人", responsibility: "规划与分工"),
        Self(id: "frontend", name: "前端", responsibility: "界面与交互"),
        Self(id: "backend", name: "后端", responsibility: "数据与业务逻辑"),
        Self(id: "test", name: "测试", responsibility: "验证与局部修复"),
        Self(id: "review", name: "审查", responsibility: "差异与验收")
    ]
}

private struct SavedTeam: Identifiable, Codable {
    var id: UUID = UUID()
    let name: String
    let roles: [String: ProviderID]
    let models: [String: String]
    let enabled: [String]?
}

struct SettingsTeamView: View {
    @EnvironmentObject private var hub: HubController
    @State private var config = HubConfiguration.balanced
    @State private var lastSaved = HubConfiguration.balanced
    @State private var loaded = false
    @State private var errorMessage = ""
    @State private var templateName = ""
    @State private var namingTemplate = false
    @AppStorage("savedTeamTemplates") private var templatesData = Data()

    private var teams: [SavedTeam] {
        (try? JSONDecoder().decode([SavedTeam].self, from: templatesData)) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !errorMessage.isEmpty { Text(errorMessage).foregroundStyle(HubDesign.amber) }
                SettingsGroup(title: "默认角色分工") {
                    HStack {
                        Menu("应用模板") {
                            Button("均衡全栈开发") {
                                let balanced = HubConfiguration.balanced
                                selectTeam(roles: balanced.roles, models: balanced.models, enabled: balanced.enabledRoles)
                            }
                            ForEach(teams) { team in
                                Button(team.name) {
                                    selectTeam(roles: team.roles, models: team.models, enabled: team.enabled)
                                }
                            }
                        }.fixedSize()
                        Button("保存为模板…") { templateName = ""; namingTemplate = true }
                    }
                    Divider()
                    ForEach(SettingsRole.all) { role in roleRow(role) }
                }
                SettingsGroup(title: "任务预算") {
                    limit("执行尝试总数", \.maxAttempts, default: 12, range: 1...1000, unit: "次")
                    limit("总运行时长", \.maxSeconds, default: 3600, range: 60...604800, step: 60, unit: "秒")
                    limit("失败后重试", \.maxRetries, default: 2, range: 0...20, unit: "次")
                    limit("自动修复", \.maxRepairs, default: 2, range: 0...20, unit: "次")
                    Text("一次执行尝试可以包含多个 CLI 内部模型请求。").font(.caption).foregroundStyle(.secondary)
                }
                SettingsGroup(title: "同时运行的执行") {
                    limit("所有工具合计", \.maxConcurrent, default: 2, range: 1...32, unit: "个")
                    ForEach(ProviderID.allCases) { id in
                        Stepper(value: Binding(get: { config.providerConcurrency[id.rawValue] ?? 1 },
                            set: { config.providerConcurrency[id.rawValue] = $0 }), in: 1...32) {
                            HStack {
                                Text(id.displayName)
                                Spacer()
                                Text("\(config.providerConcurrency[id.rawValue] ?? 1) 个").monospacedDigit()
                            }
                        }
                    }
                }
                SettingsGroup(title: "付费来源与自动切换") {
                    Toggle("允许任务使用我的 DeepSeek API key 计费", isOn: Binding(
                        get: { (config.paidProviders ?? []).contains(.dsh) },
                        set: { allowed in
                            var sources = (config.paidProviders ?? []).filter { $0 != .dsh }
                            if allowed { sources.append(.dsh) }
                            else { config.allowedFallbacks?.removeAll { $0 == .dsh } }
                            config.paidProviders = sources
                        }))
                    Divider()
                    Text("原工具不可用时允许接手的工具").font(.callout.weight(.semibold))
                    ForEach(ProviderID.allCases) { id in
                        Toggle(id == .dsh ? "DeepSeek Harness（API 付费）" : id.displayName, isOn: Binding(
                            get: { (config.allowedFallbacks ?? []).contains(id) },
                            set: { allowed in
                                var providers = (config.allowedFallbacks ?? []).filter { $0 != id }
                                if allowed { providers.append(id) }
                                config.allowedFallbacks = providers
                            }))
                        .disabled(id == .dsh && !(config.paidProviders ?? []).contains(.dsh))
                    }
                    if (config.allowedFallbacks ?? []).contains(.dsh) && config.maxCostUSD == nil {
                        Label("要自动切换到 DSH，还需设置下方费用阈值。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(HubDesign.amber)
                    }
                    Divider()
                    Toggle("达到费用阈值后停止新增付费尝试", isOn: Binding(
                        get: { config.maxCostUSD != nil },
                        set: { value in
                            config.maxCostUSD = value ? 1 : nil
                            config.reservedCostUSD = value ? 0.1 : nil
                        }))
                    if config.maxCostUSD != nil {
                        currency("每个任务的阈值（USD）", \.maxCostUSD)
                        currency("每次未结算尝试预留（USD）", \.reservedCostUSD)
                        Text("按可观测的支出和预留额度检查。缺少可靠费用时，调度可能需要你确认。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(20).disabled(!loaded)
        }
        .onAppear {
            do {
                guard let store = hub.store else { throw SettingsFailure.unavailable }
                config = HubConfiguration.balanced.overriding(with: try store.globalConfiguration())
                lastSaved = config
                loaded = true
            } catch { errorMessage = error.localizedDescription }
        }
        .onChange(of: config) { old, newValue in
            guard loaded, newValue != lastSaved else { return }
            do {
                // Merge only edited team fields. Path and connection changes can come from another window.
                try hub.updateGlobalSettings { stored in
                    if old.roles != newValue.roles { stored.roles = newValue.roles }
                    if old.models != newValue.models { stored.models = newValue.models }
                    if old.enabledRoles != newValue.enabledRoles { stored.enabledRoles = newValue.enabledRoles }
                    if old.maxAttempts != newValue.maxAttempts { stored.maxAttempts = newValue.maxAttempts }
                    if old.maxConcurrent != newValue.maxConcurrent { stored.maxConcurrent = newValue.maxConcurrent }
                    if old.maxSeconds != newValue.maxSeconds { stored.maxSeconds = newValue.maxSeconds }
                    if old.maxRetries != newValue.maxRetries { stored.maxRetries = newValue.maxRetries }
                    if old.maxRepairs != newValue.maxRepairs { stored.maxRepairs = newValue.maxRepairs }
                    if old.maxCostUSD != newValue.maxCostUSD { stored.maxCostUSD = newValue.maxCostUSD }
                    if old.reservedCostUSD != newValue.reservedCostUSD { stored.reservedCostUSD = newValue.reservedCostUSD }
                    if old.providerConcurrency != newValue.providerConcurrency { stored.providerConcurrency = newValue.providerConcurrency }
                    if old.allowedFallbacks != newValue.allowedFallbacks { stored.allowedFallbacks = newValue.allowedFallbacks }
                    if old.paidProviders != newValue.paidProviders { stored.paidProviders = newValue.paidProviders }
                }
                lastSaved = newValue
                errorMessage = ""
            } catch {
                config = lastSaved
                errorMessage = "设置保存失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $namingTemplate) {
            VStack(alignment: .leading, spacing: 14) {
                Text("保存角色模板").font(.title2.weight(.semibold))
                TextField("模板名称", text: $templateName).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("取消") { namingTemplate = false }.keyboardShortcut(.cancelAction)
                    Button("保存模板") {
                        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            let next = SavedTeam(name: name, roles: config.roles, models: config.models, enabled: config.enabledRoles)
                            templatesData = try JSONEncoder().encode(teams + [next])
                            namingTemplate = false
                        } catch { errorMessage = error.localizedDescription; namingTemplate = false }
                    }.keyboardShortcut(.defaultAction)
                    .disabled(templateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              templateName.trimmingCharacters(in: .whitespacesAndNewlines) == "均衡全栈开发" ||
                              teams.contains { $0.name == templateName.trimmingCharacters(in: .whitespacesAndNewlines) })
                }
            }.padding(22).frame(width: 340)
        }
    }

    private func selectTeam(roles: [String: ProviderID], models: [String: String], enabled: [String]?) {
        config.roles = roles
        config.models = models
        config.enabledRoles = enabled
    }

    private func roleRow(_ role: SettingsRole) -> some View {
        let provider = config.roles[role.id] ?? .codex
        let models = hub.connections[provider]?.models ?? []
        let active = config.enabledRoles?.contains(role.id) ?? true
        return HStack(spacing: 10) {
            if role.id != "lead" {
                Toggle("", isOn: Binding(get: { active }, set: { enabled in
                    var roles = (config.enabledRoles ?? SettingsRole.all.map(\.id)).filter { $0 != role.id }
                    if enabled { roles.append(role.id) }
                    config.enabledRoles = roles
                })).labelsHidden().accessibilityLabel("启用\(role.name)角色")
            } else {
                Image(systemName: "person.fill").foregroundStyle(.secondary).frame(width: 15)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(role.name).font(.callout.weight(.semibold))
                Text(role.responsibility).font(.caption).foregroundStyle(.secondary)
            }.frame(minWidth: 84, alignment: .leading)
            Spacer(minLength: 2)
            Picker("\(role.name)工具", selection: Binding(get: { provider }, set: { value in
                config.roles[role.id] = value
                config.models[role.id] = nil
            })) {
                ForEach(ProviderID.allCases) { id in Text(id.displayName).tag(id) }
            }.labelsHidden().frame(maxWidth: 145).disabled(!active)
            SettingsModelPicker(roleName: role.name, models: models, selected: Binding(
                get: { config.models[role.id] ?? "" },
                set: { config.models[role.id] = $0.isEmpty ? nil : $0 }
            )).disabled(!active)
        }
    }

    private func limit(_ label: String, _ key: WritableKeyPath<HubConfiguration, Int?>, default fallback: Int,
                       range: ClosedRange<Int>, step: Int = 1, unit: String) -> some View {
        Stepper(value: Binding(get: { config[keyPath: key] ?? fallback },
                               set: { config[keyPath: key] = $0 }), in: range, step: step) {
            HStack { Text(label); Spacer(); Text("\(config[keyPath: key] ?? fallback) \(unit)").monospacedDigit() }
        }
    }

    private func currency(_ title: String, _ key: WritableKeyPath<HubConfiguration, Double?>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("USD", value: Binding(get: { config[keyPath: key] ?? 0 },
                             set: { if $0 >= 0 && $0.isFinite { config[keyPath: key] = $0 } }),
                      format: .number.precision(.fractionLength(0...6)))
                .frame(width: 95).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }
    }
}

struct SettingsModelPicker: View {
    let roleName: String
    let models: [String]
    @Binding var selected: String
    var defaultTitle = "CLI 默认模型"
    var body: some View {
        Picker("\(roleName)模型", selection: $selected) {
            Text(defaultTitle).tag("")
            if !selected.isEmpty && !models.contains(selected) {
                Text("\(selected)（未检出）").tag(selected)
            }
            ForEach(Array(Set(models)).sorted(), id: \.self) { model in Text(verbatim: model).tag(model) }
        }.labelsHidden().frame(maxWidth: 165).disabled(models.isEmpty && selected.isEmpty)
    }
}
