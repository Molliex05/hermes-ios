import Foundation
import Security

/// A small value the app and its extensions (widget, share sheet) all read and write: kept in the keychain access
/// group they share (`HermesSharedKeychainGroup` in every Info.plist), so no App Group is needed. `directory` stores a
/// plain file instead (tests).
public struct SharedBlob: Sendable {
    public let account: String
    private static let service = "org.hermesios.shared-blob"

    public init(account: String) { self.account = account }

    private func group() -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "HermesSharedKeychainGroup") as? String
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    private func query() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account]
        if let group = group() { q[kSecAttrAccessGroup as String] = group }
        #if os(macOS)
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    public func read(from directory: URL? = nil) -> Data? {
        if let directory { return try? Data(contentsOf: directory.appendingPathComponent("\(account).json")) }
        var q = query()
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    @discardableResult
    public func write(_ data: Data, to directory: URL? = nil) -> Bool {
        if let directory {
            do { try data.write(to: directory.appendingPathComponent("\(account).json"), options: [.atomic]); return true } catch { return false }
        }
        let q = query()
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = q
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    public func clear(from directory: URL? = nil) {
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(account).json")) }
        else { SecItemDelete(query() as CFDictionary) }
    }
}
