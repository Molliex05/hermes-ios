import Foundation

/// Feed each generated character once; snapshots must not restart speech.
struct VoiceTextCursor {
    private(set) var sent = ""
    mutating func delta(_ text: String) throws -> String {
        if text == sent { return "" }
        guard text.hasPrefix(sent) else {
            // Final snapshots sometimes trim the last streamed whitespace.
            if text.trimmingCharacters(in: .whitespacesAndNewlines) == sent.trimmingCharacters(in: .whitespacesAndNewlines) { return "" }
            throw RPCFailure("La réponse a changé pendant sa lecture. Retrouvez sa version finale dans le chat.")
        }
        let delta = String(text.dropFirst(sent.count)); sent = text
        return delta
    }
}
