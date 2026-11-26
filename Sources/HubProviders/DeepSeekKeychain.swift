import Foundation
import Security

public enum DeepSeekKeychain {
    private static var item: [String:Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.agenthub.desktop.providers",
         kSecAttrAccount as String: "deepseek-api-key"]
    }
    private static func require(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw ProviderError.message("钥匙串操作失败 (\(status))。请检查本机钥匙串权限。")
        }
    }
    public static func hasKey() throws -> Bool {
        let status = SecItemCopyMatching(item as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        try require(status)
        return true
    }
    public static func save(_ key: String) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 8192, !clean.contains(where: { $0.isWhitespace }) else {
            throw ProviderError.message("请输入有效的 DeepSeek API key。")
        }
        let data = Data(clean.utf8)
        var new = item
        new[kSecValueData as String] = data
        new[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(new as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try require(SecItemUpdate(item as CFDictionary, [kSecValueData as String:data] as CFDictionary))
        } else {
            try require(status)
        }
    }
    public static func remove() throws {
        let status = SecItemDelete(item as CFDictionary)
        if status != errSecItemNotFound { try require(status) }
    }
    public static func read() throws -> String? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try require(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ProviderError.message("无法读取已保存的 DeepSeek key。")
        }
        return key
    }
}
