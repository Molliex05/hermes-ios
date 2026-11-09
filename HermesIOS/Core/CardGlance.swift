import Foundation

/// A card from the agent's reply, small enough for the Lock Screen and the Dynamic Island during a voice call: a symbol,
/// a title, a figure and two short lines. Only the app writes it, locally (the call's activity is never pushed through
/// Apple), so it may hold conversation text. Bounded to stay far below ActivityKit's 4 KB.
public struct CardGlance: Codable, Hashable, Sendable {
    public var symbol: String
    public var title: String
    public var value: String
    public var lines: [String]

    public init(symbol: String, title: String, value: String = "", lines: [String] = []) {
        self.symbol = symbol
        self.title = Self.bound(title, 70)
        self.value = Self.bound(value, 14)
        self.lines = lines.map { Self.bound($0, 90) }.filter { !$0.isEmpty }.prefix(2).map { $0 }
    }

    static func bound(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }
}
