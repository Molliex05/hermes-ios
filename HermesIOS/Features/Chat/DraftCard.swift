import SwiftUI

/// An email the agent wrote and saved as a Gmail draft: read it here, ask for a change, then open it in Gmail to send it
/// yourself. The agent has no way to send mail, and the card says so.
struct DraftCard: View {
    let draft: ChatCard.Draft
    @Environment(\.openURL) private var openURL
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    @State private var expanded = false
    @State private var asked: String?

    private static let drafts = URL(string: "https://mail.google.com/mail/u/0/#drafts")!
    private static let changes = ["Plus court", "Plus formel", "Plus chaleureux"]
    private var live: Bool { reply != nil && interactive && asked == nil }
    private var long: Bool { draft.body.count > 280 || draft.body.filter(\.isNewline).count > 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "envelope.open.fill").font(.caption.weight(.bold)).foregroundStyle(AppTheme.accent)
                Text("Brouillon à relire").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !draft.to.isEmpty { field("À", draft.to) }
                if !draft.cc.isEmpty { field("Cc", draft.cc) }
                if !draft.subject.isEmpty { Text(draft.subject).font(.headline).fixedSize(horizontal: false, vertical: true).padding(.top, 2) }
            }
            if !draft.body.isEmpty {
                Text(draft.body).font(.subheadline).lineLimit(expanded ? nil : 6).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AppTheme.line))
                if long {
                    Button(expanded ? "Réduire" : "Tout voir") { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }
                        .font(.caption.weight(.semibold)).buttonStyle(.plain).foregroundStyle(AppTheme.accent)
                }
            }
            FlowLayout(spacing: 8) {
                Button { Haptics.select(); openURL(draft.url ?? Self.drafts) } label: {
                    Label("Ouvrir dans Gmail", systemImage: "arrow.up.right.square").font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8).foregroundStyle(.white).background(AppTheme.accent, in: Capsule())
                }.buttonStyle(PressableStyle())
                ForEach(Self.changes, id: \.self) { change in
                    Button {
                        guard live, let reply, reply.send("\(change) pour ce brouillon.") else { return }
                        Haptics.send(); asked = change
                    } label: {
                        Text(asked == change ? "\(change) · demandé" : change).font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .foregroundStyle(AppTheme.accent).background(AppTheme.accent.opacity(0.12), in: Capsule())
                    }.buttonStyle(PressableStyle()).disabled(!live).opacity(live || asked == change ? 1 : 0.5)
                }
            }
            Text("Rien n’est envoyé : c’est vous qui envoyez, depuis Gmail.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14).cardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card-draft")
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
            Text(value).font(.subheadline).lineLimit(2)
        }
    }
}
