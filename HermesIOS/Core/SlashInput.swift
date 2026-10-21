import Foundation

struct SlashInput {
    let name: String
    let argument: String
    var text: String { "/" + name + (argument.isEmpty ? "" : " " + argument) }
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let token = parts.first, token.hasPrefix("/"), token.range(of: #"^/[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil else { return nil }
        name = String(token.dropFirst()).lowercased()
        argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}
