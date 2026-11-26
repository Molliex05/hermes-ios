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
    public static func opening(reason: String) -> String {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        // Without the last sentence the agent said « As-tu besoin d'autre chose ? » and hung up in the same reply.
        return "(Tu m’appelles\(why.isEmpty ? "" : " : \(why)"). J’ai décroché : donne-moi le topo, court, puis demande si j’ai besoin d’autre chose. Ne raccroche pas avant ma réponse.)"
    }

    /// The words the agent prepared before calling (« Bonjour monsieur, … »), said the moment the call is answered, and the
    /// note that leads Maxime's first answer so the agent knows what it already said. Nil when nothing was prepared: the
    /// agent then speaks first through `opening`.
    public static func greeting(reason: String, script: String) -> (text: String, context: String)? {
        let text = script.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, "(Tu m’as appelé\(why.isEmpty ? "" : " : \(why)"). Dès que j’ai décroché, tu m’as dit : « \(text) » Voici ma réponse.)")
    }

    /// The briefing the iPhone says (and writes in the missed-call notification) from what it already holds: the agent's
    /// reason, the next event of the day, the weather, the week's payslip. Never mail or amounts, and never the other
    /// agent's business: Jarvis keeps Maxime's life, Hermès keeps Noriven.
    public static func briefing(agent: String, reason: String, next: AgentBoard.Item?, weather: WeatherReport?, pay: String?) -> String {
        var parts: [String] = []
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !why.isEmpty { parts.append(sentence(why)) }
        if let next {
            let at = next.time.isEmpty ? "" : " à \(spokenTime(next.time))"
            parts.append(sentence("\(next.text)\(at)"))
        }
        if let weather { parts.append(sentence("\(weather.temp)°, \(weather.summary.lowercased())")) }
        if let pay, !pay.isEmpty { parts.append(sentence(pay)) }
        if parts.isEmpty { parts.append("Rien de particulier aujourd’hui.") }
        return parts.joined(separator: " ")
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
