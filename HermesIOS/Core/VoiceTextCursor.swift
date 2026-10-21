import Foundation

/// Feed each generated character once; snapshots must not restart speech. A final
/// snapshot that rewrites earlier text (normalization) contributes nothing instead of
/// ending the conversation: the streamed version was already delivered.
struct VoiceTextCursor {
    private(set) var sent = ""
    mutating func delta(_ text: String) -> String {
        guard text.hasPrefix(sent), text != sent else { return "" }
        let delta = String(text.dropFirst(sent.count)); sent = text
        return delta
    }
}
