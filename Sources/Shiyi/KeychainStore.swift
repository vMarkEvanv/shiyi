import Foundation
import Security

protocol APIKeyStoring {
    func loadAPIKey() throws -> String
    func saveAPIKey(_ value: String) throws
}

/// API credentials stay in the login Keychain, outside preference files.
struct KeychainStore: APIKeyStoring {
    var service = "com.shiyi.app"
    var account = "translation-api-key"

    func loadAPIKey() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw KeychainError.operationFailed(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    func saveAPIKey(_ value: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.operationFailed(status)
            }
            return
        }

        let data = Data(normalized.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.operationFailed(status) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.operationFailed(addStatus) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum KeychainError: LocalizedError {
    case operationFailed(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .operationFailed:
            return "无法访问钥匙串，请检查钥匙串是否已解锁，再试一次。"
        case .invalidData:
            return "钥匙串中的 API Key 无法读取，请重新保存。"
        }
    }
}
