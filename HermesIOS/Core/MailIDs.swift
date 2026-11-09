import Foundation

/// Message and draft ids the app accepts from a card: Gmail's short ids, or the ids Noriven's Dashboard signs
/// (`m1.<payload>.<signature>`, docs/noriven-courriel-contrat.md). Anything else is dropped, so a card cannot point the app
/// at an arbitrary path.
public enum MailID {
    public static func isNoriven(_ id: String) -> Bool { id.wholeMatch(of: /m1\.[A-Za-z0-9_-]{1,8000}\.[A-Za-z0-9_-]{22}/) != nil }
    /// A received Noriven message: its signed id, or the short reference the agent's tools give it instead (`n-` and eight
    /// characters, which a model copies faithfully) and resolve on the server. Drafts keep their signed id.
    public static func isNorivenMessage(_ id: String) -> Bool { isNoriven(id) || id.wholeMatch(of: /n-[a-z2-7]{8}/) != nil }
    public static func validMessage(_ id: String) -> Bool { id.wholeMatch(of: /[A-Za-z0-9_-]{6,64}/) != nil || isNoriven(id) }
    public static func validDraft(_ id: String) -> Bool { id.wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil || isNoriven(id) }
}

/// The text the iPhone signs to approve sending one Noriven draft: the contract's exact bytes, one field per line.
public enum SendApproval {
    public static func message(draftID: String, fingerprint: String, signedAt: Int, nonce: String) -> Data {
        Data(["noriven-email-send-v1", draftID, fingerprint, String(signedAt), nonce].joined(separator: "\n").utf8)
    }
}
