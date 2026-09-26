import SwiftUI
import AVFoundation

struct VoiceView: View {
    let app: AppModel
    let returnToChat: () -> Void
    @State private var conversation: VoiceConversation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.toolNavigation) private var navigation
    @Environment(\.dynamicTypeSize) private var typeSize

    init(app: AppModel, returnToChat: @escaping () -> Void) {
        self.app = app; self.returnToChat = returnToChat
        _conversation = State(initialValue: VoiceConversation(app))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        agentContext.padding(.top, 12)
                        Spacer(minLength: 28)
                        VoicePresence(conversation: conversation)
                            .frame(width: typeSize.isAccessibilitySize ? 176 : 236,
                                   height: typeSize.isAccessibilitySize ? 176 : 236)
                            .padding(.bottom, 24)
                        VStack(spacing: 13) {
                            Text(app.demo ? "Parlons simplement." : conversation.title)
                                .font(.system(.largeTitle, design: .serif)).tracking(-0.7)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                            Text(guidance).font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 340)
                            microphoneState.padding(.top, 5)
                        }
                        if conversation.requiresStandardMode { standardModePrompt.padding(.top, 22) }
                        if let error = conversation.error { errorMessage(error).padding(.top, 20) }
                        Spacer(minLength: 28)
                        VoiceTranscriptPanel(conversation: conversation)
                    }.padding(.horizontal, 26).padding(.bottom, 16)
                        .frame(maxWidth: 620).frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                }.scrollIndicators(.hidden)
            }
            .background(AppTheme.background)
            .safeAreaInset(edge: .bottom, spacing: 0) { callControls }
            .navigationTitle("Voix").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let navigation {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { conversation.pause(); navigation.showSpaces() } label: {
                            Image(systemName: "circle.grid.2x2").frame(width: 44, height: 44)
                        }.foregroundStyle(.secondary).accessibilityLabel("Outils").accessibilityIdentifier("back-to-spaces")
                    }
                }
            }
            .task { conversation.start() }
            .onDisappear { conversation.pause() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { conversation.systemInterrupted("Le micro a été coupé en arrière-plan. Réactivez-le pour reprendre la conversation.") }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue {
                    conversation.systemInterrupted("L’audio a été interrompu. Réactivez le micro quand vous êtes prêt.")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                      [.oldDeviceUnavailable, .noSuitableRouteForCategory].contains(reason) else { return }
                conversation.systemInterrupted("La sortie audio a changé. Réactivez le micro pour continuer sur la nouvelle sortie.")
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
                conversation.systemInterrupted("L’audio de l’iPhone a redémarré. Réactivez le micro pour reprendre.")
            }
        }
    }

    private var agentContext: some View {
        HStack(spacing: 10) {
            AgentAvatar(name: app.profile, size: 30)
            Text(app.agent?.title ?? "Hermes").font(.subheadline.weight(.medium))
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .background(AppTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(AppTheme.line))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Conversation vocale avec \(app.agent?.title ?? "Hermes")")
    }

    private var guidance: String {
        if app.demo { return "Connectez votre Hermes pour parler avec votre agent." }
        if conversation.requiresStandardMode { return "Choisissez la voix standard pour cet appel." }
        if conversation.inputMuted { return "Votre micro est coupé. Vous pouvez continuer à écouter." }
        switch conversation.phase {
        case .ready: return "La conversation se prépare."
        case .listening: return "Parlez naturellement. L’écoute est automatique."
        case .transcribing: return "Un instant, je reprends vos mots."
        case .thinking: return "Votre agent prépare sa réponse."
        case .speaking: return conversation.allowsBargeIn ? "Vous pouvez reprendre la parole naturellement." : "L’écoute reprend après la réponse de votre agent."
        case .paused: return "Réactivez le micro quand vous êtes prêt."
        }
    }

    private var microphoneState: some View {
        Label(conversation.inputMuted ? "Micro coupé" : conversation.phase == .paused ? "En pause" : app.demo ? "Aperçu" : "Conversation automatique",
              systemImage: conversation.inputMuted ? "mic.slash" : conversation.phase == .paused ? "pause.circle" : "waveform")
            .font(.caption.weight(.medium)).foregroundStyle(conversation.inputMuted ? AppTheme.accent : .secondary)
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(AppTheme.accent.opacity(conversation.inputMuted ? 0.09 : 0.04), in: Capsule())
            .accessibilityIdentifier("voice-microphone-state")
    }

    private var standardModePrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ce profil utilise GPT-Live. La voix standard est disponible pour cet appel, avec les réglages vocaux de votre agent.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("Utiliser la voix standard") { conversation.start(standardMode: true) }
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

    private var microphoneLabel: String {
        conversation.phase == .paused ? "Reprendre" : conversation.inputMuted ? "Activer le micro" : "Couper le micro"
    }

    private var callControls: some View {
        HStack(alignment: .top, spacing: 32) {
            Button { conversation.toggleMicrophone() } label: {
                VStack(spacing: 10) {
                    Image(systemName: conversation.inputMuted || conversation.phase == .paused ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 23, weight: .medium)).frame(width: 68, height: 68)
                        .foregroundStyle(conversation.inputMuted ? AppTheme.accent : .primary)
                        .background(conversation.inputMuted ? AppTheme.accent.opacity(0.1) : AppTheme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(AppTheme.line))
                    Text(typeSize.isAccessibilitySize ? "Micro" : microphoneLabel)
                        .font(.caption.weight(.medium)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
            }.accessibilityLabel(microphoneLabel).accessibilityIdentifier("voice-listen")
                .disabled(app.demo || conversation.requiresStandardMode)
            Button { conversation.pause(); returnToChat() } label: {
                VStack(spacing: 10) {
                    Image(systemName: "xmark").font(.system(size: 21, weight: .medium)).frame(width: 68, height: 68)
                        .foregroundStyle(.white).background(AppTheme.accent, in: Circle())
                    Text(typeSize.isAccessibilitySize ? "Fin" : "Terminer").font(.caption.weight(.medium))
                }.frame(maxWidth: .infinity)
            }.accessibilityLabel("Terminer et revenir au chat").accessibilityIdentifier("return-to-chat")
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .frame(maxWidth: 340).padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 18)
            .frame(maxWidth: .infinity).background(AppTheme.background)
    }
}

/// Only this small surface observes microphone energy. Its clock never invalidates
/// the transcript, navigation or call controls, and sleeps when motion is unneeded.
private struct VoicePresence: View {
    let conversation: VoiceConversation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let phase = conversation.phase
        let muted = conversation.inputMuted
        let active = ![.ready, .paused].contains(phase) && !(muted && phase == .listening)
        let animating = active && !reduceMotion && scenePhase == .active
        let energy = active && !reduceMotion ? min(1, max(0, conversation.level)) : 0
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animating)) { timeline in
            Canvas { context, size in
                let time = animating ? timeline.date.timeIntervalSinceReferenceDate : 0
                let strength = reduceMotion || !active ? 0 : energy
                draw(context: context, size: size, time: time, energy: strength,
                     speaking: phase == .speaking, active: active)
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }

    private func draw(context: GraphicsContext, size: CGSize, time: Double, energy: Double, speaking: Bool, active: Bool) {
        let side = min(size.width, size.height)
        let diameter = side * CGFloat(0.78 + energy * 0.04)
        let rect = CGRect(x: (size.width - diameter) / 2, y: (size.height - diameter) / 2, width: diameter, height: diameter)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let silhouette = Path(ellipseIn: rect)
        let dark = colorScheme == .dark
        let accent = AppTheme.accent
        let warm = Color(red: 0.97, green: 0.66, blue: 0.43)
        let deep = Color(red: 0.55, green: 0.21, blue: 0.17)
        let halo = Path(ellipseIn: CGRect(x: 1, y: 1, width: size.width - 2, height: size.height - 2))
        context.fill(halo, with: .radialGradient(Gradient(colors: [accent.opacity(0.1), accent.opacity(0.025), .clear]), center: center, startRadius: side * 0.30, endRadius: side * 0.50))
        context.stroke(Path(ellipseIn: rect.insetBy(dx: -12, dy: -12)), with: .color(accent.opacity(active ? 0.12 : 0.06)), lineWidth: 0.75)

        var orb = context
        orb.clip(to: silhouette)
        orb.fill(silhouette, with: .linearGradient(Gradient(colors: [warm.opacity(dark ? 0.75 : 0.6), accent.opacity(active ? 0.9 : 0.5), deep.opacity(dark ? 0.95 : 0.85)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        let pace = speaking ? 1.6 : 0.9
        let amplitude = diameter * CGFloat(active ? 0.045 + energy * 0.10 : 0.035)
        for index in 0..<3 {
            let baseline = rect.minY + diameter * CGFloat(0.38 + Double(index) * 0.17)
            var wave = Path()
            wave.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            for sample in 0...40 {
                let position = Double(sample) / 40
                let angle = position * .pi * 2 + time * pace + Double(index) * 1.8
                let y = baseline + CGFloat(sin(angle)) * amplitude + CGFloat(cos(angle * 0.6 + Double(index))) * amplitude * 0.3
                wave.addLine(to: CGPoint(x: rect.minX + CGFloat(position) * diameter, y: y))
            }
            wave.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            wave.closeSubpath()
            orb.fill(wave, with: .linearGradient(Gradient(colors: [warm.opacity(0.45 - Double(index) * 0.06), accent.opacity(0.12), deep.opacity(0.4)]), startPoint: CGPoint(x: rect.midX, y: baseline - amplitude), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
        orb.fill(silhouette, with: .radialGradient(Gradient(colors: [.white.opacity(dark ? 0.24 : 0.45), .clear]), center: CGPoint(x: rect.minX + diameter * 0.28, y: rect.minY + diameter * 0.20), startRadius: 0, endRadius: diameter * 0.65))
        context.stroke(silhouette, with: .color(.white.opacity(dark ? 0.1 : 0.3)), lineWidth: 0.75)
    }
}

/// Streaming answer changes are confined to this optional panel.
private struct VoiceTranscriptPanel: View {
    let conversation: VoiceConversation
    @State private var expanded = false

    var body: some View {
        if !conversation.heard.isEmpty || !conversation.answer.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "text.bubble").font(.system(size: 16))
                        Text(expanded ? "Masquer la transcription" : "Voir la transcription").font(.subheadline.weight(.medium))
                        Spacer(minLength: 4)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption.weight(.semibold))
                    }.foregroundStyle(.secondary).frame(minHeight: 48).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("voice-transcript-toggle")
                    .accessibilityValue(expanded ? "Développée" : "Réduite")
                if expanded {
                    VStack(alignment: .leading, spacing: 16) {
                        if !conversation.heard.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Vous").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(conversation.heard).font(.subheadline).textSelection(.enabled)
                            }
                        }
                        if !conversation.answer.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Hermes").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
                                Text(conversation.answer).font(.subheadline).textSelection(.enabled)
                            }
                        }
                    }.lineSpacing(4).padding(.top, 4).padding(.bottom, 16)
                }
            }.padding(.horizontal, 16).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(AppTheme.line))
        }
    }
}
