import Foundation
import HubKit
import HubProviders

enum SettingsFailure: LocalizedError {
    case unavailable, invalidCommand(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "本地数据库不可用。请检查主窗口中的存储错误。"
        case .invalidCommand(let message): return message
        }
    }
}

struct CachedCLIInspection: Codable {
    let path: String?
    let version: String?
    let checkedAt: Date
}

@MainActor
extension HubController {
    func cliOverride(_ id: ProviderID) -> URL? {
        guard let path = try? store?.globalConfiguration().executableOverrides[id.rawValue] else { return nil }
        return URL(fileURLWithPath: path)
    }

    func refreshConnection(_ id: ProviderID) async {
        guard detectingProviders.insert(id).inserted else { return }
        defer { detectingProviders.remove(id) }
        var path = cliOverride(id)
        while !Task.isCancelled {
            let detected = await ProviderDiscovery.detect(id, override: path)
            let currentPath = cliOverride(id)
            if path == currentPath {
                connections[id] = detected
                let cache = CachedCLIInspection(path: detected.executable?.path, version: detected.version,
                                                checkedAt: detected.checkedAt)
                if let record = try? JSONEncoder().encode(cache) {
                    preferences.set(record, forKey: "cliInspection." + id.rawValue)
                }
                return
            }
            path = currentPath
        }
    }

    func cachedInspection(_ id: ProviderID) -> CachedCLIInspection? {
        guard let data = preferences.data(forKey: "cliInspection." + id.rawValue) else { return nil }
        return try? JSONDecoder().decode(CachedCLIInspection.self, from: data)
    }

    func refreshConnections() async {
        async let codex: Void = refreshConnection(.codex)
        async let antigravity: Void = refreshConnection(.antigravity)
        async let dsh: Void = refreshConnection(.dsh)
        _ = await (codex, antigravity, dsh)
    }

    func updateGlobalSettings(_ update: (inout HubConfiguration) throws -> Void) throws {
        guard let store else { throw SettingsFailure.unavailable }
        var config = try store.globalConfiguration()
        try update(&config)
        try store.saveGlobalConfiguration(config)
        objectWillChange.send()
    }

    func setCLIOverride(_ url: URL?, for id: ProviderID) async throws {
        if let url {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard url.isFileURL, values.isDirectory != true,
                  FileManager.default.isExecutableFile(atPath: url.path) else {
                throw SettingsFailure.invalidCommand("请选择可执行的 CLI 文件。")
            }
        }
        try updateGlobalSettings { $0.executableOverrides[id.rawValue] = url?.standardizedFileURL.path }
        await refreshConnection(id)
    }
}
