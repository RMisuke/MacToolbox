import Foundation
import Security

/// 敏感字段只放 Keychain；任务配置和 records 只保留空值。
public enum SecretStore {
    private static let service = "com.chensinuo.mactoolbox.demo.secrets"

    public static func account(toolID: String, key: String) -> String {
        "\(toolID).\(key)"
    }

    public static func value(toolID: String, key: String) -> String? {
        var result: CFTypeRef?
        var query = baseQuery(toolID: toolID, key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    public static func has(toolID: String, key: String) -> Bool {
        var result: CFTypeRef?
        var query = baseQuery(toolID: toolID, key: key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess
    }

    @discardableResult
    public static func set(_ value: String, toolID: String, key: String) -> Bool {
        guard !value.isEmpty else {
            delete(toolID: toolID, key: key)
            return true
        }
        guard let data = value.data(using: .utf8) else { return false }

        let base = baseQuery(toolID: toolID, key: key)
        let updateStatus = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func delete(toolID: String, key: String) -> Bool {
        let status = SecItemDelete(baseQuery(toolID: toolID, key: key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(toolID: String, key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(toolID: toolID, key: key)
        ]
    }
}
