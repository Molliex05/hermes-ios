import Foundation
import Security

enum Keychain {
    static func save(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "org.hermesios.credentials", kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw RPCFailure("Le trousseau iOS n’a pas pu enregistrer la connexion.", code: Int(result)) }
        } else if status != errSecSuccess {
            throw RPCFailure("Le trousseau iOS n’est pas accessible.", code: Int(status))
        }
    }

    static func read(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.hermesios.credentials", kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: "org.hermesios.credentials", kSecAttrAccount as String: key] as CFDictionary)
    }
}
