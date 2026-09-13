import SwiftUI
import AVFoundation
import Observation

@MainActor @Observable
private final class PhoneAudio: NSObject, AVAudioPlayerDelegate {
    var recording = false
    var playing = false
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var generation = UUID()

    func start() async throws {
        let attempt = UUID(); generation = attempt
        guard await AVAudioApplication.requestRecordPermission() else { throw RPCFailure("Autorisez le microphone dans les réglages iOS pour dicter un message.") }
        guard attempt == generation else { throw CancellationError() }
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-voice-\(UUID().uuidString).m4a")
        file = url
        let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        self.recorder = recorder
        guard recorder.record(forDuration: 120) else { cleanup(); throw RPCFailure("Le microphone n’a pas pu démarrer.") }
        recording = true
    }
    func finish() throws -> Data {
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
        Task { @MainActor [weak self] in self?.stopPlayback() }
    }
}

struct VoiceView: View {
    let app: AppModel
    let returnToChat: () -> Void
    @State private var tools: NativeToolSession
    @State private var audio = PhoneAudio()
    @State private var transcript = ""
    @State private var working = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @State private var recordingLimit: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    init(app: AppModel, returnToChat: @escaping () -> Void) {
        self.app = app; self.returnToChat = returnToChat
        _tools = State(initialValue: NativeToolSession(app))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    Image(systemName: audio.recording ? "waveform" : "mic")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(AppTheme.accent)
                        .frame(width: 78, height: 78).background(AppTheme.accent.opacity(0.08), in: Circle())
                    VStack(spacing: 12) {
                        Text(audio.recording ? "Je vous écoute." : "Parlons simplement.")
                            .font(.system(size: 30, design: .serif)).multilineTextAlignment(.center)
                        Text(working ? "Hermes prépare l’audio…" : "Dictez, relisez, puis envoyez depuis le chat.\nLa voix est traitée par votre Hermes.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    if working { ProgressView() }
                    if let error { Text(error).font(.subheadline).foregroundStyle(AppTheme.accent) }
                    if !transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Votre message").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            TextField("Votre message", text: $transcript, axis: .vertical).lineLimit(3...12)
                            Button { insert() } label: { Label("Ajouter au chat", systemImage: "arrow.down.left").frame(maxWidth: .infinity, minHeight: 46) }
                                .buttonStyle(.borderedProminent)
                        }.hermesCard()
                    }
                    Button { audio.playing ? audio.stopPlayback() : speak() } label: {
                        Label(audio.playing ? "Arrêter la lecture" : "Écouter la dernière réponse", systemImage: audio.playing ? "stop.circle" : "speaker.wave.2")
                            .font(.subheadline).frame(minHeight: 44)
                    }.buttonStyle(.plain).disabled(working || audio.recording || app.transcript.running || lastAnswer.isEmpty || app.demo)
                    Text("Dictée et lecture à la demande. La conversation vocale continue n’est pas encore prise en charge.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }.padding(28).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(AppTheme.background)
                .navigationTitle("Voix").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ToolDock {
                        Button { audio.recording ? transcribe() : start() } label: {
                            Label(audio.recording ? "Terminer" : "Dicter", systemImage: audio.recording ? "stop.fill" : "mic.fill")
                                .padding(.horizontal, 18).frame(height: 44)
                                .foregroundStyle(AppTheme.surface).background(Color.primary, in: Capsule())
                        }.disabled(working || app.demo).accessibilityLabel(audio.recording ? "Terminer la dictée" : "Dicter un message")
                    }
                }
                .onDisappear { cancelAudio() }
                .onChange(of: scenePhase) { _, phase in if phase == .background { cancelAudio() } }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in cancelAudio() }
        }
    }
    private var lastAnswer: String { app.transcript.messages.last(where: { $0.role == "assistant" })?.text ?? "" }
    private func start() {
        working = true; error = nil
        operation = Task {
            defer { working = false }
            do {
                try await audio.start(); try Task.checkCancellation()
                recordingLimit = Task {
                    do { try await Task.sleep(for: .seconds(120)); transcribe() } catch { }
                }
            } catch is CancellationError { audio.cleanup() }
            catch { self.error = error.localizedDescription; audio.cleanup() }
        }
    }
    private func transcribe() {
        recordingLimit?.cancel(); working = true; error = nil
        operation = Task {
            defer { working = false }
            do {
                let data = try audio.finish()
                let result = try await tools.request("/api/audio/transcribe", method: "POST", body: ["data_url": .string("data:audio/mp4;base64,\(data.base64EncodedString())"), "mime_type": "audio/mp4"])
                transcript = result["transcript"].string
                if transcript.isEmpty { error = "Aucune parole détectée. Vous pouvez réessayer." }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func speak() {
        let text = lastAnswer; working = true; error = nil
        operation = Task {
            defer { working = false }
            do {
                let result = try await tools.request("/api/audio/speak", method: "POST", body: ["text": .string(text)])
                try audio.play(result["data_url"].string)
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    private func insert() {
        guard app.activeConnection?.id == tools.connectionID, app.profile == tools.profile else { error = "Revenez au profil de cette dictée avant de l’ajouter."; return }
        app.draft += (app.draft.isEmpty ? "" : "\n") + transcript
        returnToChat()
    }
    private func cancelAudio() {
        operation?.cancel(); recordingLimit?.cancel(); audio.cleanup(); working = false
    }
}
