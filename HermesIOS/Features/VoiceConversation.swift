import Foundation
import Observation

/// One native conversation; microphone monitoring stays independent of network work.
@MainActor @Observable
final class VoiceConversation {
    enum Phase { case ready, listening, transcribing, thinking, speaking, paused }
    let tools: NativeToolSession
    let audio: PhoneAudio
    let speechStream: NativeSpeechStream
    var phase = Phase.ready
    var heard = ""
    var answer = ""
    var error: String?
    var requiresStandardMode = false
    var inputMuted = false
    var allowsBargeIn = false
    var level = 0.0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var response: Task<Void, Error>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var bargeCapture: Task<Void, Error>?
    @ObservationIgnored private var interruption: Task<Void, Error>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var inputRevision = 0
    @ObservationIgnored private var lease: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var standardModeAccepted = false
    @ObservationIgnored private var bargeRequested = false

    init(_ app: AppModel) {
        tools = NativeToolSession(app); sessionID = app.selected?.storedID
        let audio = PhoneAudio()
        self.audio = audio; speechStream = NativeSpeechStream(audio: audio)
        #if DEBUG
        audio.fixture = ProcessInfo.processInfo.arguments.contains("--voice-fixture") && app.activeConnection?.endpoint.baseURL.host == "127.0.0.1"
        #endif
    }
    var title: String {
        switch phase {
        case .ready: "La voix se prépare."
        case .listening: inputMuted ? "Microphone coupé." : "Je vous écoute."
        case .transcribing: "Je vous ai entendu."
        case .thinking: "Hermes réfléchit."
        case .speaking: "Hermes vous répond."
        case .paused: "On reprend ?"
        }
    }
    func start(standardMode: Bool = false) {
        guard operation == nil, !tools.app.demo else { return }
        if standardMode { standardModeAccepted = true }
        sessionID = tools.app.selected?.storedID
        let attempt = UUID(); generation = attempt
        inputMuted = false; bargeRequested = false; error = nil; phase = .ready
        tools.app.voiceActive = true
        operation = Task {
            defer {
                if generation == attempt {
                    stopLocalAudio(); operation = nil; phase = .paused
                    tools.app.voiceActive = false; releaseLease()
                }
            }
            do {
                let preferences = try await voiceAPI.preferences()
                try validate(attempt)
                if preferences.isGPTLive, !standardModeAccepted {
                    requiresStandardMode = true; return
                }
                requiresStandardMode = false
                allowsBargeIn = preferences.bargeIn
                try await audio.prepare(); try validate(attempt)
                audio.setInputMuted(inputMuted)
                startMonitoring(preferences, attempt: attempt)
                let leaseID = "ios-" + UUID().uuidString
                lease = leaseID
                _ = try? await tools.request("/api/audio/tts-lease", method: "POST", body: ["lease": .string(leaseID), "active": true])
                if generation != attempt || Task.isCancelled {
                    let tools = tools
                    Task { _ = try? await tools.request("/api/audio/tts-lease", method: "POST", body: ["lease": .string(leaseID), "active": false]) }
                    throw CancellationError()
                }
                try validate(attempt)
                // Reopening voice during an admitted turn follows that same turn.
                if tools.app.transcript.running,
                   let message = tools.app.transcript.messages.last(where: { $0.role == "user" }) {
                    heard = message.text
                    try await respond(to: message.id, attempt: attempt)
                }
                while true {
                    try validate(attempt)
                    let capturedByInterruption = bargeRequested
                    if capturedByInterruption {
                        try await bargeCapture?.value
                        bargeCapture = nil; bargeRequested = false
                    }
                    let recording = try await listen(preferences, attempt: attempt, alreadyCapturing: capturedByInterruption)
                    phase = .transcribing
                    let transcription = try await voiceAPI.transcribe(recording, mimeType: audio.mimeType)
                    try validate(attempt)
                    guard !transcription.isEmpty else { continue }
                    heard = transcription
                    if VoiceActivity.isStop(heard, phrases: preferences.stopPhrases) { return }
                    // Never submit over a still-running or uncertain previous turn.
                    if let interruption {
                        try await interruption.value; self.interruption = nil
                        try await waitUntilIdle(attempt)
                    }
                    phase = .thinking; answer = ""
                    let message = try await tools.app.sendVoice(heard)
                    sessionID = tools.app.selected?.storedID
                    try validate(attempt)
                    try await respond(to: message, attempt: attempt)
                }
            } catch is CancellationError {
                if generation == attempt, !Task.isCancelled {
                    error = "La connexion a changé. La conversation reste disponible dans le chat."
                }
            } catch {
                if generation == attempt { self.error = error.localizedDescription }
            }
        }
    }
    private func listen(_ preferences: VoicePreferences, attempt: UUID, alreadyCapturing: Bool) async throws -> Data {
        var activity = VoiceActivity(threshold: preferences.threshold, silenceDuration: preferences.silenceDuration, confirmedSpeech: alreadyCapturing)
        var revision = inputRevision
        var capturing = alreadyCapturing
        phase = .listening
        while true {
            try validate(attempt)
            if inputMuted {
                capturing = false
                try await Task.sleep(for: .milliseconds(50)); continue
            }
            if !capturing || revision != inputRevision {
                try await audio.start(); try validate(attempt)
                revision = inputRevision; capturing = true
                activity = VoiceActivity(threshold: preferences.threshold, silenceDuration: preferences.silenceDuration)
            }
            try await Task.sleep(for: .milliseconds(50)); try validate(attempt)
            guard !inputMuted, revision == inputRevision else { continue }
            if let failure = audio.failure { throw RPCFailure(failure) }
            let ended = activity.sample(decibels: audio.power(), interval: 0.05)
            if ended || (activity.hasSpeech && activity.elapsed >= 119) { return try await audio.finish() }
            // Quiet rooms stay ready indefinitely; rotate the bounded recording.
            if activity.elapsed >= 119 { capturing = false }
        }
    }
    private func respond(to message: String, attempt: UUID) async throws {
        bargeRequested = false; phase = .thinking
        let work = Task { try await self.readResponse(to: message, attempt: attempt) }
        response = work
        do { try await work.value }
        catch {
            guard bargeRequested, generation == attempt, !Task.isCancelled else { throw error }
            // Monitoring already stopped playback and retained the user's onset.
        }
        response = nil
        try validate(attempt)
    }
    private func readResponse(to message: String, attempt: UUID) async throws {
        let streaming = try await speechStream.open(tools: tools)
        try validate(attempt)
        var cursor = VoiceTextCursor()
        let deadline = Date().addingTimeInterval(600)
        repeat {
            try validate(attempt)
            let transcript = tools.app.transcript
            if transcript.approval != nil || transcript.clarification != nil || transcript.credential != nil {
                throw RPCFailure("Hermes attend votre réponse dans le chat.")
            }
            if let failure = transcript.failure { throw RPCFailure(failure) }
            guard Date() < deadline else { throw RPCFailure("Hermes travaille encore. Retrouvez sa réponse dans le chat.") }
            guard let index = transcript.messages.firstIndex(where: { $0.id == message }) else {
                throw RPCFailure("La conversation a changé. Retrouvez la réponse dans le chat.")
            }
            let text = transcript.messages.dropFirst(index + 1).filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n\n")
            if text != answer { answer = text }
            if streaming {
                if let failure = speechStream.failure { throw RPCFailure(failure) }
                let delta = try cursor.delta(answer)
                if !delta.isEmpty || !transcript.running { try await speechStream.send(delta, done: !transcript.running) }
                try validate(attempt)
                if speechStream.hasAudio { phase = .speaking }
            }
            if !transcript.running { break }
            try await Task.sleep(for: .milliseconds(100))
        } while true
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCFailure("Hermes n’a pas renvoyé de réponse à lire.") }
        if streaming {
            while !speechStream.drained {
                try await Task.sleep(for: .milliseconds(50)); try validate(attempt)
                if speechStream.hasAudio { phase = .speaking }
                if let failure = speechStream.failure { throw RPCFailure(failure) }
                if let failure = audio.failure { throw RPCFailure(failure) }
                guard Date() < deadline else { throw RPCFailure("La lecture vocale prend trop de temps. La réponse reste dans le chat.") }
            }
            if let failure = speechStream.failure { throw RPCFailure(failure) }
        }
        let needsFallback = !streaming || !speechStream.hasAudio
        speechStream.stop()
        if needsFallback {
            let speech = try await voiceAPI.speech(answer)
            try validate(attempt)
            try await audio.play(speech); try validate(attempt); phase = .speaking
            while audio.playing {
                try await Task.sleep(for: .milliseconds(50)); try validate(attempt)
                if let failure = audio.failure { throw RPCFailure(failure) }
            }
        }
    }
    private func startMonitoring(_ preferences: VoicePreferences, attempt: UUID) {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var detector = VoiceBargeIn(preferences: preferences)
            var wasSpeaking = false
            var revision = self?.inputRevision
            var ambient = VoiceNoiseFloor()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, self.generation == attempt else { return }
                if self.tools.app.state != .connected {
                    self.systemInterrupted("La connexion à Hermès a été interrompue. La réponse reste dans le chat.")
                    return
                }
                if let failure = self.audio.failure {
                    self.systemInterrupted(failure)
                    return
                }
                let speaking = self.phase == .speaking
                let power = self.audio.power()
                if [.transcribing, .thinking].contains(self.phase), !self.audio.playing, !self.inputMuted {
                    // Learn only between utterances; never treat speaker bleed as room noise.
                    ambient.sample(decibels: power, interval: 0.05, multiplier: preferences.bargeInThresholdMultiplier)
                }
                let next = speaking ? self.audio.outputLevel : self.inputMuted ? 0 : VoiceActivity.normalizedLevel(decibels: power)
                if abs(self.level - next) > 0.015 { self.level = next }
                if (speaking && !wasSpeaking) || revision != self.inputRevision {
                    detector = VoiceBargeIn(preferences: preferences, noiseFloor: ambient.value)
                }
                revision = self.inputRevision
                wasSpeaking = speaking
                if speaking, !self.inputMuted, !self.bargeRequested, detector.sample(decibels: power, interval: 0.05) {
                    self.interruptForSpeech(attempt)
                }
            }
        }
    }
    private func interruptForSpeech(_ attempt: UUID) {
        guard generation == attempt, let runtimeID = tools.app.selected?.runtimeID, !runtimeID.isEmpty else { return }
        bargeRequested = true
        speechStream.stop(); audio.stopPlayback(); response?.cancel()
        phase = .listening
        bargeCapture = Task { try await audio.start(includePreRoll: true); try validate(attempt) }
        let wasRunning = tools.app.transcript.running
        interruption = Task {
            if wasRunning { try await tools.app.interruptVoice(connectionID: tools.connectionID, profile: tools.profile, runtimeID: runtimeID) }
            try validate(attempt)
        }
    }
    private func waitUntilIdle(_ attempt: UUID) async throws {
        let deadline = Date().addingTimeInterval(8)
        while tools.app.transcript.running {
            try validate(attempt)
            guard Date() < deadline else { throw RPCFailure("Hermes n’a pas encore confirmé l’interruption. Votre dernière phrase n’a pas été envoyée ; elle reste affichée ici.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private var voiceAPI: NativeVoiceAPI {
        NativeVoiceAPI { [tools] path, body, rpc in try await tools.request(path, method: "POST", body: body, rpc: rpc) }
    }
    private func validate(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard attempt == generation, tools.connectionID == tools.app.activeConnection?.id,
              tools.profile == tools.app.profile, sessionID == tools.app.selected?.storedID else { throw CancellationError() }
        guard tools.app.state == .connected else { throw RPCFailure("La connexion à Hermès a été interrompue. Retrouvez la réponse dans le chat, puis reprenez la voix.") }
    }
    private func releaseLease() {
        guard let lease else { return }; self.lease = nil
        let tools = tools
        Task { _ = try? await tools.request("/api/audio/tts-lease", method: "POST", body: ["lease": .string(lease), "active": false]) }
    }
    private func stopLocalAudio() {
        monitor?.cancel(); monitor = nil; response?.cancel(); response = nil
        bargeCapture?.cancel(); bargeCapture = nil; interruption?.cancel(); interruption = nil
        speechStream.stop(); audio.cleanup(); level = 0
    }
    func pause() {
        generation = UUID(); operation?.cancel(); operation = nil
        stopLocalAudio(); phase = .paused; tools.app.voiceActive = false; releaseLease()
    }
    func toggleMicrophone() {
        guard !tools.app.demo else { return }
        if operation == nil { start(); return }
        inputMuted.toggle(); inputRevision += 1
        audio.setInputMuted(inputMuted)
        if inputMuted { level = 0 }
    }
    func systemInterrupted(_ message: String) {
        guard operation != nil else { return }
        pause(); error = message
    }
}
