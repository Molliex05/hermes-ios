import CryptoKit
import Foundation

/// Small, device-protected display cache; no model keys or Hermes state live here.
actor LocalCache {
    private let folder: URL
    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HermesIOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resource = folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? resource.setResourceValues(values)
    }
    private func url(_ key: String) -> URL {
        // Every caller supplies a UUID, a digest or a fixed internal key, never a server path.
        folder.appendingPathComponent(key.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".json")
    }
    /// A file that exists but no longer decodes is moved aside, never silently overwritten.
    func read<T: Decodable & Sendable>(_ type: T.Type, key: String) -> T? {
        let path = url(key)
        guard let data = try? Data(contentsOf: path) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            let aside = path.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: path, to: aside)
            return nil
        }
    }
    func save<T: Encodable & Sendable>(_ value: T, key: String) throws {
        try JSONEncoder().encode(value).write(to: url(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func attachmentURL(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".attachment") }
    func saveAttachment(_ data: Data, id: UUID) throws {
        try data.write(to: attachmentURL(id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func attachment(_ id: UUID) throws -> Data { try Data(contentsOf: attachmentURL(id)) }
    func removeAttachment(_ id: UUID) { try? FileManager.default.removeItem(at: attachmentURL(id)) }
    func remove(_ key: String) throws {
        let path = url(key)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    /// Removes every per-chat file of a connection (used when the connection is forgotten).
    func removeChats(connection: String) {
        let prefix = connection + "-chat-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }

    /// One file per cached conversation: the stored chat key may contain any character.
    nonisolated static func chatKey(connection: String, chat: String) -> String {
        connection + "-chat-" + SHA256.hash(data: Data(chat.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
