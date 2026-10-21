import SwiftUI

/// Reads the model (including `transcript.running`, which changes with every streamed flush)
/// and hands plain values to `ChatHeader`. This body is a few property reads; the header itself
/// only re-renders when one of its values actually changes.
struct ChatHeaderContainer: View {
    let model: AppModel
    let compress: () -> Void
    let newChat: () -> Void
    let switchAgent: () -> Void
    let history: () -> Void
    let menu: () -> Void

    var body: some View {
        ChatHeader(
            model: model,
            title: model.selected?.title ?? "Nouvelle conversation",
            showsConnection: model.state != .connected && !model.demo,
            agentTitle: model.agent?.title ?? "Hermes",
            connectionName: model.activeConnection?.name ?? (model.demo ? "Aperçu interactif" : ""),
            demo: model.demo,
            hasConversation: model.selected != nil,
            actionsDisabled: model.transcript.running || model.sending || model.voiceActive || model.state != .connected,
            hasUnread: model.hasUnread(profile: model.profile), agentName: model.agent?.name ?? "default",
            running: model.transcript.running, activity: model.transcript.activity,
            compress: compress, newChat: newChat, switchAgent: switchAgent, history: history, menu: menu
        ).equatable()
    }
}

struct ChatHeader: View, Equatable {
    let model: AppModel
    let title: String
    let showsConnection: Bool
    let agentTitle: String
    let connectionName: String
    let demo: Bool
    let hasConversation: Bool
    let actionsDisabled: Bool
    let hasUnread: Bool
    let agentName: String
    /// A reply is running: the orb works and the second line says what the agent is doing.
    let running: Bool
    let activity: String?
    let compress: () -> Void
    let newChat: () -> Void
    let switchAgent: () -> Void
    let history: () -> Void
    let menu: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicType

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.title == rhs.title && lhs.showsConnection == rhs.showsConnection
            && lhs.agentTitle == rhs.agentTitle && lhs.connectionName == rhs.connectionName && lhs.demo == rhs.demo && lhs.hasConversation == rhs.hasConversation
            && lhs.actionsDisabled == rhs.actionsDisabled && lhs.hasUnread == rhs.hasUnread && lhs.agentName == rhs.agentName
            && lhs.running == rhs.running && lhs.activity == rhs.activity
    }

    var body: some View {
        // Menu on the left, the agent in the middle, the conversation actions on the right: one thing per place.
        // The conversation list lives in the menu (Conversations); its unread dot rides on the menu button.
        HStack(spacing: 8) {
            HeaderCircle(symbol: "line.3.horizontal", label: "Menu", id: "app-navigation", badge: hasUnread, action: menu)
            agentCapsule.frame(maxWidth: .infinity)
            if hasConversation {
                AppMenu {
                    AppMenuButton("Conversations", systemImage: "bubble.left.and.bubble.right") { history() }
                    AppMenuButton("Créer une branche", systemImage: "arrow.triangle.branch") { Task { await model.branchConversation() } }
                    AppMenuButton("Résumer le contexte", systemImage: "arrow.down.right.and.arrow.up.left") { compress() }
                } label: { HeaderCircleLabel(symbol: "ellipsis", badge: false) }
                    .disabled(actionsDisabled)
                    .accessibilityLabel("Actions de la conversation")
            } else {
                HeaderCircle(symbol: "bubble.left.and.bubble.right", label: "Conversations du profil actif", id: "quick-history", action: history)
            }
            HeaderCircle(symbol: "square.and.pencil", label: "Nouvelle conversation", id: "new-chat", tint: AppTheme.accent) { Haptics.select(); newChat() }
        }.padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 10)
    }

    /// The agent, as a pill: tap to switch. The conversation (or the connection) is its second line.
    private var agentCapsule: some View {
        Button { Haptics.select(); switchAgent() } label: {
            HStack(spacing: 9) {
                OrbView(phase: running ? .thinking : .idle, animated: running).frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agentTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if showsConnection {
                        ConnectionIndicator(model: model).font(.caption2).lineLimit(1)
                    } else if running {
                        Text(activity ?? "Réfléchit…").font(.caption2).foregroundStyle(AppTheme.accent).lineLimit(1)
                            .contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: activity)
                    } else {
                        Text(hasConversation ? title : connectionName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            .accessibilityLabel(demo ? "Aperçu interactif" : "Connecté à Hermes")
                            .accessibilityIdentifier("connection-status")
                    }
                }.frame(alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }.padding(.leading, 8).padding(.trailing, 12).frame(minHeight: 44)
                .background(AppTheme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(AppTheme.line))
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel("Changer d’agent : \(agentTitle)").accessibilityIdentifier("switch-profile")
    }
}

private struct HeaderCircleLabel: View {
    let symbol: String
    var badge = false
    var tint: Color = .primary
    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(AppTheme.surface, in: Circle())
            .overlay(Circle().strokeBorder(AppTheme.line))
            .overlay(alignment: .topTrailing) {
                if badge { Circle().fill(AppTheme.accent).frame(width: 9, height: 9).overlay(Circle().strokeBorder(AppTheme.background, lineWidth: 2)).accessibilityHidden(true) }
            }
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}

private struct HeaderCircle: View {
    let symbol: String
    let label: String
    let id: String
    var badge = false
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) { HeaderCircleLabel(symbol: symbol, badge: badge, tint: tint) }
            .buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
    }
}
