import Foundation
import Security

struct KeychainStore {
    private let service = "app.dsh.mobile.client.credentials"

    static func hermesTokenAccount(for profileID: UUID) -> String {
        "\(profileID.uuidString).hermes-native-token"
    }

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                if status == errSecMissingEntitlement {
                    return "当前 App 构建缺少钥匙串签名权限，请重新安装正常签名的版本。"
                }
                return "无法访问钥匙串（错误 \(status)）。"
            }
        }
    }

    func password(for profileID: UUID) -> String? {
        guard let data = data(for: profileID.uuidString) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return data
    }

    func setPassword(_ password: String, for profileID: UUID) throws {
        try setData(Data(password.utf8), for: profileID.uuidString)
    }

    func setData(_ data: Data, for account: String) throws {
        let selector: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(selector as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
        let addStatus = SecItemAdd(selector.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func deletePassword(for profileID: UUID) throws {
        try deleteData(for: profileID.uuidString)
    }

    func deleteData(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
