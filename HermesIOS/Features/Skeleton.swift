import SwiftUI

/// Placeholder rows with the shape of the real ones (avatar, title, detail) while Hermes data has
/// not arrived and nothing is cached. Only the first row speaks, as « Chargement ».
/// In a List each row is a list row; in a stack they simply stack.
struct SkeletonRows: View {
    var count = 4
    var avatar = true
    /// Rounded surface cards, as the conversation list draws its rows.
    var card = false

    private static let titles = ["Un titre de conversation", "Une idée à poursuivre", "Le point du matin", "Un projet en cours", "Une question ouverte", "Une note rapide"]
    private static let details = ["Un aperçu du dernier message reçu", "Quelques mots de contexte", "La suite de l’échange avec votre agent", "Un détail à reprendre plus tard"]

    var body: some View {
        ForEach(0..<count, id: \.self) { index in
            HStack(spacing: 13) {
                if avatar { RoundedRectangle(cornerRadius: 12).fill(AppTheme.line).frame(width: 38, height: 38) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.titles[index % Self.titles.count]).font(.subheadline.weight(.medium))
                    Text(Self.details[index % Self.details.count]).font(.caption)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, card ? 14 : 6).padding(.horizontal, card ? 14 : 0)
                .background(card ? AppTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 18))
                .redacted(reason: .placeholder).shimmering()
                .accessibilityElement(children: .ignore).accessibilityLabel("Chargement")
                .accessibilityHidden(index != 0)
        }
    }
}

/// Two or three message bubbles while a conversation without cached messages opens.
struct SkeletonBubbles: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 27) {
            Text("Une question posée à votre agent, en quelques mots.").font(.body)
                .padding(.horizontal, 17).padding(.vertical, 12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                Text("Hermes").font(.subheadline.weight(.medium))
                Text("Une réponse qui tient sur plusieurs lignes, avec le contexte utile et la suite à donner à l’échange.").font(.body)
            }
            Text("Une précision.").font(.body)
                .padding(.horizontal, 17).padding(.vertical, 12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(.horizontal, 24).padding(.top, 12)
            .frame(maxWidth: 750).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .redacted(reason: .placeholder).shimmering()
            .accessibilityElement(children: .ignore).accessibilityLabel("Chargement de la conversation")
    }
}

extension View {
    /// A soft light sweep over placeholders; still when Reduce Motion is on.
    func shimmering() -> some View { modifier(Shimmer()) }
}

private struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if reduceMotion { content }
        else {
            content
                .overlay {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, AppTheme.background.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geometry.size.width * 0.5)
                            .offset(x: phase * geometry.size.width * 1.5)
                    }.allowsHitTesting(false)
                }
                .mask(content)
                .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 } }
        }
    }
}
