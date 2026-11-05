import Foundation

/// A piece the agent composed the « À l'affiche » widget with (`widget_bloc`): figures, rings, a curve, a short list or a
/// note, each in its own named slot with its own lifetime. `meteo` and `affiche` carry nothing and only place what the widget
/// already has (the weather; the agent's lines, else the calendar). The server cuts every field to size; this decoding cuts
/// again, so a malformed block is dropped and never breaks the widget.
public struct WidgetBlock: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case metrics, progress, chart, list, note, meteo, affiche }
    public struct Metric: Equatable, Sendable { public var label, value, delta, tone: String }
    public struct Ring: Equatable, Sendable {
        public var label: String, value: Double, goal: Double, unit: String
        public var fraction: Double { min(1, max(0, value / goal)) }
    }
    public struct Point: Equatable, Sendable { public var label: String, value: Double }
    public struct Row: Equatable, Sendable { public var title, subtitle, value, icon, tone: String }

    public var slot: String
    public var order: Int
    public var kind: Kind
    public var title = "", icon = "", ask = "", tone = ""
    public var metrics: [Metric] = []
    public var rings: [Ring] = []
    public var points: [Point] = []
    /// A chart's headline: its latest value and change, already written by the agent (« 3 900 $ », « +22 % »).
    public var value = "", delta = "", unit = ""
    public var bars = false
    public var rows: [Row] = []
    public var text = ""
    public var expiresAt: Date?
    public var id: String { slot }

    public init(slot: String, order: Int = 5, kind: Kind, expiresAt: Date? = nil) {
        self.slot = slot; self.order = order; self.kind = kind; self.expiresAt = expiresAt
    }

    /// A block names its end; one without is not shown (the server always writes it).
    public func isExpired(at date: Date = .now) -> Bool { expiresAt.map { $0 <= date } ?? true }

    /// Places something rather than showing content of its own.
    public var isPlacement: Bool { kind == .meteo || kind == .affiche }

    init?(_ value: JSONValue) {
        func clean(_ text: String, _ limit: Int) -> String {
            String(String(text.prefix(limit * 4)).split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(limit))
        }
        func number(_ value: JSONValue) -> Double? {
            guard case .number(let number) = value, number.isFinite, abs(number) < 1e12 else { return nil }
            return number
        }
        let card = value["card"]
        let slot = clean(value["slot"].string, 24)
        guard !slot.isEmpty, let kind = Kind(rawValue: card["type"].string) else { return nil }
        self.init(slot: slot, order: min(9, max(0, value["order"].int)), kind: kind, expiresAt: AgentBoard.date(value["expires_at"].string))
        title = clean(card["title"].string, 30); icon = clean(card["icon"].string, 40); ask = clean(card["ask"].string, 200)
        tone = clean(card["tone"].string, 10).lowercased()
        switch kind {
        case .metrics:
            metrics = card["items"].array.prefix(4).compactMap { row in
                let label = clean(row["label"].string, 20), value = clean(row["value"].string, 14)
                return label.isEmpty || value.isEmpty ? nil : Metric(label: label, value: value, delta: clean(row["delta"].string, 10), tone: clean(row["tone"].string, 10).lowercased())
            }
            if metrics.isEmpty { return nil }
        case .progress:
            rings = card["items"].array.prefix(3).compactMap { row in
                let label = clean(row["label"].string, 16)
                guard !label.isEmpty, let value = number(row["value"]), let goal = number(row["goal"]), goal > 0 else { return nil }
                return Ring(label: label, value: value, goal: goal, unit: clean(row["unit"].string, 6))
            }
            if rings.isEmpty { return nil }
        case .chart:
            points = card["points"].array.suffix(24).compactMap { row in number(row["value"]).map { Point(label: clean(row["label"].string, 8), value: $0) } }
            self.value = clean(card["value"].string, 14); delta = clean(card["delta"].string, 10); unit = clean(card["unit"].string, 4)
            bars = card["style"].string == "bar"
            if points.count < 2 { return nil }
        case .list:
            rows = card["items"].array.prefix(5).compactMap { row in
                let title = clean(row["title"].string, 40)
                return title.isEmpty ? nil : Row(title: title, subtitle: clean(row["subtitle"].string, 30), value: clean(row["value"].string, 14),
                                                 icon: clean(row["icon"].string, 40), tone: clean(row["tone"].string, 10).lowercased())
            }
            if rows.isEmpty { return nil }
        case .note:
            text = clean(card["text"].string, 140)
            if text.isEmpty { return nil }
        case .meteo, .affiche:
            break
        }
    }

    /// A profile's blocks as the server sends them: malformed ones dropped, one per slot, in the widget's order.
    static func list(_ value: JSONValue) -> [WidgetBlock] {
        var seen = Set<String>()
        return value.array.prefix(12).compactMap(WidgetBlock.init).filter { seen.insert($0.slot).inserted }
            .sorted { ($0.order, $0.slot) < ($1.order, $1.slot) }
    }
}
