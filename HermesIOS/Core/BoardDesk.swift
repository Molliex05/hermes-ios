import Foundation

/// What an agent's widget is for. The two agents complement each other on the Home Screen: Jarvis keeps Maxime's day
/// (shifts, appointments, the weather), Hermès runs Noriven's desk (what needs fixing, the figures, the one thing to do).
public enum BoardRole: Equatable, Sendable {
    case day, desk

    public init(profile: String) {
        self = ["noriven", "default", "hermes", "hermès"].contains(profile.lowercased()) ? .desk : .day
    }

    /// The weather is the day's business; on the desk it was noise.
    public var showsWeather: Bool { self == .day }
}

/// The desk at a glance: the agent's lines sorted by urgency (to fix, to watch, the rest, in the agent's order within each),
/// and what that adds up to.
public struct BoardDesk: Equatable, Sendable {
    public enum Level: Int, Comparable, Sendable {
        case fix, watch, fine
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        public init(tone: String) {
            switch tone {
            case "negative": self = .fix
            case "warning": self = .watch
            default: self = .fine
            }
        }
    }

    public let items: [AgentBoard.Item]
    public let toFix: Int
    public let toWatch: Int

    public init(_ items: [AgentBoard.Item]) {
        self.items = Self.ranked(items) { $0.tone }
        toFix = items.filter { Level(tone: $0.tone) == .fix }.count
        toWatch = items.filter { Level(tone: $0.tone) == .watch }.count
    }

    /// Anything with a tone, by urgency, keeping the agent's order among equals.
    public static func ranked<T>(_ values: [T], tone: (T) -> String) -> [T] {
        values.enumerated().sorted { a, b in
            let (la, lb) = (Level(tone: tone(a.element)), Level(tone: tone(b.element)))
            return la == lb ? a.offset < b.offset : la < lb
        }.map(\.element)
    }

    /// The desk's overall state: the worst line wins.
    public var level: Level { toFix > 0 ? .fix : toWatch > 0 ? .watch : .fine }

    /// The large figure and its label: « 2 » « à régler », else « 3 » « à surveiller », else « ✓ » « Tout roule ».
    public var headline: (figure: String, label: String) {
        if toFix > 0 { return ("\(toFix)", "à régler") }
        if toWatch > 0 { return ("\(toWatch)", "à surveiller") }
        return ("✓", items.isEmpty ? "Rien à signaler" : "Tout roule")
    }

    /// The line under it: « + 3 à surveiller », or how many lines there are when nothing is wrong.
    public var subline: String {
        if toFix > 0, toWatch > 0 { return "+ \(toWatch) à surveiller" }
        if toFix == 0, toWatch == 0, !items.isEmpty { return items.count == 1 ? "1 point suivi" : "\(items.count) points suivis" }
        return ""
    }
}
