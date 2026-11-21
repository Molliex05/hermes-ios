import Foundation

/// When an agent calls Maxime (the call it planned around his shifts), what the answered call may do, and the short
/// briefing the iPhone itself says when it may not reach the agent. Pure: the CallKit side only applies it.
public enum AgentCallPlan {
    /// How an answered call goes on.
    public enum Mode: Equatable, Sendable {
        /// Live with the agent at once: the sound goes through the car (paired, as `CarCallIntent` already trusts), or the
        /// iPhone is unlocked.
        case conversation
        /// The iPhone is locked and not in the car: the iPhone says the briefing itself, and the agent (who reads mail and
        /// the calendar) is reached only once Face ID has unlocked it.
        case briefing
    }

    public static func mode(carAudio: Bool, unlocked: Bool) -> Mode { carAudio || unlocked ? .conversation : .briefing }

    /// How long the phone rings before the call counts as missed.
    public static let ringSeconds: TimeInterval = 40
    /// How long a briefing call waits for Face ID before it hangs up.
    public static let unlockWaitSeconds: TimeInterval = 60

    /// The first turn sent to the agent when the call becomes a conversation: it speaks first, with the reason it called.
    /// `noriven`: Hermès's desk as the widget holds it (`deskLine`), so Jarvis can say it without reaching Hermès.
    public static func opening(reason: String, noriven: String? = nil) -> String {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let desk = noriven.map { " Côté Noriven, selon le tableau d’Hermès : \($0)." } ?? ""
        // Without the last sentence the agent said « As-tu besoin d'autre chose ? » and hung up in the same reply.
        return "(Tu m’appelles\(why.isEmpty ? "" : " : \(why)"). J’ai décroché : donne-moi le topo, court, puis demande si j’ai besoin d’autre chose. Ne raccroche pas avant ma réponse.\(desk))"
    }

    /// The briefing the iPhone says (and writes in the missed-call notification) from what it already holds: the agent's
    /// reason, the next event of the day, the weather, the desk's state, the week's payslip. Never mail or amounts.
    public static func briefing(agent: String, reason: String, next: AgentBoard.Item?, weather: WeatherReport?,
                                desk: BoardDesk?, pay: String?) -> String {
        var parts: [String] = []
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !why.isEmpty { parts.append(sentence(why)) }
        if let next {
            let at = next.time.isEmpty ? "" : " à \(spokenTime(next.time))"
            parts.append(sentence("\(next.text)\(at)"))
        }
        if let weather { parts.append(sentence("\(weather.temp)°, \(weather.summary.lowercased())")) }
        if let desk, desk.level != .fine {
            parts.append(sentence(desk.toFix > 0 ? "Noriven : \(desk.toFix) \(desk.toFix == 1 ? "chose" : "choses") à régler"
                                                 : "Noriven : \(desk.toWatch) à surveiller"))
        }
        if let pay, !pay.isEmpty { parts.append(sentence(pay)) }
        if parts.isEmpty { parts.append("Rien de particulier aujourd’hui.") }
        return parts.joined(separator: " ")
    }

    /// Hermès's desk in a few words for the call: « 2 à régler, 3 à surveiller », « rien à signaler »; nil without a board.
    public static func deskLine(_ desk: BoardDesk?) -> String? {
        guard let desk else { return nil }
        if desk.level == .fine { return "rien à signaler" }
        return [desk.toFix > 0 ? "\(desk.toFix) à régler" : nil, desk.toWatch > 0 ? "\(desk.toWatch) à surveiller" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// Said after the briefing on a locked iPhone.
    public static func unlockPrompt(agent: String) -> String { "Déverrouille ton iPhone pour parler à \(agent)." }

    /// « 14:30 » → « 14 h 30 », « 9:00 » → « 9 h », so the voice reads it well.
    static func spokenTime(_ text: String) -> String {
        guard let match = text.firstMatch(of: /^(\d{1,2})\s*[:hH]\s*(\d{2})?$/) else { return text }
        let minutes = match.2.map(String.init) ?? "00"
        return minutes == "00" ? "\(Int(match.1) ?? 0) h" : "\(Int(match.1) ?? 0) h \(minutes)"
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        let capital = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        return ".!?".contains(last) ? capital : capital + "."
    }
}
