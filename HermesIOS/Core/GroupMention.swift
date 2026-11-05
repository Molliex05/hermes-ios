import Foundation

/// `@` in a group. Hermes reads the mentions itself (`resolve_mentions`) and decides who answers; the app only helps to write them.
public enum GroupMention {
    /// The word after a final « @ », as typed so far; nil when the draft does not end in a mention.
    public static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let word = draft[draft.index(after: at)...]
        return word.contains(where: \.isWhitespace) ? nil : String(word)
    }

    /// The draft with its final mention written out, ready for the next word.
    public static func completed(_ draft: String, handle: String) -> String {
        guard query(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return draft[..<at] + "@" + handle + " "
    }

    /// « Hermès » → « hermes » : what is typed after the @, in the letters Hermes recognises. `fallback` is the profile's name.
    public static func handle(title: String, fallback: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_CA"))
        let kept = folded.unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }
        let handle = String(String.UnicodeScalarView(kept))
        return handle.isEmpty || !handle.first!.isLetter ? fallback : handle
    }
}

/// A message one agent sent another with Hermes' `message_agent`. It lands on the user side of the recipient's Bot Chat, signed
/// by the server: « Message from 🤖 Jarvis (@personnel): … ».
public struct AgentNote: Equatable, Sendable {
    public let name: String, handle: String, body: String

    public init?(_ text: String) {
        guard let match = text.prefixMatch(of: #/Message from (?:🤖 )?(.+?) \(@([A-Za-z0-9._:-]+)\): /#) else { return nil }
        name = String(match.1); handle = String(match.2); body = String(text[match.range.upperBound...])
    }
}
