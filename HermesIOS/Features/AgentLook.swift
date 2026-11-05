import SwiftUI

/// How an agent looks and moves: a small neural network of points with its own personality (layout and motion) and
/// palette. Each profile has its own, so Hermès and Jarvis are told apart at a glance in the header, the voice screen,
/// lists and next to each reply.
struct AgentLook: Equatable, Codable, Hashable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case flower, sphere, spiral, cluster, layers, lattice
        var id: String { rawValue }
        var label: String {
            switch self {
            case .flower: "Fleur"
            case .sphere: "Sphère"
            case .spiral: "Spirale"
            case .cluster: "Nuée"
            case .layers: "Couches"
            case .lattice: "Treillis"
            }
        }
    }

    /// Soft colours that sit well on the app's sand background and next to its ember accent.
    enum Palette: String, Codable, CaseIterable, Identifiable {
        case ember, ink, sage, plum, ochre, clay
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ember: "Braise"
            case .ink: "Encre"
            case .sage: "Sauge"
            case .plum: "Prune"
            case .ochre: "Ocre"
            case .clay: "Argile"
            }
        }
        var light: Color {
            switch self {
            case .ember: Color(red: 0.97, green: 0.66, blue: 0.43)
            case .ink: Color(red: 0.79, green: 0.83, blue: 0.88)
            case .sage: Color(red: 0.81, green: 0.88, blue: 0.79)
            case .plum: Color(red: 0.93, green: 0.78, blue: 0.83)
            case .ochre: Color(red: 0.96, green: 0.86, blue: 0.65)
            case .clay: Color(red: 0.94, green: 0.79, blue: 0.71)
            }
        }
        var main: Color {
            switch self {
            case .ember: Color(red: 0.81, green: 0.29, blue: 0.19)
            case .ink: Color(red: 0.31, green: 0.39, blue: 0.51)
            case .sage: Color(red: 0.44, green: 0.58, blue: 0.45)
            case .plum: Color(red: 0.6, green: 0.31, blue: 0.43)
            case .ochre: Color(red: 0.78, green: 0.56, blue: 0.18)
            case .clay: Color(red: 0.71, green: 0.41, blue: 0.29)
            }
        }
        var deep: Color {
            switch self {
            case .ember: Color(red: 0.55, green: 0.21, blue: 0.17)
            case .ink: Color(red: 0.15, green: 0.2, blue: 0.29)
            case .sage: Color(red: 0.24, green: 0.35, blue: 0.27)
            case .plum: Color(red: 0.34, green: 0.16, blue: 0.25)
            case .ochre: Color(red: 0.48, green: 0.33, blue: 0.09)
            case .clay: Color(red: 0.42, green: 0.23, blue: 0.16)
            }
        }
    }

    var style: Style
    var palette: Palette

    /// The app's own mark: Hermès' neural flower in its ember colours.
    static let hermes = AgentLook(style: .flower, palette: .ember)

    /// A profile's look before anyone chooses: Hermès keeps the flower, Jarvis is a turning sphere of points; any other
    /// agent gets a personality and a palette of its own from its name, the same on every launch.
    static func standard(for profile: String) -> AgentLook {
        switch profile.lowercased() {
        case "default", "noriven", "hermes", "hermès": return .hermes
        case "personnel", "jarvis": return AgentLook(style: .sphere, palette: .ink)
        case "research": return AgentLook(style: .layers, palette: .sage)
        case "studio": return AgentLook(style: .cluster, palette: .plum)
        default:
            let seed = profile.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0x7FFF_FFFF }
            let styles: [Style] = [.spiral, .cluster, .layers, .lattice, .sphere]
            let palettes: [Palette] = [.sage, .plum, .ochre, .clay, .ink]
            return AgentLook(style: styles[seed % styles.count], palette: palettes[(seed / 7) % palettes.count])
        }
    }
}

/// The looks chosen on this iPhone, per profile (the server does not need to know). Observed: a change shows everywhere.
@MainActor @Observable final class AgentLooks {
    static let shared = AgentLooks()
    private static let key = "agentLooks.v2"
    private var chosen: [String: AgentLook]

    private init() {
        // Look by look: one this version does not know (a style since removed) is dropped, the others are kept.
        let data = UserDefaults.standard.data(forKey: Self.key)
        let stored = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        chosen = stored.compactMapValues { value in
            guard let entry = value as? [String: Any],                       // a field this version does not know changes nothing
                  let style = (entry["style"] as? String).flatMap(AgentLook.Style.init(rawValue:)),
                  let palette = (entry["palette"] as? String).flatMap(AgentLook.Palette.init(rawValue:)) else { return nil }
            return AgentLook(style: style, palette: palette)
        }
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
