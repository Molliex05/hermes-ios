import SwiftUI

/// The only chat view that reads `model.transcript`, so the only one invalidated by each stream
/// flush. Its body slices the transcript into small Equatable values: settled history, the
/// streaming message, activity, tools and request cards. Unchanged pieces skip their bodies.
struct ChatTranscriptView: View {
    let model: AppModel
    @Binding var pinnedToBottom: Bool
    @Binding var bottomVisible: Bool
    @Binding var toolsExpanded: Bool
    let suggest: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Not observed: drag state and scroll throttling must not re-render anything.
    @State private var follower = ScrollFollower()

    var body: some View {
        let transcript = model.transcript
        if transcript.messages.isEmpty && transcript.approval == nil && transcript.clarification == nil && transcript.credential == nil {
            // Opening a conversation with nothing cached: its shape, not the welcome suggestions.
            if model.opening && model.selected != nil { SkeletonBubbles() }
            else { EmptyChatView(suggest: suggest, agentName: model.agent?.name ?? "default", agentTitle: model.agent?.title ?? "Hermes").equatable() }
        } else {
            messages(transcript)
        }
    }

    private func messages(_ transcript: Transcript) -> some View {
        let agent = model.agent?.title ?? "Hermes"
        // The streamed message is rendered on its own; the history before it then compares equal
        // on every flush and the 500-row ForEach is not diffed again.
        let live = transcript.messages.last.flatMap { $0.streaming ? $0 : nil }
        let history = live == nil ? transcript.messages : Array(transcript.messages.dropLast())
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 27) {
                        // Reports where the content starts, so a blank band under the last row can be told from a short chat.
                        Color.clear.frame(height: 0).background(GeometryReader { marker in
                            Color.clear.preference(key: TopPreference.self, value: marker.frame(in: .named("chat-scroll")).minY)
                        })
                        LazyVStack(alignment: .leading, spacing: 27) {
                            MessageHistory(messages: history, agent: agent)
                            // Its own identity namespace: reusing the message id here would make the
                            // lazy stack keep this row once the message settles into the history, and
                            // a completed turn recovered in one batch would stay at its first token.
                            if let live { MessageView(message: live, agent: agent).equatable().id("live:" + live.id) }
                            if let activity = transcript.activity, transcript.running {
                                ActivityRow(
                                    title: activityTitle(activity, steps: transcript.toolSteps),
                                    sending: model.sending,
                                    connected: model.state == .connected,
                                    // Same rule as Transcript.isWaitingForResponse(at:), evaluated once
                                    // per change; the row's timeline only compares dates.
                                    waitingFrom: transcript.isWaitingForResponse(at: .distantFuture)
                                        ? transcript.lastActivityAt.addingTimeInterval(15) : nil
                                ).equatable()
                            }
                            if !transcript.toolSteps.isEmpty {
                                ToolActivityView(steps: transcript.toolSteps, expanded: toolsExpanded) { toolsExpanded.toggle() }.equatable()
                            }
                            if let failure = transcript.failure, !failure.isEmpty {
                                Label(failure, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(AppTheme.accent)
                            }
                            if let approval = transcript.approval {
                                ApprovalCard(payload: approval, model: model).equatable().id(approval["rpc_id"].string + approval["request_id"].string)
                            }
                            if let clarification = transcript.clarification, ClarificationCard.hasPendingQuestions(clarification) {
                                ClarificationCard(payload: clarification, model: model).equatable().id(clarification["rpc_id"].string + clarification["request_id"].string)
                            }
                            if let credential = transcript.credential {
                                CredentialCard(payload: credential, model: model).equatable().id(credential["rpc_id"].string + credential["request_id"].string)
                            }
                        }
                        // Outside the lazy stack so it always reports its position, even far from the end.
                        Color.clear.frame(height: 1).id("bottom").background(GeometryReader { marker in
                            Color.clear.preference(key: BottomPreference.self, value: marker.frame(in: .named("chat-scroll")).maxY)
                        })
                    }.padding(.horizontal, 26).padding(.top, 14).padding(.bottom, 20).frame(maxWidth: 720).frame(maxWidth: .infinity)
                }
                .coordinateSpace(name: "chat-scroll")
                .scrollDismissesKeyboard(.interactively)
                .chatScrollAnchors()
                .simultaneousGesture(DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        follower.dragging = true
                        if value.translation.height > 5, pinnedToBottom { pinnedToBottom = false }
                    }
                    .onEnded { _ in
                        follower.dragging = false
                        if bottomVisible, !pinnedToBottom { pinnedToBottom = true }
                    })
                .onPreferenceChange(TopPreference.self) { follower.top = $0 }
                .onPreferenceChange(BottomPreference.self) { y in
                    bottomMoved(y, height: geo.size.height, proxy: proxy)
                }
                .onChange(of: transcript.messages.count) { _, _ in
                    if pinnedToBottom {
                        follower.didScroll()
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !pinnedToBottom {
                        RoundButton(symbol: "arrow.down", label: "Dernier message") {
                            pinnedToBottom = true
                            follower.didScroll()
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }.padding(18)
                    }
                }
            }
        }
    }

    /// Runs after layout whenever the end marker moves. State is written only when a value
    /// flips, and following the stream goes through one throttled scroll (at most one per
    /// stream flush) instead of scrolling from both layout and text changes.
    private func bottomMoved(_ y: CGFloat, height: CGFloat, proxy: ScrollViewProxy) {
        follower.end = y; follower.viewport = height
        if ScrollGap.isBlank(contentTop: follower.top, endMarker: y, viewport: height) {
            follower.heal { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        let visible = y <= height + 55
        if bottomVisible != visible { bottomVisible = visible }
        var pinned = pinnedToBottom
        if !follower.dragging, visible, !pinned { pinnedToBottom = true; pinned = true }
        guard pinned, !follower.dragging, y > height + 1 else { return }
        follower.follow { [pinnedBinding = $pinnedToBottom] in
            if pinnedBinding.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func activityTitle(_ activity: String, steps: [Transcript.ToolStep]) -> String {
        guard let step = steps.last(where: { $0.name == activity }) else { return activity }
        return step.title + "…"
    }
}

/// Coalesces follow-the-stream scrolls to the stream's flush cadence (~30 fps).
@MainActor final class ScrollFollower {
    var dragging = false
    /// Last positions reported by the content's start and end markers, and the viewport height.
    var top = 0.0, end = 0.0, viewport = 0.0
    private var healing = false
    private var scheduled = false
    private var last = Date.distantPast
    private static let interval: TimeInterval = 1.0 / 30

    func didScroll() { last = Date() }

    /// Brings the list back to its end when it stays scrolled past it. Waits a moment and re-checks, so a normal
    /// overscroll bounce or a keyboard still moving never fights the user.
    func heal(_ scroll: @escaping @MainActor () -> Void) {
        guard !healing else { return }
        healing = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard let self else { return }
            self.healing = false
            guard !self.dragging, ScrollGap.isBlank(contentTop: self.top, endMarker: self.end, viewport: self.viewport) else { return }
            self.last = Date()
            scroll()
        }
    }

    func follow(_ scroll: @escaping @MainActor () -> Void) {
        guard !scheduled else { return }
        scheduled = true
        let wait = max(0, Self.interval - Date().timeIntervalSince(last))
        Task { @MainActor [weak self] in
            // Never scroll from inside the layout pass that reported the position.
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) } else { await Task.yield() }
            guard let self else { return }
            self.scheduled = false
            guard !self.dragging else { return }
            self.last = Date()
            scroll()
        }
    }
}

private struct TopPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct BottomPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Settled messages. Compared element-wise (cheap: unchanged strings share storage), so a
/// stream flush that only touches the live message skips this ForEach entirely. Not wrapped in
/// `.equatable()` so the lazy stack still sees one row per message.
private struct MessageHistory: View, Equatable {
    let messages: [ChatMessage]
    let agent: String
    var body: some View {
        ForEach(messages) { message in
            MessageView(message: message, agent: agent)
                .equatable().id(message.id)
        }
    }
}

private struct ActivityRow: View, Equatable {
    let title: String
    let sending: Bool
    let connected: Bool
    let waitingFrom: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.sending == rhs.sending && lhs.connected == rhs.connected && lhs.waitingFrom == rhs.waitingFrom
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkle")
                .foregroundStyle(AppTheme.accent)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(sending ? "Transmission à Hermès…"
                     : connected && waitingFrom.map { context.date >= $0 } == true
                     ? "En attente de la réponse du modèle…" : title)
                    .lineLimit(2)
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

private struct ToolActivityView: View, Equatable {
    let steps: [Transcript.ToolStep]
    let expanded: Bool
    let toggle: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.expanded == rhs.expanded && lhs.steps == rhs.steps }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text("\(steps.count) outil\(steps.count > 1 ? "s" : "") utilisé\(steps.count > 1 ? "s" : "")")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("Activité des outils")
                .accessibilityValue(expanded ? "Développée" : "Réduite").accessibilityIdentifier("tool-activity")
            if expanded {
                ForEach(steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: step.state == .completed ? "checkmark" : step.state == .stopped ? "minus" : "ellipsis")
                            .foregroundStyle(step.state == .running ? AppTheme.accent : .secondary)
                        Text(step.title)
                        Spacer(minLength: 8)
                        Text(step.state == .completed ? "Terminé" : step.state == .stopped ? "Arrêté" : "En cours")
                            .foregroundStyle(.secondary)
                    }.font(.caption).padding(.vertical, 5)
                }
            }
        }
    }
}

/// Warm, empty home of a conversation: the orb, a greeting and three ways to begin.
/// Equal while the agent is the same, so transcript changes never re-render it.
struct EmptyChatView: View, Equatable {
    let suggest: (String) -> Void
    var agentName = "default"
    var agentTitle = "Hermes"

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.agentName == rhs.agentName && lhs.agentTitle == rhs.agentTitle }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Bonjour"
        case 12..<18: "Bon après-midi"
        default: "Bonsoir"
        }
    }

    private struct Idea: Identifiable { let id: String; let title: String; let subtitle: String; let symbol: String; let prompt: String }

    private var ideas: [Idea] {
        let weather = Idea(id: "weather", title: "Météo du jour", subtitle: "Aujourd’hui et demain", symbol: "cloud.sun", prompt: "Quelle météo fait-il aujourd’hui et demain ?")
        let overview = Idea(id: "overview", title: "Faire le point", subtitle: "Ce qui compte aujourd’hui", symbol: "sun.max", prompt: "Aide-moi à faire le point et à choisir mes priorités pour aujourd’hui.")
        let third = agentName == "noriven"
            ? Idea(id: "noriven", title: "Où en est Noriven ?", subtitle: "Revenu, dépenses et profit du mois", symbol: "chart.bar", prompt: "Où en est Noriven ce mois-ci ? Donne-moi le revenu, les dépenses et le profit, et compare avec le mois dernier.")
            : Idea(id: "idea", title: "Explorer une idée", subtitle: "Laisser la curiosité faire son chemin", symbol: "sparkle", prompt: "J’ai une idée à explorer. Aide-moi à la préciser.")
        return [weather, overview, third]
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    VStack(spacing: 14) {
                        OrbView(phase: .idle, breathesWhenIdle: true).frame(width: 104, height: 104)
                        Text(greeting).font(.system(size: 34, weight: .regular, design: .serif)).tracking(-0.8)
                        Text("Que puis-je faire pour vous ?").font(.title3).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    Spacer(minLength: 24)
                    VStack(spacing: 8) {
                        ForEach(ideas) { idea in suggestion(idea) }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 10)
                    .frame(minHeight: geometry.size.height).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively).scrollBounceBehavior(.basedOnSize)
        }
    }

    private func suggestion(_ idea: Idea) -> some View {
        Button { Haptics.select(); suggest(idea.prompt) } label: {
            HStack(spacing: 14) {
                Image(systemName: idea.symbol).font(.system(size: 18, weight: .light)).foregroundStyle(AppTheme.accent).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(idea.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(idea.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }.padding(.horizontal, 16).padding(.vertical, 13)
                .background(AppTheme.surface.opacity(0.78), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AppTheme.line))
        }.buttonStyle(.plain)
    }
}

/// Behind the whole chat: the warm glow while the conversation is empty, the plain background afterwards.
/// A tiny body: it only reads whether there are messages.
struct ChatBackdrop: View {
    let model: AppModel
    var body: some View {
        let empty = model.transcript.messages.isEmpty
        ZStack {
            AppTheme.background
            if empty { AmbientBackground().transition(.opacity) }
        }.ignoresSafeArea().animation(.easeInOut(duration: 0.4), value: empty)
    }
}

/// A soft, warm glow behind the empty chat. Drawn once (no per-frame work); a very slow drift is the only motion.
struct AmbientBackground: View {
    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            AppTheme.background
            RadialGradient(colors: [AppTheme.accent.opacity(dark ? 0.30 : 0.18), .clear], center: .init(x: drift ? 0.30 : 0.10, y: 1.0), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.35).opacity(dark ? 0.14 : 0.16), .clear], center: .init(x: drift ? 0.85 : 1.0, y: 0.9), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Color(red: 0.42, green: 0.45, blue: 0.75).opacity(dark ? 0.10 : 0.07), .clear], center: .init(x: 0.85, y: 0.0), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
        .onAppear { guard !reduceMotion else { return }; withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true } }
        .accessibilityHidden(true)
    }
}

struct MessageView: View, Equatable {
    let message: ChatMessage
    let agent: String
    private var user: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .top) {
            if user { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 10) {
                if !user {
                    HStack(spacing: 8) { AgentMark(size: 17); Text(agent).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Group {
                    if user { Text(verbatim: message.text).lineSpacing(4) }
                    else { MarkdownText(text: message.text, cacheKey: message.id.isEmpty ? nil : message.id) }
                }
                    .textSelection(.enabled)
                    .padding(user ? 17 : 0)
                    .background(user ? AppTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 21))
                    .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(user ? AppTheme.line : .clear))
                if message.delivery != .confirmed {
                    Text(message.delivery == .sending ? "Envoi…" : message.delivery == .uncertain ? "Réception à vérifier dans l’historique" : "Non envoyé · copiez pour réessayer")
                        .font(.caption2).foregroundStyle(message.delivery == .sending ? Color.secondary : AppTheme.accent)
                }
            }
            if !user { Spacer(minLength: 5) }
        }
        .appContextMenu {
            AppMenuButton("Copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
            ShareLink(item: message.text) {
                AppMenuLabel(title: "Partager", systemImage: "square.and.arrow.up").padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            }.buttonStyle(.plain)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(user ? "user-message" : "assistant-message")
    }
}
