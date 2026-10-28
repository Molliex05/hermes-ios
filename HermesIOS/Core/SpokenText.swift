import Foundation

/// Removes fenced blocks (code, rich cards) from a reply on its way to speech, chunk by chunk as it streams: a card's
/// JSON or a code listing is never read aloud. A fence opens or closes only on a line that starts (after up to three
/// spaces) with three backticks or tildes; characters that could be such a start are held until the line shows what it is,
/// everything else passes through at once so speech starts as early as before.
struct SpokenTextFilter {
    private var inFence = false
    private var atLineStart = true
    private var held = ""
    private var dropLine = false

    mutating func feed(_ chunk: String) -> String {
        var out = ""
        for character in chunk {
            if character == "\n" {
                if !held.isEmpty {
                    if Self.isFence(held) { inFence.toggle(); dropLine = true } else if !inFence { out += held }
                    held = ""
                }
                if !inFence && !dropLine { out.append(character) }
                atLineStart = true; dropLine = false
                continue
            }
            if atLineStart {
                if character == "`" || character == "~" || (character == " " && held.count < 3 && !held.contains(where: { $0 != " " })) {
                    held.append(character); continue
                }
                atLineStart = false
                if Self.isFence(held) {                 // an opening fence with a language tag, e.g. ```ui
                    inFence.toggle(); dropLine = true; held = ""; continue
                }
                if !inFence { out += held; out.append(character) }
                held = ""
                continue
            }
            if !inFence && !dropLine { out.append(character) }
        }
        return out
    }

    /// Text still held at the end of the reply (a last line that only looked like a possible fence).
    mutating func finish() -> String {
        defer { held = ""; atLineStart = true; dropLine = false }
        return inFence || Self.isFence(held) ? "" : held
    }

    /// The whole text at once, for non-streamed speech.
    static func strip(_ text: String) -> String {
        var filter = SpokenTextFilter()
        return filter.feed(text) + filter.finish()
    }

    private static func isFence(_ start: String) -> Bool {
        let marks = start.drop { $0 == " " }
        guard marks.count >= 3, let first = marks.first, first == "`" || first == "~" else { return false }
        return marks.allSatisfy { $0 == first }
    }
}
