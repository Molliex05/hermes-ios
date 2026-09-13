import SwiftUI
import AVFoundation
import Observation

@MainActor @Observable
private final class PhoneAudio: NSObject, AVAudioPlayerDelegate {
    #if DEBUG
    var fixture = false
    private var fixtureSamples = 0
    #endif
    var recording = false
    var playing = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var generation = UUID()

    var mimeType: String {
        #if DEBUG
        if fixture { return "audio/wav" }
        #endif
        return "audio/mp4"
    }
    func start() async throws {
        #if DEBUG
        if fixture { fixtureSamples = 0; recording = true; return }
        #endif
        let attempt = UUID(); generation = attempt
        guard await AVAudioApplication.requestRecordPermission() else { throw RPCFailure("Autorisez le microphone dans les réglages iOS pour parler avec Hermes.") }
        guard attempt == generation else { throw CancellationError() }
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-voice-\(UUID().uuidString).m4a")
        file = url
        let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        recorder.isMeteringEnabled = true
        self.recorder = recorder
        guard recorder.record(forDuration: 120) else { cleanup(); throw RPCFailure("Le microphone n’a pas pu démarrer.") }
        recording = true
    }
    func power() -> Double {
        #if DEBUG
        if fixture { fixtureSamples += 1; return fixtureSamples <= 10 ? -20 : -90 }
        #endif
        recorder?.updateMeters(); return Double(recorder?.averagePower(forChannel: 0) ?? -160)
    }
    func finish() throws -> Data {
        #if DEBUG
        if fixture { recording = false; return Data(base64Encoded: "UklGRuQSAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YcASAAA=")! + Data(repeating: 0, count: 4800) }
        #endif
        recorder?.stop(); recording = false
        guard let file else { throw RPCFailure("Aucun enregistrement disponible.") }
        defer { cleanup() }
        return try Data(contentsOf: file)
    }
    func play(_ dataURL: String) throws {
        guard let comma = dataURL.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { throw RPCFailure("Hermes n’a pas renvoyé d’audio lisible.") }
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
        let player = try AVAudioPlayer(data: data); self.player = player; player.delegate = self
        playing = player.play()
        if !playing { throw RPCFailure("Impossible de lire cet audio.") }
    }
    func stopPlayback() {
        player?.stop(); player = nil; playing = false
        if !recording { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    func cleanup() {
        generation = UUID(); recorder?.stop(); recorder = nil; recording = false
        if let file { try? FileManager.default.removeItem(at: file) }; file = nil
        stopPlayback()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in if self?.player === player { self?.stopPlayback() } }
    }
}

@MainActor @Observable
private final class VoiceConversation {
    enum Phase { case ready, listening, transcribing, thinking, speaking, paused }
    let tools: NativeToolSession
    let audio = PhoneAudio()
    var phase = Phase.ready
    var heard = ""
    var answer = ""
    var error: String?
    var requiresStandardMode = false
    var finishUtterance = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lease: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var standardModeAccepted = false
    init(_ app: AppModel) {
        tools = NativeToolSession(app); sessionID = app.selected?.storedID
        #if DEBUG
        audio.fixture = ProcessInfo.processInfo.arguments.contains("--voice-fixture") && app.activeConnection?.endpoint.baseURL.host == "127.0.0.1"
        #endif
    }
    var title: String {
        switch phase {
        case .ready: "Parlons simplement."
        case .listening: "Je vous écoute."
        case .transcribing: "Je vous ai entendu."
        case .thinking: "Hermes réfléchit."
        case .speaking: "Hermes vous répond."
        case .paused: "On reprend ?"
        }
    }
    func start(standardMode: Bool = false) {
        guard operation == nil, !tools.app.demo else { return }
        sessionID = tools.app.selected?.storedID
        if standardMode { standardModeAccepted = true }
        let attempt = UUID(); generation = attempt
        tools.app.voiceActive = true; error = nil
        operation = Task {
            defer {
                if generation == attempt { audio.cleanup(); tools.app.voiceActive = false; operation = nil; phase = .paused; releaseLease() }
            }
            do {
                let preferences = try await voiceAPI.preferences()
                try validate(attempt)
                if preferences.isGPTLive, !standardModeAccepted {
                    requiresStandardMode = true
                    return
                }
                requiresStandardMode = false
                let leaseID = "ios-" + UUID().uuidString
                lease = leaseID
                _ = try? await tools.request("/api/audio/tts-lease", method: "POST", body: ["lease": .string(leaseID), "active": true])
                while true {
                    try validate(attempt)
                    guard !tools.app.transcript.running else { throw RPCFailure("Attendez la fin de la réponse dans le chat.") }
                    phase = .listening; finishUtterance = false
                    var activity = VoiceActivity(threshold: preferences.threshold, silenceDuration: preferences.silenceDuration)
                    try await audio.start()
                    while true {
                        try await Task.sleep(for: .milliseconds(50)); try validate(attempt)
                        let ended = activity.sample(decibels: audio.power(), interval: 0.05)
                        if ended || finishUtterance || activity.elapsed >= 120 { break }
                        if activity.elapsed >= 15, !activity.hasSpeech { throw RPCFailure("L’écoute est en pause. Touchez le micro pour reprendre.") }
                    }
                    let recording = try audio.finish()
                    guard activity.hasSpeech else { throw RPCFailure("Aucune parole détectée. Touchez le micro pour réessayer.") }
                    phase = .transcribing
                    let transcription = try await voiceAPI.transcribe(recording, mimeType: audio.mimeType)
                    try validate(attempt)
                    heard = transcription
                    if heard.isEmpty { continue }
                    if VoiceActivity.isStop(heard, phrases: preferences.stopPhrases) { return }
                    phase = .thinking; answer = ""
                    let message = try await tools.app.sendVoice(heard)
                    sessionID = tools.app.selected?.storedID
                    try validate(attempt)
                    let deadline = Date().addingTimeInterval(600)
                    while tools.app.transcript.running {
                        try await Task.sleep(for: .milliseconds(100)); try validate(attempt)
                        let transcript = tools.app.transcript
                        if transcript.approval != nil || transcript.clarification != nil || transcript.credential != nil {
                            throw RPCFailure("Hermes attend votre réponse dans le chat.")
                        }
                        guard Date() < deadline else { throw RPCFailure("Hermes travaille encore. Retrouvez sa réponse dans le chat.") }
                    }
                    try validate(attempt)
                    if let failure = tools.app.transcript.failure { throw RPCFailure(failure) }
                    let messages = tools.app.transcript.messages
                    guard let index = messages.firstIndex(where: { $0.id == message }) else { throw RPCFailure("La conversation a changé. Retrouvez la réponse dans le chat.") }
                    answer = messages.dropFirst(index + 1).filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n\n")
                    guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCFailure("Hermes n’a pas renvoyé de réponse à lire.") }
                    let speech = try await voiceAPI.speech(answer)
                    try validate(attempt)
                    phase = .speaking
                    try audio.play(speech)
                    while audio.playing { try await Task.sleep(for: .milliseconds(100)); try validate(attempt) }
                }
            } catch is CancellationError { }
            catch { if generation == attempt { self.error = error.localizedDescription } }
        }
    }
    private var voiceAPI: NativeVoiceAPI {
        NativeVoiceAPI { [tools] path, body, rpc in
            try await tools.request(path, method: "POST", body: body, rpc: rpc)
        }
    }
    private func validate(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard attempt == generation, tools.connectionID == tools.app.activeConnection?.id,
              tools.profile == tools.app.profile, tools.app.state == .connected,
              sessionID == tools.app.selected?.storedID else { throw CancellationError() }
    }
    private func releaseLease() {
        guard let lease else { return }; self.lease = nil
        let tools = tools
        Task { _ = try? await tools.request("/api/audio/tts-lease", method: "POST", body: ["lease": .string(lease), "active": false]) }
    }
    func pause() {
        generation = UUID(); operation?.cancel(); operation = nil
        audio.cleanup(); phase = .paused; tools.app.voiceActive = false; releaseLease()
    }
    func speakNow() {
        // Playback can be interrupted locally without cancelling a completed agent turn.
        if phase == .speaking { pause(); start() }
        else if phase == .listening { finishUtterance = true }
        else if phase == .ready || phase == .paused { start() }
    }
}

struct VoiceView: View {
    let app: AppModel
    let returnToChat: () -> Void
    @State private var conversation: VoiceConversation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.toolNavigation) private var navigation
    init(app: AppModel, returnToChat: @escaping () -> Void) {
        self.app = app; self.returnToChat = returnToChat
        _conversation = State(initialValue: VoiceConversation(app))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 28) {
                        Text(app.agent?.title ?? "Hermes").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        ZStack {
                            Circle().fill(AppTheme.accent.opacity(0.045)).frame(width: 190, height: 190)
                            Circle().fill(AppTheme.accent.opacity(0.07)).frame(width: 144, height: 144)
                            Image(systemName: conversation.phase == .speaking ? "waveform" : "mic")
                                .font(.system(size: 42, weight: .light)).foregroundStyle(AppTheme.accent)
                                .symbolEffect(.pulse, isActive: conversation.phase == .listening || conversation.phase == .speaking)
                        }.padding(.top, 22)
                        VStack(spacing: 12) {
                            Text(conversation.title).font(.system(size: 31, design: .serif)).multilineTextAlignment(.center)
                            Text("Votre agent, sa voix.\nL’écoute reprend après sa réponse.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        if app.demo { Text("Connectez votre Hermes pour démarrer une conversation vocale.").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                        if conversation.requiresStandardMode {
                            Text("Ce profil utilise GPT-Live, qui n’est pas encore disponible sur iOS. Vous pouvez utiliser la conversation vocale standard pour cet appel.").font(.subheadline).foregroundStyle(.secondary)
                            Button("Utiliser la voix standard") { conversation.start(standardMode: true) }.buttonStyle(.bordered)
                        }
                        if let error = conversation.error { Text(error).font(.subheadline).foregroundStyle(AppTheme.accent).multilineTextAlignment(.center) }
                        if !conversation.heard.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(conversation.heard).foregroundStyle(.secondary)
                                if !conversation.answer.isEmpty { Text(conversation.answer) }
                            }.font(.subheadline).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).hermesCard()
                        }
                    }.padding(28).frame(maxWidth: 600).frame(maxWidth: .infinity)
                }
                HStack(spacing: 24) {
                    Button { conversation.pause(); returnToChat() } label: {
                        Image(systemName: "xmark").font(.system(size: 20)).frame(width: 58, height: 58).background(AppTheme.surface, in: Circle())
                    }.accessibilityLabel("Terminer et revenir au chat").accessibilityIdentifier("return-to-chat")
                    Button { conversation.speakNow() } label: {
                        Image(systemName: conversation.phase == .speaking ? "waveform" : "mic.fill").font(.system(size: 25))
                            .frame(width: 76, height: 76).foregroundStyle(AppTheme.surface).background(AppTheme.accent, in: Circle())
                    }.accessibilityLabel(conversation.phase == .speaking ? "Interrompre et parler" : conversation.phase == .listening ? "Envoyer ma parole" : "Reprendre l’écoute")
                        .accessibilityIdentifier("voice-listen")
                        .disabled(app.demo || [.thinking, .transcribing].contains(conversation.phase) || conversation.requiresStandardMode)
                    Button { conversation.pause() } label: {
                        Image(systemName: "pause.fill").font(.system(size: 20)).frame(width: 58, height: 58).background(AppTheme.surface, in: Circle())
                    }.accessibilityLabel("Mettre l’écoute en pause").disabled(app.demo || conversation.phase == .paused)
                }.buttonStyle(.plain).padding(.vertical, 22)
            }.background(AppTheme.background).navigationTitle("Voix").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let navigation {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { conversation.pause(); navigation.showSpaces() } label: {
                                Image(systemName: "circle.grid.2x2").frame(width: 44, height: 44)
                            }.accessibilityLabel("Outils").accessibilityIdentifier("back-to-spaces")
                        }
                    }
                }
                .task { conversation.start() }
                .onDisappear { conversation.pause() }
                .onChange(of: scenePhase) { _, phase in if phase == .background { conversation.pause() } }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in conversation.pause() }
        }
    }
}
