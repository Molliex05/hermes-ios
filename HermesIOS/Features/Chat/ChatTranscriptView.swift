import SwiftUI

/// The only chat view that reads `model.transcript`, so the only one invalidated by each stream
/// flush. Its body slices the transcript into small Equatable values: settled history, the
/// streaming message, activity, tools and request cards. Unchanged pieces skip their bodies.
struct ChatTranscriptView: View {
    let model: AppModel
    @Binding var pinnedToBottom: Bool
    @Binding var bottomVisible: Bool
    /// The header's title folds away once the reader is well up the conversation.
    @Binding var headerFolded: Bool
    @Binding var toolsExpanded: Bool
    let suggest: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Not observed: drag state and scroll throttling must not re-render anything.
    @State private var follower = ScrollFollower()
    /// The list's position, measured by SwiftUI from the real content size (not from a marker under estimated row heights).
    @State private var position = ScrollPosition(edge: .bottom)

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
        return ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                LazyVStack(alignment: .leading, spacing: 27) {
                    // Only the newest reply's cards still answer (quick replies, rows that send a message).
                    MessageHistory(messages: history, agent: agent, latestID: live == nil ? transcript.messages.last?.id : nil)
                    // Its own identity namespace: reusing the message id here would make the
                    // lazy stack keep this row once the message settles into the history, and
                    // a completed turn recovered in one batch would stay at its first token.
                    if let live { MessageView(message: live, agent: agent).equatable().id("live:" + live.id).environment(\.cardsInteractive, true) }
                    if let activity = transcript.activity, transcript.running {
                        ActivityRow(
                            title: transcript.activityLabel ?? activity,
                            sending: model.sending,
                            connected: model.state == .connected,
                            // Same rule as Transcript.isWaitingForResponse(at:), evaluated once
                            // per change; the row's timeline only compares dates.
                            waitingFrom: transcript.isWaitingForResponse(at: .distantFuture)
                                ? transcript.lastActivityAt.addingTimeInterval(15) : nil
                        ).equatable()
                    }
                    if !transcript.toolSteps.isEmpty {
                        ToolActivityView(steps: transcript.toolSteps, expanded: toolsExpanded, running: transcript.running) { toolsExpanded.toggle() }.equatable()
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
                    // Keeps the newest reply off the last row: a tall last row fell out of the accessibility tree.
                    Color.clear.frame(height: 1).padding(.top, -26).accessibilityHidden(true)
                }
            }.padding(.horizontal, 26).padding(.top, 14).frame(maxWidth: 720).frame(maxWidth: .infinity)   // the end row's spacing is the bottom margin
        }
        .scrollPosition($position)
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
        // The distance to the real end of the content, from the scroll view's own geometry. It drives following the stream
        // and putting the list back when it ends up past its end.
        .onScrollGeometryChange(for: Double.self) { geometry in
            ScrollGap.distanceFromEnd(contentHeight: geometry.contentSize.height, insetTop: geometry.contentInsets.top,
                                      insetBottom: geometry.contentInsets.bottom, contentOffset: geometry.contentOffset.y,
                                      container: geometry.containerSize.height)
        } action: { _, distance in
            scrolled(distance: distance)
        }
        .onChange(of: transcript.messages.count) { _, _ in
            if pinnedToBottom { follower.didScroll(); position.scrollTo(edge: .bottom) }
        }
        .onChange(of: model.selected?.storedID) { _, _ in position.scrollTo(edge: .bottom) }
        .overlay(alignment: .bottomTrailing) {
            if !pinnedToBottom {
                RoundButton(symbol: "arrow.down", label: "Dernier message") {
                    pinnedToBottom = true
                    follower.didScroll()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
                }.padding(18)
            }
        }
    }

    /// Runs whenever the scroll geometry changes. State is written only when a value flips, and following the stream goes
    /// through one throttled scroll (at most one per stream flush).
    private func scrolled(distance: Double) {
        follower.distance = distance
        let visible = distance <= 55
        if bottomVisible != visible { bottomVisible = visible }
        // Folds past 140 pt from the end, unfolds within 20: a glance up does not fold it, and the header's own change
        // of height (about 60 pt) cannot flip it back.
        // Only while reading up: a tall block arriving while following the stream must not fold the title and unfold it again.
        let fold = (!pinnedToBottom || follower.dragging) && (headerFolded ? distance > 20 : distance > 140)
        if headerFolded != fold { headerFolded = fold }
        if !follower.dragging, visible, !pinnedToBottom { pinnedToBottom = true }
        let target = $position
        if ScrollGap.isPastEnd(distance) { follower.heal { target.wrappedValue.scrollTo(edge: .bottom) } }
        guard pinnedToBottom, !follower.dragging, distance > 1 else { return }
        follower.follow { [pinnedBinding = $pinnedToBottom] in
            if pinnedBinding.wrappedValue { target.wrappedValue.scrollTo(edge: .bottom) }
        }
    }

}

/// Coalesces follow-the-stream scrolls to the stream's flush cadence (~30 fps).
@MainActor final class ScrollFollower {
    var dragging = false
    /// Last distance to the real end of the content (see `ScrollGap`).
    var distance = 0.0
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
            guard !self.dragging, ScrollGap.isPastEnd(self.distance) else { return }
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

/// Settled messages. Compared element-wise (cheap: unchanged strings share storage), so a
/// stream flush that only touches the live message skips this ForEach entirely. Not wrapped in
/// `.equatable()` so the lazy stack still sees one row per message.
private struct MessageHistory: View, Equatable {
    let messages: [ChatMessage]
    let agent: String
    let latestID: String?
    var body: some View {
        ForEach(messages) { message in
            MessageView(message: message, agent: agent)
                .equatable().id(message.id)
                .environment(\.cardsInteractive, message.id == latestID)
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
            // The agent's own network, thinking.
            OrbView(phase: .thinking, animated: !reduceMotion, compact: true).frame(width: 20, height: 20)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(sending ? "Transmission à Hermès…"
                     : connected && waitingFrom.map { context.date >= $0 } == true
                     ? "En attente de la réponse du modèle…" : title)
                    .lineLimit(2)
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.leading, 2)
    }
}

/// The tools the agent uses, as a timeline: one symbol per kind of tool, what it works on, its time. While the agent
/// works the last steps show by themselves; afterwards a compact summary opens the whole list.
private struct ToolActivityView: View, Equatable {
    let steps: [Transcript.ToolStep]
    let expanded: Bool
    let running: Bool
    let toggle: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.expanded == rhs.expanded && lhs.running == rhs.running && lhs.steps == rhs.steps }

    private var shown: [Transcript.ToolStep] { expanded ? steps : running ? Array(steps.suffix(3)) : [] }
    private var total: Double { steps.compactMap(\.duration).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { Haptics.select(); toggle() }) { summary }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Activité des outils")
                .accessibilityValue(expanded ? "Développée" : "Réduite")
                .accessibilityIdentifier("tool-activity")
            if !shown.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, step in
                        ToolStepRow(step: step, last: index == shown.count - 1)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                .padding(.top, 10).padding(.leading, 4)
            }
        }
        .animation(.snappy(duration: 0.3), value: steps)
        .animation(.snappy(duration: 0.3), value: expanded)
    }

    /// Stacked symbols of the tools used, how many, how long.
    private var summary: some View {
        HStack(spacing: 8) {
            HStack(spacing: -5) {
                ForEach(Array(Self.kinds(steps).prefix(4).enumerated()), id: \.offset) { _, symbol in
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(AppTheme.accent)
                        .frame(width: 22, height: 22)
                        .background(AppTheme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.25)))
                }
            }
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.primary.opacity(0.75)).contentTransition(.numericText())
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
        .background(AppTheme.surface.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(AppTheme.line))
        .frame(minHeight: 44)
    }

    private var label: String {
        let count = steps.count, tools = "\(count) outil\(count > 1 ? "s" : "")"
        if running && steps.contains(where: { $0.state == .running }) { return "\(tools) · en cours" }
        return total >= 0.05 ? "\(tools) · \(ToolStepRow.time(total))" : tools
    }

    /// The kinds of tools used, each once, most recent first.
    private static func kinds(_ steps: [Transcript.ToolStep]) -> [String] {
        var seen = Set<String>()
        return steps.reversed().map(\.symbol).filter { seen.insert($0).inserted }
    }
}

private struct ToolStepRow: View {
    let step: Transcript.ToolStep
    let last: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            VStack(spacing: 0) {
                Image(systemName: step.symbol).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint).accessibilityHidden(true)
                    .symbolEffect(.pulse, options: .repeating, isActive: step.state == .running && !reduceMotion)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.13), in: Circle())
                if !last { Rectangle().fill(AppTheme.line).frame(width: 1.5).frame(maxHeight: .infinity).padding(.vertical, 3) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.caption.weight(.semibold))
                if !step.context.isEmpty {
                    Text(step.context).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.top, 4).padding(.bottom, last ? 0 : 12)
            Spacer(minLength: 8)
            trailing.padding(.top, 5)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityValue(step.state == .completed ? "Terminé" : step.state == .stopped ? "Arrêté" : "En cours")
        .accessibilityIdentifier("tool-step")
    }

    @ViewBuilder private var trailing: some View {
        switch step.state {
        case .running:
            HStack(spacing: 6) {
                if let started = step.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.time(context.date.timeIntervalSince(started))).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                ProgressView().controlSize(.mini).accessibilityHidden(true)
            }
        case .completed:
            HStack(spacing: 5) {
                if let duration = step.duration { Text(Self.time(duration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(CardPalette.positive).accessibilityHidden(true)
            }
        case .stopped:
            // The row's value already says it.
            Text("Arrêté").font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private var tint: Color { step.state == .stopped ? .secondary : AppTheme.accent }

    /// « 0,4 s », « 4,1 s », « 12 s », « 1 min 05 ».
    static func time(_ seconds: Double) -> String {
        if seconds < 10 { return seconds.formatted(.number.precision(.fractionLength(1))) + " s" }
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(String(format: "%02d", whole % 60))"
    }
}

/// Warm, empty home of a conversation: the orb, a greeting and three ways to begin.
/// Equal while the agent is the same, so transcript changes never re-render it.
struct EmptyChatView: View, Equatable {
    let suggest: (String) -> Void
    var agentName = "default"
    var agentTitle = "Hermes"
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                            .scaleEffect(appeared || reduceMotion ? 1 : 0.8).opacity(appeared || reduceMotion ? 1 : 0)
                            .animation(.spring(response: 0.7, dampingFraction: 0.78), value: appeared)
                        Text(greeting).font(.system(size: 34, weight: .regular, design: .serif)).tracking(-0.8)
                            .opacity(appeared || reduceMotion ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 10)
                            .animation(.easeOut(duration: 0.5).delay(0.12), value: appeared)
                        Text("Que puis-je faire pour vous ?").font(.title3).foregroundStyle(.secondary)
                            .opacity(appeared || reduceMotion ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 10)
                            .animation(.easeOut(duration: 0.5).delay(0.2), value: appeared)
                    }.multilineTextAlignment(.center)
                    Spacer(minLength: 24)
                    VStack(spacing: 10) {
                        ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
                            suggestion(idea)
                                .opacity(appeared || reduceMotion ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 18)
                                .animation(.spring(response: 0.55, dampingFraction: 0.82).delay(0.28 + 0.08 * Double(index)), value: appeared)
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 10)
                    .frame(minHeight: geometry.size.height).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively).scrollBounceBehavior(.basedOnSize)
        }.onAppear { appeared = true }
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
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AppTheme.line))
                .softShadow(0.7)
        }.buttonStyle(PressableStyle())
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.orbsAsleep) private var asleep

    var body: some View {
        let dark = scheme == .dark
        // A slow back-and-forth every 18 s, redrawn 10 times a second at most, and not at all behind a page or with reduced motion.
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion || asleep)) { timeline in
            let drift = reduceMotion ? 0 : 0.5 - 0.5 * cos(timeline.date.timeIntervalSinceReferenceDate / 9 * .pi)
            ZStack {
                AppTheme.background
                RadialGradient(colors: [AppTheme.accent.opacity(dark ? 0.30 : 0.18), .clear], center: .init(x: 0.10 + 0.20 * drift, y: 1.0), startRadius: 0, endRadius: 520)
                RadialGradient(colors: [Color(red: 0.95, green: 0.62, blue: 0.35).opacity(dark ? 0.14 : 0.16), .clear], center: .init(x: 1.0 - 0.15 * drift, y: 0.9), startRadius: 0, endRadius: 380)
                RadialGradient(colors: [Color(red: 0.42, green: 0.45, blue: 0.75).opacity(dark ? 0.10 : 0.07), .clear], center: .init(x: 0.85, y: 0.0), startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        }
        .accessibilityHidden(true)
    }
}

struct MessageView: View, Equatable {
    let message: ChatMessage
    let agent: String
    private var user: Bool { message.role == "user" }
    /// What Copy and Share give: your own words as typed; a reply with its cards turned into readable lines.
    private var copyText: String { user ? message.text : ChatCard.plainText(message.text) }
    /// Your bubble keeps a small corner at its tail, like a speech bubble.
    private static let bubble = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 7, topTrailingRadius: 22, style: .continuous)
    var body: some View {
        HStack(alignment: .top) {
            if user { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 10) {
                if !user {
                    HStack(spacing: 8) { AgentGlyph(size: 17); Text(agent).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Group {
                    if user { Text(verbatim: message.text).lineSpacing(4) }
                    else { MarkdownText(text: message.text, cacheKey: message.id.isEmpty ? nil : message.id, settled: !message.streaming) }
                }
                    .textSelection(.enabled)
                    .padding(user ? 17 : 0)
                    .background(user ? AppTheme.userBubble : .clear, in: Self.bubble)
                    .overlay(Self.bubble.strokeBorder(user ? AppTheme.userBubbleLine : .clear))
                if message.delivery != .confirmed {
                    Text(message.delivery == .sending ? "Envoi…" : message.delivery == .uncertain ? "Réception à vérifier dans l’historique" : "Non envoyé · copiez pour réessayer")
                        .font(.caption2).foregroundStyle(message.delivery == .sending ? Color.secondary : AppTheme.accent)
                }
                if !user && !message.streaming {
                    // Pages the reply points to, as previews (the agent need not do anything for these).
                    let links = message.text.contains("http") ? ChatCard.links(in: message.text, limit: 2) : []
                    if !links.isEmpty {
                        VStack(spacing: 8) { ForEach(links, id: \.self) { LinkPreviewRow(url: $0) } }
                    }
                    let plain = ChatCard.plainText(message.text)
                    if !plain.isEmpty { MessageActions(text: plain) }
                }
            }
            if !user { Spacer(minLength: 5) }
        }
        .appContextMenu {
            AppMenuButton("Copier", systemImage: "doc.on.doc") { UIPasteboard.general.string = copyText }
            ShareLink(item: copyText) {
                AppMenuLabel(title: "Partager", systemImage: "square.and.arrow.up").padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            }.buttonStyle(.plain)
        }
        // A reply keeps its buttons reachable (cards, link previews, copy and share); a message you sent reads as one element.
        .accessibilityElement(children: user ? .combine : .contain)
        .accessibilityIdentifier(user ? "user-message" : "assistant-message")
    }
}

/// Copy and share under a finished reply: always at hand, never in the way.
private struct MessageActions: View {
    let text: String
    @State private var copied = false
    var body: some View {
        HStack(spacing: 2) {
            Button {
                UIPasteboard.general.string = text; Haptics.select(); copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
                    .frame(width: 34, height: 30).contentShape(Rectangle())
            }.accessibilityLabel(copied ? "Copié" : "Copier la réponse")
            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up").frame(width: 34, height: 30).contentShape(Rectangle())
            }.accessibilityLabel("Partager la réponse")
        }
        .font(.footnote.weight(.medium)).foregroundStyle(.secondary).buttonStyle(.plain)
        .padding(.leading, -8)
        .task(id: copied) { if copied { try? await Task.sleep(for: .seconds(1.6)); if !Task.isCancelled { copied = false } } }
    }
}
