import Foundation

/// A Gmail draft as Gmail holds it, read by the server for the app's « Envoyer » sheet (not as the agent described it).
/// `fingerprint` goes back with the send: the server refuses it if the draft changed after Maxime read it.
public struct OutboxDraft: Equatable, Sendable {
    public struct File: Equatable, Sendable, Identifiable {
        public let id: Int
        public let name: String, type: String
        public let size: Int
    }
    public let draftID: String
    public let to: String, cc: String, bcc: String, subject: String, body: String
    public let truncated: Bool
    public let attachments: [File]
    public let fingerprint: String
    public var hasRecipient: Bool { ![to, cc, bcc].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    init?(_ value: JSONValue) {
        guard case .object = value, !value["fingerprint"].string.isEmpty, !value["id"].string.isEmpty else { return nil }
        draftID = value["id"].string; to = value["to"].string; cc = value["cc"].string; bcc = value["bcc"].string
        subject = value["subject"].string; body = value["body"].string; truncated = value["truncated"].bool
        fingerprint = value["fingerprint"].string
        attachments = value["attachments"].array.prefix(20).enumerated().map { index, file in
            File(id: index, name: file["name"].string, type: file["type"].string, size: file["size"].int)
        }
    }

    public static func path(profile: String, draftID: String) -> String? {
        guard profile.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,63}/) != nil, draftID.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil else { return nil }
        return "/api/plugins/hermes-widgets/drafts/\(profile)/\(draftID)"
    }
}

/// The drafts already sent from this iPhone, so a card says « Envoyé » when the conversation is opened again.
public enum SentDrafts {
    private static let key = "sentDrafts.v1"
    public static func contains(_ id: String, in defaults: UserDefaults = .standard) -> Bool { (defaults.stringArray(forKey: key) ?? []).contains(id) }
    public static func add(_ id: String, in defaults: UserDefaults = .standard) {
        defaults.set(Array(((defaults.stringArray(forKey: key) ?? []).filter { $0 != id } + [id]).suffix(300)), forKey: key)
    }
}
