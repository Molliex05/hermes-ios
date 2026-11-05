import CryptoKit
import Foundation

/// A draft as its mailbox holds it (Gmail, or a Noriven Polaris box), read by the server for the app's « Envoyer » sheet
/// (not as the agent described it). `fingerprint` goes back with the send: the server refuses it if the draft changed after
/// Maxime read it. A Noriven draft is also sent with an approval signed on this iPhone (`needsDeviceApproval`), and the app
/// recomputes its fingerprint from the very fields it shows (`fingerprintMatches`): a relay that showed one draft and asked
/// to sign another is caught before Face ID.
public struct OutboxDraft: Equatable, Sendable {
    public struct File: Equatable, Sendable, Identifiable {
        public let id: Int
        public let name: String, type: String
        public let size: Int
        public var sha256 = ""
    }
    public let draftID: String
    public let to: String, cc: String, bcc: String, subject: String, body: String
    public let truncated: Bool
    public let attachments: [File]
    public let fingerprint: String
    /// The mailbox it will leave from (Noriven drafts), empty for Gmail.
    public let mailbox: String
    /// Noriven drafts: the exact From, the message it answers (empty if none), and each recipient list as sent.
    public let from: String, inReplyTo: String
    let recipients: [[String]]
    /// Whether every recipient, the subject, the text and the attachments came as plain values (no Noriven field missing).
    let complete: Bool
    public var needsDeviceApproval: Bool { MailID.isNoriven(draftID) }
    public var hasRecipient: Bool { ![to, cc, bcc].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }

    init?(_ value: JSONValue) {
        guard case .object = value, !value["fingerprint"].string.isEmpty, !value["id"].string.isEmpty else { return nil }
        func strings(_ field: JSONValue) -> [String]? {
            guard case .array(let items) = field else { return nil }
            return items.allSatisfy({ if case .string = $0 { true } else { false } }) ? items.map(\.string) : nil
        }
        func isString(_ field: JSONValue) -> Bool { if case .string = field { true } else { false } }
        func wholeSize(_ field: JSONValue) -> Int? {
            guard case .number(let v) = field, v >= 0, v <= 1e12, v == v.rounded() else { return nil }
            return Int(v)
        }
        let lists = ["to", "cc", "bcc"].map { strings(value[$0]) }
        draftID = value["id"].string
        (to, cc, bcc) = (lists[0]?.joined(separator: ", ") ?? value["to"].string, lists[1]?.joined(separator: ", ") ?? value["cc"].string,
                         lists[2]?.joined(separator: ", ") ?? value["bcc"].string)
        recipients = lists.map { $0 ?? [] }
        subject = value["subject"].string; body = value["body"].string; truncated = value["truncated"].bool
        fingerprint = value["fingerprint"].string; mailbox = value["mailbox"].string
        from = value["from"].string; inReplyTo = value["in_reply_to"].string
        let files = value["attachments"].array
        attachments = files.enumerated().map { index, file in
            File(id: index, name: file["name"].string, type: file["type"].string, size: wholeSize(file["size"]) ?? 0, sha256: file["sha256"].string)
        }
        let replyOK: Bool = { if case .null = value["in_reply_to"] { true } else { isString(value["in_reply_to"]) } }()
        complete = lists.allSatisfy { $0 != nil } && ["from", "subject", "body"].allSatisfy { isString(value[$0]) } && replyOK && !truncated
            && { if case .array = value["attachments"] { true } else { false } }()
            && files.allSatisfy { isString($0["name"]) && isString($0["type"]) && isString($0["sha256"]) && wholeSize($0["size"]) != nil }
    }

    /// noriven-web's `draftFingerprint` (lib/mail/agent/service.ts): SHA-256, lowercase hex, of a canonical sequence where a
    /// text is `<UTF-8 byte count>:<text>\n` and a list is `<count>\n` followed by its texts.
    public static func norivenFingerprint(id: String, from: String, to: [String], cc: [String], bcc: [String], subject: String, body: String,
                                          inReplyTo: String, attachments: [File]) -> String {
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: "\(value.utf8.count):".utf8); data.append(contentsOf: value.utf8); data.append(10) }
        func list(_ values: [String]) { data.append(contentsOf: "\(values.count)\n".utf8); values.forEach(text) }
        text("noriven-email-draft-v2"); text(id); text(from); list(to); list(cc); list(bcc)
        text(subject); text(body); text(inReplyTo)
        data.append(contentsOf: "\(attachments.count)\n".utf8)
        for file in attachments { text(file.name); text(file.type); text(String(file.size)); text(file.sha256) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A Noriven draft is sendable only if what is shown here hashes to the fingerprint that will be signed.
    public var fingerprintMatches: Bool {
        guard needsDeviceApproval else { return true }
        return complete && fingerprint == Self.norivenFingerprint(id: draftID, from: from, to: recipients[0], cc: recipients[1], bcc: recipients[2],
                                                                   subject: subject, body: body, inReplyTo: inReplyTo, attachments: attachments)
    }

    public static func path(profile: String, draftID: String) -> String? {
        guard profile.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,63}/) != nil, MailID.validDraft(draftID) else { return nil }
        return "/api/plugins/hermes-widgets/drafts/\(profile)/\(draftID)"
    }
}

/// A received message's whole text (Gmail or a Noriven box), read by the server for its card. Someone else's words: shown as plain text, and
/// never sent back to the agent.
public struct MailBody: Equatable, Sendable {
    public let text: String
    /// Longer than what the server sends.
    public let truncated: Bool

    public init?(_ json: JSONValue, messageID: String) {
        guard json["id"].string == messageID else { return nil }
        text = json["texte"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        truncated = json["tronque"].bool
    }

    public static func path(profile: String, messageID: String) -> String? {
        guard profile.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,63}/) != nil, MailID.validMessage(messageID) else { return nil }
        return "/api/plugins/hermes-widgets/messages/\(profile)/\(messageID)"
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
