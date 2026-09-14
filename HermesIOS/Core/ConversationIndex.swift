import Foundation

/// A display cache per profile. Hermes remains the source of truth.
struct ConversationIndex: Codable, Sendable {
    private var profiles: [String: [Conversation]]

    init(legacy: [Conversation] = []) {
        profiles = Dictionary(grouping: legacy, by: \.profile)
    }

    subscript(profile: String) -> [Conversation] { profiles[profile] ?? [] }

    mutating func update(_ rows: [Conversation], profile: String) {
        profiles[profile] = rows.filter { $0.profile == profile }
    }
}
