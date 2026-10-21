import SwiftUI
import AVFoundation

struct VoiceView: View {
    let app: AppModel
    let returnToChat: () -> Void
    @State private var conversation: VoiceConversation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var startedAt = Date()

    init(app: AppModel, returnToChat: @escaping () -> Void) {
        self.app = app; self.returnToChat = returnToChat
        _conversation = State(initialValue: VoiceConversation(app))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
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
                        if conversation.requiresStandardMode { standardModePrompt.padding(.top, 22) }
                        if let error = conversation.error { errorMessage(error).padding(.top, 20) }
                        else if let notice = conversation.notice { noticeMessage(notice).padding(.top, 20) }
                        Spacer(minLength: 24)
                    }.padding(.horizontal, 26).padding(.bottom, 8)
                        .frame(maxWidth: 620).frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                }.scrollIndicators(.hidden)
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
                    } label: {
                        Label(conversation.isLive ? "GPT-Live" : "Mode vocal", systemImage: "slider.horizontal.3")
                    }.disabled(app.demo).accessibilityIdentifier("voice-engine")
                }
            }
            // Like a phone call: the screen doesn't auto-lock, and locking it or leaving the app
            // keeps the call running in the background (UIBackgroundModes `audio`).
            .task { startedAt = Date(); UIApplication.shared.isIdleTimerDisabled = true; conversation.start() }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; conversation.pause() }
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
