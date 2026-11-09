import SwiftUI

/// Reads the model (including `transcript.running`, which changes with every streamed flush)
/// and hands plain values to `ChatHeader`. This body is a few property reads; the header itself
/// only re-renders when one of its values actually changes.
struct ChatHeaderContainer: View {
    let model: AppModel
    let compress: () -> Void
    let newChat: () -> Void
    let history: () -> Void
    let menu: () -> Void

    var body: some View {
        ChatHeader(
            model: model,
            title: model.selected?.title ?? "Nouvelle conversation",
            showsConnection: model.state != .connected && !model.demo,
            agentTitle: model.agent?.title ?? "Hermes",
            demo: model.demo,
            hasConversation: model.selected != nil,
            actionsDisabled: model.transcript.running || model.sending || model.voiceActive || model.state != .connected,
            hasUnread: model.hasUnread(profile: model.profile),
            running: model.transcript.running, activity: model.transcript.activityLabel,
            loading: model.chatStage == .loading, messageCount: model.transcript.messages.count,
            compress: compress, newChat: newChat, history: history, menu: menu
        ).equatable()
    }
}

struct ChatHeader: View, Equatable {
    let model: AppModel
    let title: String
    let showsConnection: Bool
    let agentTitle: String
    let demo: Bool
    let hasConversation: Bool
    let actionsDisabled: Bool
    let hasUnread: Bool
    /// A reply is running: the second line says what the agent is doing.
    let running: Bool
    let activity: String?
    /// The conversation's messages are on their way (`ChatStage.loading`): no « 0 message » meanwhile.
    let loading: Bool
    let messageCount: Int
    let compress: () -> Void
    let newChat: () -> Void
    let history: () -> Void
    let menu: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.title == rhs.title && lhs.showsConnection == rhs.showsConnection
            && lhs.agentTitle == rhs.agentTitle && lhs.demo == rhs.demo && lhs.hasConversation == rhs.hasConversation
            && lhs.actionsDisabled == rhs.actionsDisabled && lhs.hasUnread == rhs.hasUnread
            && lhs.running == rhs.running && lhs.activity == rhs.activity && lhs.loading == rhs.loading && lhs.messageCount == rhs.messageCount
    }

    var body: some View {
        // One fine bar: the menu, the conversation's title on one line with what the agent is doing under it, then the
        // conversation's actions and a new conversation. Its height never changes, so the transcript below never jumps.
        // The agent is switched from the composer.
        HStack(spacing: 2) {
            HeaderGlyph(symbol: "line.3.horizontal", label: "Menu", id: "app-navigation", badge: hasUnread, action: menu)
            // The same room as the second glyph on the right keeps the title centred.
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
            Spacer(minLength: 4)
            VStack(spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier("chat-title")
                    .contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: title)
                detailLine
            }.frame(minHeight: 44)
            Spacer(minLength: 4)
            conversationActions
            HeaderGlyph(symbol: "square.and.pencil", label: "Nouvelle conversation", id: "new-chat", tint: AppTheme.accent) { Haptics.select(); newChat() }
        }
        .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 4)
        .overlay(alignment: .bottom) { HeaderProgress(running: running) }
    }

    /// Branch, compress and the conversation list; the list alone while there is no conversation yet.
    @ViewBuilder private var conversationActions: some View {
        if hasConversation {
            AppMenu {
                AppMenuButton("Conversations", systemImage: "bubble.left.and.bubble.right") { history() }
                AppMenuButton("Créer une branche", systemImage: "arrow.triangle.branch") { Task { await model.branchConversation() } }
                AppMenuButton("Résumer le contexte", systemImage: "arrow.down.right.and.arrow.up.left") { compress() }
            } label: { HeaderGlyphLabel(symbol: "ellipsis", badge: false) }
                .disabled(actionsDisabled)
                .accessibilityLabel("Actions de la conversation")
        } else {
            HeaderGlyph(symbol: "bubble.left.and.bubble.right", label: "Conversations du profil actif", id: "quick-history", action: history)
        }
    }

    /// Under the title: the connection when it is down, what the agent does while it works, else the agent and the size of
    /// the conversation.
    @ViewBuilder private var detailLine: some View {
        if showsConnection {
            ConnectionIndicator(model: model).font(.caption2).lineLimit(1)
        } else if running {
            ShimmerText(text: activity ?? "Réfléchit…")
        } else {
            let detail = loading ? "Ouverture…" : hasConversation ? "\(agentTitle) · \(messageCount) message\(messageCount > 1 ? "s" : "")" : "Avec \(agentTitle)"
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityLabel(demo ? "Aperçu interactif" : "Connecté à Hermes")
                .accessibilityValue(detail)
                .accessibilityIdentifier("connection-status")
        }
    }
}

/// What the agent is doing, in the accent colour, with a light that passes over it.
private struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.orbsAsleep) private var asleep

    var body: some View {
        label
            .foregroundStyle(AppTheme.accent)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: asleep)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                        GeometryReader { geometry in
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.75), .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: geometry.size.width * 0.35)
                                .offset(x: -geometry.size.width * 0.35 + geometry.size.width * 1.35 * phase)
                        }
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                }
            }
            .contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: text)
    }

    private var label: some View { Text(text).font(.caption2.weight(.medium)).lineLimit(1) }
}

private struct HeaderGlyphLabel: View {
    let symbol: String
    var badge = false
    var tint: Color = .primary
    var body: some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .regular)).foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) {
                if badge {
                    Circle().fill(AppTheme.accent).frame(width: 8, height: 8).overlay(Circle().strokeBorder(AppTheme.background, lineWidth: 2))
                        .offset(x: -8, y: 9).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
    }
}

private struct HeaderGlyph: View {
    let symbol: String
    let label: String
    let id: String
    var badge = false
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) { HeaderGlyphLabel(symbol: symbol, badge: badge, tint: tint) }
            .buttonStyle(PressableStyle()).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}

/// The header's lower edge: a fine line at rest, a moving light while the agent works.
private struct HeaderProgress: View {
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.orbsAsleep) private var asleep

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(AppTheme.line.opacity(0.7)).frame(height: 0.5)
            if running {
                GeometryReader { geometry in
                    if reduceMotion {
                        Rectangle().fill(AppTheme.accent.opacity(0.5)).frame(height: 2)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: asleep)) { timeline in
                            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
                            let width = geometry.size.width * 0.38
                            LinearGradient(colors: [AppTheme.accent.opacity(0), AppTheme.accent, AppTheme.accent.opacity(0)], startPoint: .leading, endPoint: .trailing)
                                .frame(width: width, height: 2)
                                .offset(x: -width + (geometry.size.width + width) * phase)
                        }
                    }
                }.frame(height: 2).clipped().transition(.opacity)
            }
        }.frame(height: 2).animation(.easeInOut(duration: 0.3), value: running).allowsHitTesting(false)
    }
}
