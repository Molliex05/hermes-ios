import CryptoKit
import Foundation

/// Decrypted notification text. Never log or persist these fields.
public struct NotificationContent: Codable, Equatable, Sendable {
    public var agent: String
    public var conversation: String
    public var preview: String
    public init(agent: String, conversation: String, preview: String) {
        self.agent = agent; self.conversation = conversation; self.preview = preview
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation) ?? ""
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
    }
}

/// AES-256-GCM, AAD = UTF-8 of the event id, wire layout `base64(nonce12 || ciphertext || tag16)`.
/// Every failure returns nil; nothing here traps or logs.
public enum NotificationCrypto {
    public static let keyLength = 32
    static let maxEncodedLength = 8192

    public static func decrypt(_ encoded: String, key: Data, eventID: String) -> NotificationContent? {
        guard key.count == keyLength, !eventID.isEmpty, encoded.utf8.count <= maxEncodedLength,
              let combined = Data(base64Encoded: encoded), combined.count >= 12 + 16,
              let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: Data(eventID.utf8)),
              let content = try? JSONDecoder().decode(NotificationContent.self, from: plain),
              !(content.agent.isEmpty && content.conversation.isEmpty && content.preview.isEmpty) else { return nil }
        return content
    }

    /// Used by tests (and to mirror the server). `nonce` must be 12 bytes; random when nil.
    public static func encrypt(_ plaintext: Data, key: Data, eventID: String, nonce: Data? = nil) -> String? {
        guard key.count == keyLength else { return nil }
        do {
            let iv = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: iv, authenticating: Data(eventID.utf8))
            return box.combined?.base64EncodedString()
        } catch { return nil }
    }
}
