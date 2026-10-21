import Foundation
import Security

/// Per-connection notification keys, shared between the app and the notification service
/// extension through a keychain access group named in both Info.plists (`HermesSharedKeychainGroup`).
/// Depends on no UI or app-model type. Never log a key.
public enum NotificationKeyStore {
    private static let service = "org.hermesios.notification-key"

    private static func group() -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "HermesSharedKeychainGroup") as? String
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func query(_ connection: UUID) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: connection.uuidString]
        if let group = group() { q[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    public static func generateKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: NotificationCrypto.keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    public static func key(for connection: UUID) -> Data? {
        var q = query(connection)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == NotificationCrypto.keyLength else { return nil }
        return data
    }

    @discardableResult
    public static func store(_ key: Data, for connection: UUID) -> Bool {
        guard key.count == NotificationCrypto.keyLength else { return false }
        let q = query(connection)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = q
        item[kSecValueData as String] = key
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public static func remove(for connection: UUID) {
        SecItemDelete(query(connection) as CFDictionary)
    }
}
