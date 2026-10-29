import SwiftUI

/// How an agent looks and moves: one illustration style and one palette. Each profile has its own, so Hermès and Jarvis
/// are told apart at a glance in the header, the voice screen, lists and next to each reply.
struct AgentLook: Equatable, Codable, Hashable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case petals, aurora, prism, constellation, liquid
        var id: String { rawValue }
        var label: String {
            switch self {
            case .petals: "Pétales"
            case .aurora: "Aurore"
            case .prism: "Prisme"
            case .constellation: "Constellation"
            case .liquid: "Liquide"
            }
        }
    }

    enum Palette: String, Codable, CaseIterable, Identifiable {
        case ember, ocean, amethyst, jade, sun
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ember: "Braise"
            case .ocean: "Océan"
            case .amethyst: "Améthyste"
            case .jade: "Jade"
            case .sun: "Soleil"
            }
        }
        /// Light, main and deep shades, plus a companion hue for the styles that blend several lights.
        var light: Color {
            switch self {
            case .ember: Color(red: 0.97, green: 0.66, blue: 0.43)
            case .ocean: Color(red: 0.55, green: 0.88, blue: 0.98)
            case .amethyst: Color(red: 0.98, green: 0.68, blue: 0.85)
            case .jade: Color(red: 0.62, green: 0.95, blue: 0.78)
            case .sun: Color(red: 1.0, green: 0.88, blue: 0.45)
            }
        }
        var main: Color {
            switch self {
            case .ember: Color(red: 0.81, green: 0.29, blue: 0.19)
            case .ocean: Color(red: 0.18, green: 0.52, blue: 0.92)
            case .amethyst: Color(red: 0.6, green: 0.36, blue: 0.9)
            case .jade: Color(red: 0.13, green: 0.66, blue: 0.52)
            case .sun: Color(red: 0.95, green: 0.6, blue: 0.12)
            }
        }
        var deep: Color {
            switch self {
            case .ember: Color(red: 0.55, green: 0.21, blue: 0.17)
            case .ocean: Color(red: 0.12, green: 0.2, blue: 0.55)
            case .amethyst: Color(red: 0.28, green: 0.16, blue: 0.55)
            case .jade: Color(red: 0.05, green: 0.36, blue: 0.32)
            case .sun: Color(red: 0.66, green: 0.3, blue: 0.06)
            }
        }
        var companion: Color {
            switch self {
            case .ember: Color(red: 0.98, green: 0.45, blue: 0.55)
            case .ocean: Color(red: 0.55, green: 0.4, blue: 0.95)
            case .amethyst: Color(red: 0.35, green: 0.55, blue: 0.98)
            case .jade: Color(red: 0.4, green: 0.75, blue: 0.98)
            case .sun: Color(red: 0.98, green: 0.42, blue: 0.3)
            }
        }
    }

    var style: Style
    var palette: Palette

    /// The app's own mark: Hermès' flower in its ember colours.
    static let hermes = AgentLook(style: .petals, palette: .ember)

    /// A profile's look before anyone chooses: Hermès keeps the flower, Jarvis is an aurora; any other agent gets a style
    /// and a palette of its own from its name, the same on every launch.
    static func standard(for profile: String) -> AgentLook {
        switch profile.lowercased() {
        case "default", "noriven", "hermes", "hermès": return .hermes
        case "personnel", "jarvis": return AgentLook(style: .aurora, palette: .ocean)
        case "research": return AgentLook(style: .prism, palette: .jade)
        case "studio": return AgentLook(style: .liquid, palette: .amethyst)
        default:
            let seed = profile.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7FFF_FFFF }
            return AgentLook(style: Style.allCases[seed % Style.allCases.count], palette: Palette.allCases[(seed / 7) % Palette.allCases.count])
        }
    }
}

/// The looks chosen on this iPhone, per profile (the server does not need to know). Observed: a change shows everywhere.
@MainActor @Observable final class AgentLooks {
    static let shared = AgentLooks()
    private static let key = "agentLooks.v1"
    private var chosen: [String: AgentLook]

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        chosen = data.flatMap { try? JSONDecoder().decode([String: AgentLook].self, from: $0) } ?? [:]
    }

    func look(for profile: String) -> AgentLook { chosen[profile] ?? .standard(for: profile) }
    func isCustom(_ profile: String) -> Bool { chosen[profile] != nil }

    func set(_ look: AgentLook?, for profile: String) {
        chosen[profile] = look == AgentLook.standard(for: profile) ? nil : look
        if let data = try? JSONEncoder().encode(chosen) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension EnvironmentValues {
    /// The current agent's look: set by the chat for its profile; the app's own mark elsewhere.
    @Entry var agentLook: AgentLook = .hermes
}

/// The agent's small mark (next to a reply, in a list): its illustration, still.
struct AgentGlyph: View {
    var look: AgentLook?
    var size: CGFloat = 17
    var body: some View {
        OrbView(phase: .idle, animated: false, look: look, compact: true).frame(width: size, height: size)
    }
}
