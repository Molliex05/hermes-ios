import Foundation

/// Small block parser for chat Markdown. Inline emphasis/links use Apple's parser.
/// Line-based fences keep inline backticks and unfinished streamed code intact.
enum ChatMarkdown {
    enum Block: Equatable {
        case paragraph(String), heading(Int, String), quote(String)
        case item(depth: Int, marker: String, text: String, checked: Bool?)
        case code(language: String, text: String), table([[String]]), rule
    }

    static func parse(_ source: String) -> [Block] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [Block] = [], paragraph: [String] = []
        var i = 0
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = fenceStart(line) {
                flush(); i += 1
                var code: [String] = []
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= fence.count && candidate.allSatisfy({ $0 == fence.character }) { break }
                    code.append(lines[i]); i += 1
                }
                blocks.append(.code(language: fence.language, text: code.joined(separator: "\n")))
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
        flush(); return blocks
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
