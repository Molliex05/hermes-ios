import Foundation

/// Small block parser for chat Markdown. Inline emphasis/links use Apple's parser.
/// Line-based fences keep inline backticks and unfinished streamed code intact.
enum ChatMarkdown {
    enum Block: Equatable {
        case paragraph(String), heading(Int, String), quote(String)
        case item(depth: Int, marker: String, text: String, checked: Bool?)
        case code(language: String, text: String), table([[String]]), rule
        /// A ```ui fence: a rich card described in JSON (see `ChatCard`). `complete` is false while it still streams.
        case card(String, complete: Bool)
    }

    /// A point where parsing can resume from scratch: the UTF-8 offset of a line that follows a
    /// blank line and starts without indentation, and the number of blocks completed before it.
    /// Nothing before it can change when text is appended after it (no lookahead crosses a blank
    /// line, and only an indented line can extend the previous list item).
    struct Checkpoint: Equatable, Sendable {
        var utf8Offset: Int
        var blockCount: Int
    }

    static func parse(_ source: String) -> [Block] { parseDetailed(normalized(source)).blocks }

    static func normalized(_ source: String) -> String {
        // "\r\n" is one Character, so look for the carriage return byte instead.
        source.utf8.contains(13) ? source.replacingOccurrences(of: "\r\n", with: "\n") : source
    }

    /// Parses already-normalized text and reports the last checkpoint reached.
    static func parseDetailed(_ source: String) -> (blocks: [Block], checkpoint: Checkpoint?) {
        let lines = source.components(separatedBy: "\n")
        var blocks: [Block] = [], paragraph: [String] = []
        var checkpoint: Checkpoint?
        var i = 0, lineOffset = 0, offsetLine = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if i > 0, paragraph.isEmpty, let first = line.first, !first.isWhitespace,
               lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                while offsetLine < i { lineOffset += lines[offsetLine].utf8.count + 1; offsetLine += 1 }
                checkpoint = Checkpoint(utf8Offset: lineOffset, blockCount: blocks.count)
            }
            if let fence = fenceStart(line) {
                flush(); i += 1
                var code: [String] = []
                var closed = false
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= fence.count && candidate.allSatisfy({ $0 == fence.character }) { closed = true; break }
                    code.append(lines[i]); i += 1
                }
                if ChatCard.isCardFence(fence.language) { blocks.append(.card(code.joined(separator: "\n"), complete: closed)) }
                else { blocks.append(.code(language: fence.language, text: code.joined(separator: "\n"))) }
                if i < lines.count { i += 1 }
                continue
            }
            if trimmed.isEmpty { flush(); i += 1; continue }
            if i + 1 < lines.count, line.contains("|"), tableDivider(lines[i + 1]) {
                flush()
                let header = cells(line)
                var rows = [header]; i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = cells(lines[i])
                    rows.append(Array((row + Array(repeating: "", count: header.count)).prefix(header.count))); i += 1
                }
                blocks.append(.table(rows)); continue
            }
            let hashes = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                flush(); blocks.append(.heading(hashes, String(trimmed.dropFirst(hashes + 1)))); i += 1; continue
            }
            let compact = trimmed.filter { !$0.isWhitespace }
            if compact.count >= 3, let c = compact.first, "*-_".contains(c), compact.allSatisfy({ $0 == c }) {
                flush(); blocks.append(.rule); i += 1; continue
            }
            if trimmed.hasPrefix(">") {
                flush(); var quoted: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quoted.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n"))); continue
            }
            if let item = listItem(line) {
                flush(); blocks.append(item); i += 1; continue
            }
            // Indented continuation belongs to its preceding list item.
            if line.first?.isWhitespace == true, paragraph.isEmpty,
               case let .item(depth, marker, text, checked) = blocks.last {
                blocks[blocks.count - 1] = .item(depth: depth, marker: marker, text: text + "\n" + trimmed, checked: checked)
            } else { paragraph.append(line) }
            i += 1
        }
        flush(); return (blocks, checkpoint)
    }

    /// Splits code into groups of lines so a streamed code block only re-measures its last group.
    static func codeChunks(_ text: String, lines: Int = 40) -> [String] {
        var result: [String] = []
        var start = text.startIndex, count = 0
        var index = text.utf8.startIndex
        while index < text.utf8.endIndex {
            if text.utf8[index] == 10 {
                count += 1
                if count == lines {
                    result.append(String(text[start..<index]))
                    start = text.utf8.index(after: index); count = 0
                }
            }
            index = text.utf8.index(after: index)
        }
        result.append(String(text[start...]))
        return result
    }

    /// Byte equality of the first `count` UTF-8 bytes (no Unicode normalization work).
    static func sameUTF8Prefix(_ lhs: String, _ rhs: String, count: Int) -> Bool {
        guard lhs.utf8.count >= count, rhs.utf8.count >= count else { return false }
        guard count > 0 else { return true }
        var lhs = lhs, rhs = rhs
        return lhs.withUTF8 { a in rhs.withUTF8 { b in memcmp(a.baseAddress!, b.baseAddress!, count) == 0 } }
    }

    static func sameUTF8(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.count == rhs.utf8.count && sameUTF8Prefix(lhs, rhs, count: lhs.utf8.count)
    }

    private static func fenceStart(_ line: String) -> (character: Character, count: Int, language: String)? {
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let count = trimmed.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let language = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        guard first != "`" || !language.contains("`") else { return nil }
        return (first, count, language)
    }

    private static func listItem(_ line: String) -> Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0.isWhitespace }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        var marker: String, content: String
        if ["- ", "* ", "+ "].contains(where: trimmed.hasPrefix) {
            marker = "•"; content = String(trimmed.dropFirst(2))
        } else {
            let number = trimmed.prefix { $0.isNumber }
            let rest = trimmed.dropFirst(number.count)
            guard !number.isEmpty, number.count <= 9, rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
            marker = String(number) + "."; content = String(rest.dropFirst(2))
        }
        var checked: Bool?
        if content.hasPrefix("[ ] ") { checked = false; content = String(content.dropFirst(4)) }
        else if content.lowercased().hasPrefix("[x] ") { checked = true; content = String(content.dropFirst(4)) }
        return .item(depth: min(indent / 2, 6), marker: marker, text: content, checked: checked)
    }

    static func cells(_ line: String) -> [String] {
        var result: [String] = [], cell = "", escaped = false
        var codeFence: Int?
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var offset = 0
        while offset < characters.count {
            let c = characters[offset]; offset += 1
            if escaped { cell.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; cell.append(c); continue }
            if c == "`" {
                var count = 1
                while offset < characters.count, characters[offset] == "`" { count += 1; offset += 1 }
                if codeFence == count { codeFence = nil } else if codeFence == nil { codeFence = count }
                cell += String(repeating: "`", count: count); continue
            }
            if c == "|", codeFence == nil { result.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(c) }
        }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { result.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), result.last == "" { result.removeLast() }
        return result
    }

    private static func tableDivider(_ line: String) -> Bool {
        let parts = cells(line)
        return !parts.isEmpty && parts.allSatisfy {
            let part = $0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return part.count >= 3 && part.allSatisfy { $0 == "-" }
        }
    }
}

/// Incremental parse of a growing message. Blocks before the last checkpoint are reused as long
/// as their bytes are unchanged; only the tail (usually the block being streamed) is re-parsed.
/// Any edit inside the stable prefix falls back to a full parse, so results always equal
/// `ChatMarkdown.parse(text)`.
struct StreamingMarkdown: Sendable {
    private(set) var blocks: [ChatMarkdown.Block] = []
    private var source = ""
    private var normalized = ""
    private var stableBlocks: [ChatMarkdown.Block] = []
    private var stableCount = 0

    init() {}

    @discardableResult
    mutating func update(_ raw: String) -> [ChatMarkdown.Block] {
        if ChatMarkdown.sameUTF8(raw, source) { return blocks }
        let text = ChatMarkdown.normalized(raw)
        var base: [ChatMarkdown.Block] = [], offset = 0
        if stableCount > 0, ChatMarkdown.sameUTF8Prefix(text, normalized, count: stableCount) {
            base = stableBlocks; offset = stableCount
        }
        let tail = offset == 0 ? text : String(text[text.utf8.index(text.startIndex, offsetBy: offset)...])
        let parsed = ChatMarkdown.parseDetailed(tail)
        blocks = base + parsed.blocks
        if let checkpoint = parsed.checkpoint {
            stableBlocks = base + parsed.blocks.prefix(checkpoint.blockCount)
            stableCount = offset + checkpoint.utf8Offset
        } else if offset == 0 {
            stableBlocks = []; stableCount = 0
        }
        source = raw; normalized = text
        return blocks
    }
}

/// Parsed blocks per message id, validated against the exact text. Streaming messages keep
/// their incremental parser here, so a finished answer is never parsed again from scratch.
@MainActor final class MarkdownCache {
    static let shared = MarkdownCache()
    private struct Entry { var parser = StreamingMarkdown(); var tick = 0 }
    private var entries: [String: Entry] = [:]
    private var tick = 0
    private let capacity: Int

    init(capacity: Int = 600) { self.capacity = capacity }

    func blocks(id: String, text: String) -> [ChatMarkdown.Block] {
        tick += 1
        let blocks = entries[id, default: Entry()].parser.update(text)
        entries[id]?.tick = tick
        if entries.count > capacity {
            let stale = entries.sorted { $0.value.tick < $1.value.tick }.prefix(entries.count - capacity * 3 / 4)
            for (key, _) in stale { entries.removeValue(forKey: key) }
        }
        return blocks
    }
}
