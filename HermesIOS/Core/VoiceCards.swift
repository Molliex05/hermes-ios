import Foundation

/// The cards to show on the voice screen: those of the newest agent reply given during the call. The voice reads only the
/// text; a card (an event, the weather, places, the news) stays on screen to look at while talking, until a newer reply
/// brings its own. Replies from before the call are recognised by their text, which survives the history being reloaded
/// (ids may not).
public enum VoiceCards {
    public struct Card: Equatable, Sendable { public let json: String, complete: Bool }
    public struct Shown: Equatable, Sendable { public let messageID: String, cards: [Card] }

    public static func latest(in messages: [ChatMessage], before: Set<String>) -> Shown? {
        for message in messages.reversed() where message.role == "assistant" && !before.contains(message.text) {
            guard message.text.contains("```") || message.text.contains("~~~") else { continue }
            let cards = ChatMarkdown.parse(message.text).compactMap { block -> Card? in
                if case .card(let json, let complete) = block { Card(json: json, complete: complete || !message.streaming) } else { nil }
            }
            if !cards.isEmpty { return Shown(messageID: message.id, cards: Array(cards.prefix(3))) }
        }
        return nil
    }

    /// What was already in the conversation when the call started.
    public static func snapshot(_ messages: [ChatMessage]) -> Set<String> {
        Set(messages.filter { $0.role == "assistant" }.map(\.text))
    }
}
