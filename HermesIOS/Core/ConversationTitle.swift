import Foundation

/// The title Hermes gives a conversation (`session.title` event): first an instant one cut from the opening message, then a
/// short one written by its title model (3 to 7 words). Shown as it comes, on one line, never empty.
public enum ConversationTitle {
    public static func clean(_ raw: String) -> String? {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let text = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"«»“”'`*#")))
        guard !text.isEmpty else { return nil }
        return text.count > 80 ? String(text.prefix(79)) + "…" : text
    }
}
