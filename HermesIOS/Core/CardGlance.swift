import Foundation

/// A card from the agent's reply, small enough for the Lock Screen and the Dynamic Island during a voice call: a symbol,
/// a title, a figure and two short lines. Only the app writes it, locally (the call's activity is never pushed through
/// Apple), so it may hold conversation text. Bounded to stay far below ActivityKit's 4 KB.
public struct CardGlance: Codable, Hashable, Sendable {
    public var symbol: String
    public var title: String
    public var value: String
    public var lines: [String]
    /// The card's own detail, up to three rows (the days of a forecast, the next appointments, emails, figures), drawn
    /// when the activity is expanded. Empty: the title and lines say it all.
    public var rows: [Row] = []

    public struct Row: Codable, Hashable, Sendable {
        public var symbol: String
        public var label: String
        public var detail: String
        public var value: String
        /// 0…1 for an objective; nil for anything else.
        public var progress: Double?

        public init(symbol: String = "", label: String, detail: String = "", value: String = "", progress: Double? = nil) {
            self.symbol = symbol
            self.label = CardGlance.bound(label, 40)
            self.detail = CardGlance.bound(detail, 60)
            self.value = CardGlance.bound(value, 16)
            self.progress = progress.map { min(max($0, 0), 1) }
        }
    }

    public init(symbol: String, title: String, value: String = "", lines: [String] = [], rows: [Row] = []) {
        self.symbol = symbol
        self.title = Self.bound(title, 70)
        self.value = Self.bound(value, 14)
        self.lines = lines.map { Self.bound($0, 90) }.filter { !$0.isEmpty }.prefix(2).map { $0 }
        self.rows = rows.filter { !$0.label.isEmpty || !$0.detail.isEmpty }.prefix(3).map { $0 }
    }

    private enum CodingKeys: String, CodingKey { case symbol, title, value, lines, rows }

    /// A glance saved before rows existed still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try c.decode(String.self, forKey: .symbol); title = try c.decode(String.self, forKey: .title)
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
        rows = try c.decodeIfPresent([Row].self, forKey: .rows) ?? []
    }

    static func bound(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }
}
