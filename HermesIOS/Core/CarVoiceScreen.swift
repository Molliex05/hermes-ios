import Foundation

/// What the car's screen shows during a call (CarPlay's voice control template). Never the answer's text or a card:
/// Apple forbids text and images in answers at the wheel. Only the call's state, the agent's name and two buttons.
public enum CarVoiceScreen {
    /// CarPlay keeps at most five states per template.
    public enum State: String, CaseIterable, Sendable { case idle, listening, thinking, speaking, muted }

    /// `phase` is the call's Live Activity phase (`listening`, `thinking`, `speaking`, `waiting`, `paused`); nil, no call.
    public static func state(phase: String?, muted: Bool) -> State {
        guard let phase, phase != "paused" else { return .idle }
        if muted, phase != "speaking" { return .muted }
        return switch phase {
        case "thinking", "waiting": .thinking
        case "speaking": .speaking
        default: .listening
        }
    }

    /// The template shows the longest title that fits the car's screen.
    public static func titles(_ state: State, agent: String) -> [String] {
        let agent = agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Hermès" : agent
        return switch state {
        case .idle: ["Appeler \(agent)", "Appeler"]
        case .listening: ["\(agent) vous écoute", "Je vous écoute", "Écoute"]
        case .thinking: ["\(agent) réfléchit", "Un instant"]
        case .speaking: ["\(agent) vous répond", "Réponse"]
        case .muted: ["Micro coupé", "Muet"]
        }
    }
}

/// A place to drive to, opened in Plans on the car's screen.
public struct CarDestination: Equatable, Sendable {
    public let messageID: String
    public let url: URL

    /// Plans' driving route to a place: coordinates when the card has them, otherwise its name and address.
    static func drivingURL(to target: String, name: String) -> URL? {
        guard !target.isEmpty else { return nil }
        var parts = URLComponents(string: "https://maps.apple.com/")!
        parts.queryItems = [URLQueryItem(name: "daddr", value: target), URLQueryItem(name: "dirflg", value: "d")]
        if !name.isEmpty { parts.queryItems?.append(URLQueryItem(name: "q", value: name)) }
        return parts.url
    }

    static func drivingURL(to place: ChatCard.Place) -> URL? {
        let target = place.latitude.flatMap { lat in place.longitude.map { "\(lat),\($0)" } } ?? place.query
        return drivingURL(to: target, name: place.name.isEmpty ? place.address : place.name)
    }
}

extension VoiceCards {
    /// The newest reply of the call, if it gives one place and only one (the « En voiture » rule: a destination is a
    /// `places` card with a single place). A list of several places stays a question: the driver picks one by voice.
    public static func destination(in messages: [ChatMessage], before: Set<String>) -> CarDestination? {
        guard let shown = latest(in: messages, before: before) else { return nil }
        let places = shown.cards.compactMap { card -> [ChatCard.Place]? in
            guard card.complete, case .places(_, let items)? = ChatCard.parse(card.json) else { return nil }
            return items
        }
        guard places.count == 1, let only = places.first, only.count == 1, let url = CarDestination.drivingURL(to: only[0]) else { return nil }
        return CarDestination(messageID: shown.messageID, url: url)
    }
}
