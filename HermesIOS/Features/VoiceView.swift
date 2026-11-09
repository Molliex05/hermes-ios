import SwiftUI
import AVFoundation

struct VoiceView: View {
    let app: AppModel
    let returnToChat: () -> Void
    @State private var conversation: VoiceConversation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var startedAt = Date()
    @State private var interruption = VoiceInterruptionSetting.mode
    @State private var environment = VoiceEnvironmentSetting.mode
    /// The agent's replies already in the chat when the call started: their cards are not the call's.
    @State private var before: Set<String>?
    /// Natural height of the cards on screen and of the line above them: the cards shrink to fit what is left.
    @State private var cardsHeight: CGFloat = 0
    @State private var headHeight: CGFloat = 0

    init(app: AppModel, returnToChat: @escaping () -> Void) {
        self.app = app; self.returnToChat = returnToChat
        _conversation = State(initialValue: app.takeBackgroundCall() ?? VoiceConversation(app))
    }

    var body: some View {
        let shown = before.flatMap { VoiceCards.latest(in: app.transcript.messages, before: $0) }
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        Group {
                            if let shown { cardLayout(shown, viewport: geometry.size.height) }
                            else { callLayout }
                        }
                        .padding(.horizontal, shown == nil ? 26 : 16).padding(.bottom, 8)
                        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: shown?.messageID)
                        .frame(maxWidth: 620).frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height, alignment: shown == nil ? .center : .top)
                        .id(Self.top)
                    }.scrollIndicators(.hidden)
                    // A new card is read from its top, whatever was scrolled before.
                    .onChange(of: shown?.messageID) { _, _ in withAnimation { proxy.scrollTo(Self.top, anchor: .top) } }
                }
            }
            .background(AppTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { callControls }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .topBarTrailing) {
                    AppMenu {
                        AppMenuButton("GPT-Live · Stone · français") { conversation.chooseLive() }
                            .accessibilityIdentifier("voice-use-live")
                        AppMenuButton("Voix standard pour cet appel") { conversation.chooseStandard() }
                        // Where you are: a car's noise should neither cut the agent off nor pass for your voice.
                        AppMenuButton("Mode voiture (bruit de moteur)", systemImage: "car", selected: environment == .car) {
                            environment = environment == .car ? .auto : .car
                            VoiceEnvironmentSetting.set(environment)
                        }.accessibilityIdentifier("voice-car-mode")
                        AppMenuButton("Te couper la parole à la voix", systemImage: "waveform.badge.mic", selected: interruption == .auto) {
                            interruption = interruption == .auto ? .off : .auto
                            VoiceInterruptionSetting.set(interruption)
                        }.accessibilityIdentifier("voice-interruption")
                        AppMenuButton("Mode du micro (isolation de la voix)", systemImage: "mic.badge.plus") {
                            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
                        }
                    } label: {
                        Label(conversation.isLive ? "GPT-Live" : "Mode vocal", systemImage: "slider.horizontal.3")
                    }.disabled(app.demo).accessibilityIdentifier("voice-engine")
                }
            }
            // Like a phone call: the screen doesn't auto-lock, and locking it or leaving the app
            // keeps the call running in the background (UIBackgroundModes `audio`).
            .task {
                startedAt = Date(); UIApplication.shared.isIdleTimerDisabled = true
                if before == nil { before = conversation.cardsBefore ?? VoiceCards.snapshot(app.transcript.messages) }
                conversation.start()
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; conversation.pause() }
            // Hung up by voice, by the agent or from the Lock Screen: back to the chat, like the « Terminer » button.
            .onChange(of: conversation.hungUp) { _, ended in if ended { returnToChat() } }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                    conversation.systemInterrupted("L’audio a été interrompu. Réactivez le micro quand vous êtes prêt.")
                }
            }
            // Route changes (speaker, Bluetooth, headphones) are absorbed by the audio engine,
            // which rebuilds itself; only a route with no usable input/output pauses the call.
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .noSuitableRouteForCategory else { return }
                conversation.systemInterrupted("Aucune sortie audio utilisable. Réactivez le micro quand l’iPhone est prêt.")
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
                conversation.systemInterrupted("L’audio de l’iPhone a redémarré. Réactivez le micro pour reprendre.")
            }
        }.presentationBackground(AppTheme.background)
    }

    private static let top = "voice-top"
    /// The cards shrink down to this to fit the screen; below, the text would be too small to read at a glance.
    private static let smallestCard = 0.72

    /// No card: the orb takes the middle of the screen, the state under it.
    private var callLayout: some View {
        VStack(spacing: 0) {
            agentContext.padding(.top, 8)
            Spacer(minLength: 24)
            VoicePresence(conversation: conversation)
                .frame(maxWidth: typeSize.isAccessibilitySize ? 200 : 330)
                .aspectRatio(1, contentMode: .fit)
                .padding(.bottom, 18)
            VStack(spacing: 10) {
                Text(app.demo ? "Parlons simplement." : conversation.title)
                    .font(.system(.title, design: .serif)).tracking(-0.4)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .id(conversation.title).transition(.opacity)
                    .accessibilityAddTraits(.isHeader)
                if let hint = guidance {
                    Text(hint).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                }
                if conversation.inputMuted || conversation.phase == .paused { microphoneState.padding(.top, 2) }
            }.animation(.easeInOut(duration: 0.25), value: conversation.title)
            messages
            Spacer(minLength: 24)
        }
    }

    /// A card on screen: the orb and the state fold into one line at the top and the card gets the rest of the screen,
    /// shrunk if needed so all of it shows without touching the phone (driving).
    private func cardLayout(_ shown: VoiceCards.Shown, viewport: CGFloat) -> some View {
        let room = viewport - headHeight - 22
        let scale = cardsHeight > room && cardsHeight > 0 ? max(Self.smallestCard, room / cardsHeight) : 1
        return VStack(spacing: 0) {
            VStack(spacing: 12) {
                agentContext
                HStack(spacing: 14) {
                    VoicePresence(conversation: conversation).frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.demo ? "Parlons simplement." : conversation.title)
                            .font(.system(.title3, design: .serif)).lineLimit(2)
                            .contentTransition(.opacity).animation(.easeInOut(duration: 0.25), value: conversation.title)
                            .accessibilityAddTraits(.isHeader)
                        if let hint = guidance { Text(hint).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                    if conversation.inputMuted || conversation.phase == .paused { microphoneState }
                }
            }
            .padding(.top, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headHeight = $0 }
            VoiceCardsPanel(shown: shown)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardsHeight = $0 }
                .scaleEffect(scale, anchor: .top)
                .frame(height: cardsHeight > 0 ? cardsHeight * scale : nil, alignment: .top)
                .padding(.top, 14)
            messages
        }
    }

    @ViewBuilder private var messages: some View {
        if conversation.requiresStandardMode { standardModePrompt.padding(.top, 22) }
        if let error = conversation.error { errorMessage(error).padding(.top, 20) }
        else if let notice = conversation.notice { noticeMessage(notice).padding(.top, 20) }
    }

    /// Agent and call time: the only text besides the state, so the screen stays calm.
    private var agentContext: some View {
        HStack(spacing: 10) {
            AgentAvatar(name: app.profile, size: 28)
            Text(app.agent?.title ?? "Hermes").font(.subheadline.weight(.medium))
            if !app.demo {
                TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                    let seconds = max(0, Int(timeline.date.timeIntervalSince(startedAt)))
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 14).padding(.vertical, 9)
            .background(AppTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AppTheme.line))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Conversation vocale avec \(app.agent?.title ?? "Hermes")")
    }

    /// A hint only when the call needs the person to do something; the state title says the rest.
    private var guidance: String? {
        if app.demo { return "Connectez votre Hermes pour parler avec votre agent." }
        if conversation.requiresStandardMode { return "Choisissez la voix standard pour cet appel." }
        if conversation.inputMuted { return "Vous pouvez continuer à écouter." }
        switch conversation.phase {
        case .waiting: return "Répondez dans le chat. La conversation reprendra ensuite."
        case .paused: return "Réactivez le micro quand vous êtes prêt."
        default: return nil
        }
    }

    private var microphoneState: some View {
        Label(conversation.inputMuted ? "Micro coupé" : "En pause",
              systemImage: conversation.inputMuted ? "mic.slash" : "pause.circle")
            .font(.caption.weight(.medium)).foregroundStyle(conversation.inputMuted ? AppTheme.accent : .secondary)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(AppTheme.accent.opacity(conversation.inputMuted ? 0.09 : 0.04), in: Capsule())
            .accessibilityIdentifier("voice-microphone-state")
    }

    private var standardModePrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GPT-Live n’est pas disponible pour cet appel. Vous pouvez réessayer depuis le menu vocal ou utiliser la voix standard.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Utiliser la voix standard") { conversation.chooseStandard() }
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                .accessibilityIdentifier("voice-standard-mode")
        }.padding(18).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func errorMessage(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").padding(.top, 2)
            Text(error).fixedSize(horizontal: false, vertical: true)
        }.font(.subheadline).foregroundStyle(AppTheme.accent)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine).accessibilityIdentifier("voice-error")
    }

    private func noticeMessage(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").padding(.top, 2)
            Text(notice).fixedSize(horizontal: false, vertical: true)
        }.font(.subheadline).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine).accessibilityIdentifier("voice-notice")
    }

    private var microphoneLabel: String {
        conversation.phase == .paused ? "Reprendre" : conversation.inputMuted ? "Activer le micro" : "Couper le micro"
    }

    private var callControls: some View {
        HStack(alignment: .top, spacing: 36) {
            Button { conversation.toggleMicrophone() } label: {
                VStack(spacing: 9) {
                    Image(systemName: conversation.inputMuted || conversation.phase == .paused ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .medium)).frame(width: 64, height: 64)
                        .foregroundStyle(conversation.inputMuted ? AppTheme.accent : .primary)
                        .background(conversation.inputMuted ? AppTheme.accent.opacity(0.1) : AppTheme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(AppTheme.line))
                    Text(typeSize.isAccessibilitySize ? "Micro" : microphoneLabel)
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
            }.accessibilityLabel(microphoneLabel).accessibilityIdentifier("voice-listen")
                .disabled(app.demo || conversation.requiresStandardMode)
            Button { conversation.pause(); returnToChat() } label: {
                VStack(spacing: 9) {
                    Image(systemName: "xmark").font(.system(size: 20, weight: .medium)).frame(width: 64, height: 64)
                        .foregroundStyle(.white).background(AppTheme.accent, in: Circle())
                    Text(typeSize.isAccessibilitySize ? "Fin" : "Terminer").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }.accessibilityLabel("Terminer et revenir au chat").accessibilityIdentifier("return-to-chat")
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .frame(maxWidth: 320).padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 14)
            .frame(maxWidth: .infinity).barBackground()
    }

}

/// The cards of the agent's newest reply during the call, to look at while talking. Nothing here sends a message: a quick
/// reply would land in the chat mid-call. A link opens in Safari and an event in Calendar; the call keeps running.
private struct VoiceCardsPanel: View {
    let shown: VoiceCards.Shown

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(shown.cards.enumerated()), id: \.offset) { _, card in
                RichCardView(json: card.json, complete: card.complete).equatable()
            }
        }
        .id(shown.messageID)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .environment(\.cardsInteractive, false)
        .environment(\.chatReply, nil)
        .environment(\.calendarEvent, nil)
        .environment(\.openURL, OpenURLAction { _ in .systemAction })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-cards")
    }
}

/// The call's orb, driven by the conversation (phase, mute, microphone level). Only this surface observes the level.
private struct VoicePresence: View {
    let conversation: VoiceConversation

    var body: some View {
        let phase = conversation.phase
        let active = ![.ready, .paused].contains(phase)
        let orbPhase: OrbPhase = switch phase {
        case .listening, .transcribing: active && !conversation.inputMuted ? .listening : .idle
        case .thinking, .waiting: .thinking
        case .speaking: .speaking
        default: .idle
        }
        OrbView(phase: orbPhase, level: conversation.level).allowsHitTesting(false)
    }
}
