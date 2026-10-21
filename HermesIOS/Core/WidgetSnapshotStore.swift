import Foundation
import Security

/// The saved snapshot, shared by the app and the widgets through the keychain access group both Info.plists
/// name (`HermesSharedKeychainGroup`, the same group as the notification keys). The widgets never reach the
/// network: they show what the app last saved. The figures are not secrets, but the keychain keeps them
/// out of reach of other apps without needing an App Group. `directory` stores a plain file instead (tests).
public enum WidgetSnapshotStore {
    private static let service = "org.hermesios.widget-snapshot"
    private static let account = "noriven"
    private static let file = "widget-snapshot.json"

    private static func group() -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "HermesSharedKeychainGroup") as? String
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private static func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if let group = group() { q[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    public static func read(from directory: URL? = nil) -> WidgetSnapshot? {
        readData(from: directory).flatMap { try? WidgetSnapshot.decode($0) }
    }

    /// The saved payload exactly as the server sent it.
    public static func readData(from directory: URL? = nil) -> Data? {
        let data: Data?
        if let directory { data = try? Data(contentsOf: directory.appendingPathComponent(file)) }
        else {
            var q = query()
            q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            data = SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
        }
        return data.flatMap { (try? WidgetSnapshot.decode($0)) == nil ? nil : $0 }
    }

    /// Validates the payload before saving, so a malformed answer never replaces a good snapshot.
    @discardableResult
    public static func write(_ data: Data, to directory: URL? = nil) -> WidgetSnapshot? {
        guard let snapshot = try? WidgetSnapshot.decode(data) else { return nil }
        if let directory {
            do { try data.write(to: directory.appendingPathComponent(file), options: [.atomic]) } catch { return nil }
            return snapshot
        }
        let q = query()
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return snapshot }
        guard status == errSecItemNotFound else { return nil }
        var item = q
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess ? snapshot : nil
    }

    public static func clear(from directory: URL? = nil) {
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
        else { SecItemDelete(query() as CFDictionary) }
    }
}
