import Foundation

/// Removes fenced blocks (code, rich cards) from a reply on its way to speech, chunk by chunk as it streams: a card's
/// JSON or a code listing is never read aloud. Fences follow `ChatMarkdown.fence` exactly (same opener, same closing
/// rule, same indentation), so what is spoken matches what is shown as text. A line that could open or close a fence is
/// held until it ends; everything else passes through at once so speech starts as early as before.
struct SpokenTextFilter {
    /// The fence the text is inside, if any.
    private var open: ChatMarkdown.Fence?
    /// The current line, held while it could still be a fence line.
    private var line = ""
    /// Whether the current line is held (true) or already streaming through (false).
    private var holding = true

    mutating func feed(_ chunk: String) -> String {
        var out = ""
        for character in chunk {
            if character == "\n" || character == "\r\n" {
                out += endLine()
                continue
            }
            if character == "\r" { continue }
            guard holding else {
                if open == nil { out.append(character) }
                continue
            }
            line.append(character)
            if !Self.couldBeFence(line) {
                holding = false
                if open == nil { out += line }
                line = ""
            }
        }
        return out
    }

    /// Text still held at the end of the reply (a last line that only looked like a possible fence).
    mutating func finish() -> String {
        defer { open = nil; line = ""; holding = true }
        guard holding, !line.isEmpty, open == nil, ChatMarkdown.fence(line) == nil else { return "" }
        return line
    }

    /// The whole text at once, for non-streamed speech.
    static func strip(_ text: String) -> String {
        var filter = SpokenTextFilter()
        return filter.feed(text) + filter.finish()
    }

    private mutating func endLine() -> String {
        defer { line = ""; holding = true }
        if let current = open {
            if holding, current.closes(line) { open = nil }
            return ""
        }
        if holding, let start = ChatMarkdown.fence(line) {
            open = start
            return ""
        }
        return holding ? line + "\n" : "\n"
    }

    /// Whether a line beginning like this may still turn out to open or close a fence: indentation (at most three
    /// spaces, as ChatMarkdown allows), then backticks or tildes. Three or more marks keep the whole line held, since
    /// only its end tells « ```ui » from « ```npm install``` », which is inline code.
    private static func couldBeFence(_ prefix: String) -> Bool {
        let body = prefix.drop { $0 == " " || $0 == "\t" }
        guard prefix.prefix(while: { $0 == " " }).count <= 3 else { return false }
        guard let first = body.first else { return true }
        guard first == "`" || first == "~" else { return false }
        let marks = body.prefix { $0 == first }.count
        return marks >= 3 || marks == body.count
    }
}
