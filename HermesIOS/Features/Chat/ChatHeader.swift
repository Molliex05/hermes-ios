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
    /// The keyboard is up or the reader scrolled back through the history: the large title folds into the bar.
    var collapsed = false

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
            running: model.transcript.running, activity: model.transcript.activityLabel,
            // An empty conversation keeps the title folded: its greeting is the large title there.
            collapsed: collapsed || model.transcript.messages.isEmpty, messageCount: model.transcript.messages.count,
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
    let collapsed: Bool
    let messageCount: Int
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
            && lhs.running == rhs.running && lhs.activity == rhs.activity && lhs.collapsed == rhs.collapsed && lhs.messageCount == rhs.messageCount
    }

    var body: some View {
        // Editorial: a fine bar (menu, the agent, a new conversation) and the conversation's title set large, in the
        // app's serif, with a line that says what the agent is doing. The title folds into the bar when room is short.
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                HeaderGlyph(symbol: "line.3.horizontal", label: "Menu", id: "app-navigation", badge: hasUnread, action: menu)
                // Folded, the actions join the right side: the same room on the left keeps the agent centred.
                if collapsed { Color.clear.frame(width: 44, height: 44).accessibilityHidden(true) }
                Spacer(minLength: 4)
                agentChip
                Spacer(minLength: 4)
                if collapsed { conversationActions }
                HeaderGlyph(symbol: "square.and.pencil", label: "Nouvelle conversation", id: "new-chat", tint: AppTheme.accent) { Haptics.select(); newChat() }
            }
            if !collapsed {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: dynamicType.isAccessibilitySize ? 24 : 28, weight: .regular, design: .serif)).tracking(-0.6)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        detailLine
                        Spacer(minLength: 8)
                        conversationActions.padding(.trailing, -8).padding(.vertical, -8)     // full tap area, tight line
                    }
                }
                .padding(.leading, 12).padding(.trailing, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, collapsed ? 4 : 6)
        .overlay(alignment: .bottom) { HeaderProgress(running: running) }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: collapsed)
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

    /// Under the large title: the connection when it is down, what the agent does while it works, else the size of the conversation.
    @ViewBuilder private var detailLine: some View {
        if showsConnection {
            ConnectionIndicator(model: model).font(.footnote).lineLimit(1)
        } else if running {
            ShimmerText(text: activity ?? "Réfléchit…")
        } else {
            Text(hasConversation ? "\(messageCount) message\(messageCount > 1 ? "s" : "")" : "Avec \(agentTitle)")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityLabel(demo ? "Aperçu interactif" : "Connecté à Hermes")
                .accessibilityValue(hasConversation ? "\(messageCount) message\(messageCount > 1 ? "s" : "")" : "Avec \(agentTitle)")
                .accessibilityIdentifier("connection-status")
        }
    }

    /// The agent, in the middle of the bar: tap to switch. Folded, it also carries the conversation's title.
    private var agentChip: some View {
        Button { Haptics.select(); switchAgent() } label: {
            HStack(spacing: 7) {
                OrbView(phase: running ? .thinking : .idle, animated: running, compact: true).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(agentTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if collapsed {
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
                    }
                }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 10).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle()).accessibilityLabel("Changer d’agent : \(agentTitle)").accessibilityIdentifier("switch-profile")
    }
}

/// What the agent is doing, in the accent colour, with a light that passes over it.
private struct ShimmerText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label
            .foregroundStyle(AppTheme.accent)
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
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

    private var label: some View { Text(text).font(.footnote.weight(.medium)).lineLimit(1) }
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

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(AppTheme.line.opacity(0.7)).frame(height: 0.5)
            if running {
                GeometryReader { geometry in
                    if reduceMotion {
                        Rectangle().fill(AppTheme.accent.opacity(0.5)).frame(height: 2)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
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
