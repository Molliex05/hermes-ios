import SwiftUI

/// Agent settings: pick the agent's illustration and colour; the chosen one moves, the others wait.
struct AgentLookSection: View {
    let profile: String
    private var looks: AgentLooks { .shared }

    var body: some View {
        let current = looks.look(for: profile)
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
                ForEach(AgentLook.Style.allCases) { style in
                    let candidate = AgentLook(style: style, palette: current.palette)
                    let selected = style == current.style
                    Button { Haptics.select(); looks.set(candidate, for: profile) } label: {
                        VStack(spacing: 6) {
                            OrbView(phase: .idle, animated: selected, breathesWhenIdle: true, look: candidate, compact: true)
                                .frame(width: 46, height: 46).padding(8)
                                .background(candidate.palette.main.opacity(selected ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(selected ? candidate.palette.main : .clear, lineWidth: 2))
                            Text(style.label).font(.caption2.weight(selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.6)
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.label).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 6)
            HStack(spacing: 10) {
                ForEach(AgentLook.Palette.allCases) { palette in
                    let selected = palette == current.palette
                    Button { Haptics.select(); looks.set(AgentLook(style: current.style, palette: palette), for: profile) } label: {
                        Circle().fill(LinearGradient(colors: [palette.light, palette.main, palette.deep], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 28, height: 28)
                            .overlay { if selected { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                            .padding(3)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.45 : 0), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(palette.label).accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer(minLength: 0)
                if looks.isCustom(profile) {
                    Button("Par défaut") { Haptics.select(); looks.set(nil, for: profile) }.font(.footnote.weight(.semibold)).buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Apparence")
        } footer: {
            Text("La personnalité de l’agent : son réseau de points et sa façon de bouger, dans l’en-tête, la conversation vocale, les listes et les réponses. Enregistré sur cet iPhone.").font(.footnote)
        }
        .accessibilityIdentifier("agent-look")
    }
}
