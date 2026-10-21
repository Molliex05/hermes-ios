import Foundation
import Observation

/// One native conversation. Microphone meters are measured on the audio thread and drive
/// endpointing and barge-in here, independently of network work; the reply streams to
/// speech as Hermes generates it (`AppModel.speechSink`), never through UI polling.
@MainActor @Observable
final class VoiceConversation {
    enum Phase { case ready, listening, transcribing, thinking, speaking, waiting, paused }
    let tools: NativeToolSession
    let audio: PhoneAudio
    let speechStream: NativeSpeechStream
    var phase = Phase.ready { didSet { if phase != oldValue { syncActivity() } } }
    var heard = ""
    /// Words recognized while the user is still speaking (live STT partials).
    var partial = ""
    var answer = ""
    /// The conversation stopped.
    var error: String?
    /// A turn-level problem; listening continues.
    var notice: String?
    var requiresStandardMode = false
    var isLive = false
    var inputMuted = false { didSet { if inputMuted != oldValue { syncActivity() } } }
    var allowsBargeIn = false
    var level = 0.0
    @ObservationIgnored private var preferences = VoicePreferences(.null)
    @ObservationIgnored private var live: VoiceLiveTransport?
    @ObservationIgnored private var liveTranscript = VoiceLiveTranscript()
    @ObservationIgnored private var lastLiveSpeechAt = -TimeInterval.infinity
    @ObservationIgnored private var lastLiveOutputAt = -TimeInterval.infinity
    @ObservationIgnored private var stopTimer: Task<Void, Never>?
    @ObservationIgnored private var liveRequested = false
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var response: Task<Void, Error>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var interruption: Task<Bool, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var leases: [(path: String, id: String)] = []
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var standardModeAccepted = false
    // Utterance pipeline (standard voice).
    @ObservationIgnored private var onset = VoiceActivity(threshold: 200, silenceDuration: 0.8)
    @ObservationIgnored private var ambient = VoiceNoiseFloor()
    @ObservationIgnored private var barge: VoiceBargeIn?
    @ObservationIgnored private var capture: Utterance?
    @ObservationIgnored private var finished: [Utterance] = []
    @ObservationIgnored private var turnActive = false
    @ObservationIgnored private var awaitingUser = false
    @ObservationIgnored private var bargeRequested = false
    @ObservationIgnored private var interruptedTurn = false
    @ObservationIgnored private var liveSTT = false
    // Reply fed by AppModel.speechSink.
    @ObservationIgnored private var reply = VoiceReplyText()
    @ObservationIgnored private let localSpeech = LocalSpeech()
    @ObservationIgnored private var replyOpen = false
    @ObservationIgnored private var replyStatus: String?
    @ObservationIgnored private var liveDelegation: String?
    @ObservationIgnored private var liveCursor = VoiceLiveReplyCursor()
    @ObservationIgnored private var liveFirstResultAt: TimeInterval?

    /// Connection|profile pairs whose GPT-Live failed during this app session.
    private static var liveUnavailable = Set<String>()
    private static let waitingNotice = "Hermes attend votre réponse dans le chat. La conversation vocale reprendra ensuite."
    private static let busyNotice = "Hermes termine la réponse précédente…"
    private static let localVoiceNotice = "La voix du serveur est indisponible (quota). L’iPhone lit la réponse."
    /// Spoken once when the agent has been working in silence: after a tool starts, or after a slow start.
    private static let holdingLine = "Je regarde ça. "
    private static let holdingToolDelay: TimeInterval = 0.5
    private static let holdingSlowDelay: TimeInterval = 1.5

    init(_ app: AppModel) {
        tools = NativeToolSession(app); sessionID = app.selected?.storedID
        let audio = PhoneAudio()
        self.audio = audio; speechStream = NativeSpeechStream(audio: audio)
        #if DEBUG
        audio.fixture = ProcessInfo.processInfo.arguments.contains("--voice-fixture") && app.activeConnection?.endpoint.baseURL.host == "127.0.0.1"
        #endif
    }
    private func syncActivity() {
        guard !tools.app.demo else { return }
        let name: String = switch phase {
        case .ready, .listening, .transcribing: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .waiting: "waiting"
        case .paused: "paused"
        }
        LiveActivities.shared.updateCall(title: tools.app.agent?.title ?? "Hermès", phase: name, muted: inputMuted)
    }
    var title: String {
        if inputMuted, [.listening, .transcribing, .thinking].contains(phase) { return "Microphone coupé." }
        return switch phase {
        case .ready: "La voix se prépare."
        case .listening: "Je vous écoute."
        case .transcribing: "Je vous ai entendu."
        case .thinking: "Hermes réfléchit."
        case .speaking: "Hermes vous répond."
        case .waiting: "Hermes attend votre réponse."
        case .paused: "On reprend ?"
        }
    }
    func start(standardMode: Bool = false, useLive: Bool = false) {
        VoiceCallRemote.current = self
        guard operation == nil, !tools.app.demo else { return }
        if standardMode { standardModeAccepted = true; liveRequested = false }
        if useLive { standardModeAccepted = false; liveRequested = true }
        sessionID = tools.app.selected?.storedID
        let attempt = UUID(); generation = attempt
        inputMuted = false; error = nil; notice = nil; phase = .ready
        tools.app.voiceActive = true
        operation = Task {
            defer {
                if generation == attempt {
                    stopLocalAudio(); operation = nil; phase = .paused
                    tools.app.voiceActive = false; releaseLeases()
                }
            }
            do {
                let preferences = try await voiceAPI.preferences()
                self.preferences = preferences
                try validate(attempt)
                let liveKey = "\(tools.connectionID?.uuidString ?? "")|\(tools.profile)"
                if (preferences.isGPTLive || liveRequested), !standardModeAccepted,
                   liveRequested || !Self.liveUnavailable.contains(liveKey) {
                    isLive = true; requiresStandardMode = false; allowsBargeIn = true
                    do { try await runLive(preferences, attempt: attempt, configureStone: useLive); return }
                    catch let unavailable as VoiceLiveUnavailable {
                        // Never leave the call stuck: continue at once with the standard engine and
                        // say why. This profile skips GPT-Live until it is chosen again in the menu.
                        guard generation == attempt, !Task.isCancelled else { throw CancellationError() }
                        Self.liveUnavailable.insert(liveKey); liveRequested = false
                        live?.close(); live = nil; liveTranscript = VoiceLiveTranscript(); tools.app.speechSink = nil
                        await VoiceAudioEngine.settleAudioWork()
                        try validate(attempt)
                        notice = "GPT-Live indisponible : \(unavailable.message) Voix standard utilisée pour cet appel."
                    }
                }
                try await runStandard(preferences, attempt: attempt)
            } catch is CancellationError {
                if generation == attempt, !Task.isCancelled {
                    error = "La connexion a changé. La conversation reste disponible dans le chat."
                }
            } catch {
                if generation == attempt { self.error = error.localizedDescription }
            }
        }
    }
    /// Explicit engine selection only updates the voice settings of the captured profile.
    func chooseLive() { pause(); start(useLive: true) }
    func chooseStandard() { pause(); start(standardMode: true) }

    // MARK: Standard voice (chained STT → Hermes → TTS)

    private func runStandard(_ preferences: VoicePreferences, attempt: UUID) async throws {
        isLive = false
        requiresStandardMode = false
        allowsBargeIn = preferences.bargeIn
        liveSTT = preferences.liveTranscription
        onset = VoiceActivity(threshold: preferences.threshold, silenceDuration: preferences.endpointSilence)
        ambient = VoiceNoiseFloor()
        try await audio.prepare(); try validate(attempt)
        audio.setInputMuted(inputMuted)
        tools.app.speechSink = { [weak self] event in self?.receiveSpeech(event, attempt: attempt) }
        startMonitoring(attempt)
        // Warm the server's TTS (and local STT) while the user starts speaking.
        await acquireLeases(attempt)
        try validate(attempt)
        // Reopening voice during an admitted turn follows that same turn.
        if tools.app.transcript.running,
           let message = tools.app.transcript.messages.last(where: { $0.role == "user" }) {
            heard = message.text
            turnActive = true; bargeRequested = false
            barge = preferences.bargeIn ? VoiceBargeIn(preferences: preferences, noiseFloor: ambient.value) : nil
            speechStream.prepare(tools: tools)
            openReply(seed: assistantText(after: message.id))
            try await respond(to: message.id, attempt: attempt)
        }
        var pending = ""
        while true {
            try validate(attempt)
            let utterance = try await nextUtterance(attempt)
            let words = try await transcribe(utterance, attempt: attempt)
            if utterance.barge, !words.isEmpty, !utterance.spoken.isEmpty, await Self.isEcho(words, spoken: utterance.spoken + " " + VoiceFiller.phrases.joined(separator: " ")) {
                // Hermes heard itself: no submit, and the next real turn isn't annotated.
                interruptedTurn = false
                if pending.isEmpty, capture == nil, finished.isEmpty { speechStream.stop() }
                continue
            }
            pending = [pending, words].filter { !$0.isEmpty }.joined(separator: " ")
            if !pending.isEmpty { heard = pending }
            // Speech resumed before submission belongs to the same request.
            if capture != nil || !finished.isEmpty { continue }
            partial = ""
            guard !pending.isEmpty else { speechStream.stop(); continue }
            if VoiceActivity.isStop(pending, phrases: preferences.stopPhrases) { return }
            // From here on, speech interrupts (barge-in) instead of extending the request.
            turnActive = true; bargeRequested = false
            barge = preferences.bargeIn ? VoiceBargeIn(preferences: preferences, noiseFloor: ambient.value) : nil
            let settled = try await settle(attempt)
            if bargeRequested { turnActive = false; continue }
            guard settled else {
                pending = ""; turnActive = false; barge = nil; speechStream.stop()
                continue
            }
            let text = pending; pending = ""
            phase = .thinking; answer = ""
            speechStream.prepare(tools: tools)
            openReply()
            let interrupted = interruptedTurn; interruptedTurn = false
            let message: String
            VoiceMetrics.shared.mark(.submitSent)
            do { message = try await tools.app.sendVoice("🎙️ " + text, voiceTurn: true, interrupted: interrupted); VoiceMetrics.shared.mark(.submitAck) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try validate(attempt)
                closeTurn(); speechStream.stop()
                notice = error.localizedDescription
                continue
            }
            sessionID = tools.app.selected?.storedID
            try validate(attempt)
            try await respond(to: message, attempt: attempt)
        }
    }

    private func nextUtterance(_ attempt: UUID) async throws -> Utterance {
        if capture == nil, finished.isEmpty {
            phase = .listening; partial = ""
            audio.listeningStarted()
        }
        while finished.isEmpty {
            try validate(attempt)
            if let failure = audio.failure { throw RPCFailure(failure) }
            try await Task.sleep(for: .milliseconds(20))
        }
        return finished.removeFirst()
    }

    /// Live transcript when the profile streams STT, else the compact 16 kHz recording.
    private func transcribe(_ utterance: Utterance, attempt: UUID) async throws -> String {
        if capture == nil { phase = .transcribing }
        VoiceDiag.log("transcribe begin")
        let recording: Data
        do { recording = try await utterance.recording.value }
        catch {
            try validate(attempt)
            utterance.transcriber?.cancel()
            return ""
        }
        try validate(attempt)
        let sample = VoiceSamples.save(recording)
        if let transcriber = utterance.transcriber {
            do {
                let text = try await transcriber.finish()
                try validate(attempt)
                VoiceDiag.log("live transcript chars=\(text.count)")
                VoiceMetrics.shared.mark(.sttFinal, overwrite: true); VoiceMetrics.shared.note("sttChars", Double(text.count)); VoiceMetrics.shared.note("stt", text: "stream")
                VoiceSamples.annotate(sample, text: text, provider: "stream")
                return text
            } catch {
                VoiceDiag.log("live STT failed unavailable=\(transcriber.unavailable): \(error.localizedDescription)")
                if Task.isCancelled { throw CancellationError() }
                try validate(attempt)
                if transcriber.unavailable { liveSTT = false }
            }
        }
        do {
            let text = try await voiceAPI.transcribe(recording, mimeType: audio.mimeType)
            VoiceDiag.log("upload transcript chars=\(text.count) bytes=\(recording.count)")
            VoiceMetrics.shared.mark(.sttFinal, overwrite: true); VoiceMetrics.shared.note("sttChars", Double(text.count)); VoiceMetrics.shared.note("stt", text: "upload")
            VoiceSamples.annotate(sample, text: text, provider: "upload")
            return text
        }
        catch is CancellationError { throw CancellationError() }
        catch {
            VoiceDiag.log("upload STT failed: \(error.localizedDescription)")
            try validate(attempt)
            notice = error.localizedDescription
            return ""
        }
    }

    /// The previous turn must be idle before submitting. A barge-in interrupts it
    /// (retried once); an unconfirmed interruption keeps the conversation listening.
    private func settle(_ attempt: UUID) async throws -> Bool {
        var sent = false
        if let interruption { sent = await interruption.value; self.interruption = nil }
        let started = ProcessInfo.processInfo.systemUptime
        var deadline = started + 8
        var attempts = sent ? 1 : 0
        while tools.app.transcript.running || tools.app.sending {
            try validate(attempt)
            if bargeRequested { return false }
            let now = ProcessInfo.processInfo.systemUptime
            if interruptedTurn, tools.app.transcript.running, attempts < 2, attempts == 0 || now >= deadline {
                attempts += 1
                _ = await sendInterrupt()
                deadline = ProcessInfo.processInfo.systemUptime + 8
                continue
            }
            if now >= deadline {
                notice = "Hermes n’a pas encore terminé sa réponse précédente. Votre phrase n’a pas été envoyée ; elle reste affichée ici."
                return false
            }
            if now - started > 1, notice == nil { notice = Self.busyNotice }
            try await Task.sleep(for: .milliseconds(50))
        }
        if notice == Self.busyNotice || notice == Self.localVoiceNotice { notice = nil }
        return true
    }

    private func respond(to message: String, attempt: UUID) async throws {
        defer { closeTurn() }
        if bargeRequested { return }
        phase = .thinking
        let work = Task { try await self.followReply(to: message, attempt: attempt) }
        response = work
        defer { response = nil }
        do { try await work.value }
        catch {
            // Monitoring already stopped playback and is capturing the interruption.
            if bargeRequested, generation == attempt, !Task.isCancelled { return }
            guard let issue = error as? VoiceTurnIssue, generation == attempt else { throw error }
            speechStream.stop(); audio.stopPlayback()
            notice = issue.message
        }
    }

    private func followReply(to message: String, attempt: UUID) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 600
        var idleSince: TimeInterval?
        var announced = false
        // Bridges the silence while the agent works (tools, slow first token); never over real speech.
        let turnStart = ProcessInfo.processInfo.systemUptime
        var toolSince: TimeInterval?
        var holdingLine = false
        while true {
            try validate(attempt)
            if let failure = audio.failure { throw RPCFailure(failure) }
            let transcript = tools.app.transcript
            let now = ProcessInfo.processInfo.systemUptime
            if !holdingLine, VoiceMetrics.shared.holdingLineEnabled, !isLive, !awaitingUser, reply.display.isEmpty, !speechStream.hasAudio, !audio.playing {
                if toolSince == nil, transcript.toolSteps.contains(where: { $0.state == .running }) { toolSince = now }
                let toolWaited = toolSince.map { now - $0 >= Self.holdingToolDelay } ?? false
                if toolWaited || now - turnStart >= Self.holdingSlowDelay {
                    holdingLine = true; playFiller()
                }
            }
            if transcript.approval != nil || transcript.clarification != nil || transcript.credential != nil {
                if !awaitingUser {
                    awaitingUser = true; phase = .waiting; notice = Self.waitingNotice
                    if !announced { announced = true; speechStream.send("\n\nJ’attends votre réponse dans le chat de l’application.\n\n") }
                }
            } else if awaitingUser {
                awaitingUser = false; phase = .thinking
                if notice == Self.waitingNotice { notice = nil }
            }
            if !awaitingUser, speechStream.hasAudio || audio.playing { phase = .speaking }
            if reply.complete { break }
            if transcript.running || tools.app.sending || awaitingUser { idleSince = nil }
            else if let since = idleSince, now - since >= 1.5 {
                // Completed without a live `message.complete` (reconnect, replay).
                speechStream.send(reply.finish(assistantText(after: message)))
                speechStream.finish(); answer = reply.display
                break
            } else if idleSince == nil { idleSince = now }
            guard now < deadline else { throw VoiceTurnIssue("Hermes travaille encore. Retrouvez sa réponse dans le chat.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        awaitingUser = false
        if notice == Self.waitingNotice { notice = nil }
        if replyStatus == "error" {
            throw VoiceTurnIssue(tools.app.transcript.failure ?? "Hermes n’a pas pu terminer cette réponse. Elle reste dans le chat.")
        }
        let text = reply.display
        answer = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceTurnIssue("Hermes n’a pas renvoyé de réponse à lire.") }
        while !speechStream.needsFallback && !speechStream.drained {
            try await Task.sleep(for: .milliseconds(50)); try validate(attempt)
            if speechStream.hasAudio { phase = .speaking }
            if let failure = audio.failure { throw RPCFailure(failure) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw VoiceTurnIssue("La lecture vocale prend trop de temps. La réponse reste dans le chat.") }
        }
        if !speechStream.needsFallback && speechStream.hasAudio {
            if let failure = speechStream.failure { throw VoiceTurnIssue(failure) }
            VoiceMetrics.shared.mark(.playbackEnd)
            VoiceMetrics.shared.finish(profile: tools.profile)
            speechStream.stop()
            return
        }
        // Server-side synthesis failed or no streaming socket: regular speech endpoint.
        VoiceMetrics.shared.note("ttsFallback", 1)
        VoiceMetrics.shared.note("ttsWhy", text: "unavailable=\(speechStream.unavailable) fallback=\(speechStream.fallback) failure=\(speechStream.failure ?? "-") audio=\(speechStream.hasAudio) ended=\(speechStream.ended)")
        speechStream.stop()
        let speech: String
        do { speech = try await voiceAPI.speech(text) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try validate(attempt)
            VoiceMetrics.shared.note("ttsLocal", 1)
            try await speakLocally(text, attempt: attempt)
            VoiceMetrics.shared.mark(.playbackEnd)
            VoiceMetrics.shared.finish(profile: tools.profile)
            return
        }
        try validate(attempt)
        VoiceMetrics.shared.mark(.firstPCM)
        try await audio.play(speech); try validate(attempt); phase = .speaking
        VoiceMetrics.shared.mark(.playbackStart)
        while audio.playing {
            try await Task.sleep(for: .milliseconds(50)); try validate(attempt)
            if let failure = audio.failure { throw RPCFailure(failure) }
        }
        VoiceMetrics.shared.mark(.playbackEnd)
        VoiceMetrics.shared.finish(profile: tools.profile)
    }

    /// The server's voice refused the reply: the iPhone reads it, so the call keeps talking. The text is in the chat anyway.
    private func speakLocally(_ text: String, attempt: UUID) async throws {
        notice = Self.localVoiceNotice
        guard let rendered = await localSpeech.render(text) else {
            throw VoiceTurnIssue("La voix du serveur est indisponible. La réponse reste dans le chat.")
        }
        try validate(attempt)
        let engine = audio.engine, id = UUID()
        try engine.reservePlayback(id)
        try await engine.preparePCM(sampleRate: rendered.sampleRate, id: id)
        _ = try await engine.enqueuePCM(rendered.pcm, sampleRate: rendered.sampleRate, id: id)
        try await engine.finishPCM(id: id)
        try validate(attempt); phase = .speaking
        while audio.playing {
            try await Task.sleep(for: .milliseconds(50)); try validate(attempt)
            if let failure = audio.failure { throw RPCFailure(failure) }
        }
    }

    /// « Je regarde ça » from the bundled recording, through the call's own audio engine (so echo cancellation
    /// knows it) and without waiting for speech synthesis. The reply's own speech replaces it when it arrives.
    private func playFiller() {
        guard let data = VoiceFiller.next() else { return }
        VoiceMetrics.shared.mark(.filler); VoiceMetrics.shared.note("holdingSpoken", 1)
        let engine = audio.engine, id = UUID()
        Task {
            do {
                try engine.reservePlayback(id)
                try await engine.preparePCM(sampleRate: VoiceFiller.sampleRate, id: id)
                _ = try await engine.enqueuePCM(data, sampleRate: VoiceFiller.sampleRate, id: id)
                try await engine.finishPCM(id: id)
            } catch { /* the reply's speech simply starts without it */ }
        }
    }

    private func openReply(seed: String = "") {
        reply = VoiceReplyText(seed: seed); replyStatus = nil; replyOpen = true
        answer = seed
        if !isLive { speechStream.send(seed) }
    }

    private func closeTurn() {
        replyOpen = false; turnActive = false; barge = nil
        if awaitingUser { awaitingUser = false; if notice == Self.waitingNotice { notice = nil } }
    }

    private func receiveSpeech(_ event: AppModel.SpeechEvent, attempt: UUID) {
        guard generation == attempt, replyOpen else { return }
        switch event {
        case .delta(_, let text):
            VoiceMetrics.shared.mark(.firstDelta)
            let spoken = reply.append(text)
            if isLive { emitLive(done: false) } else { if !spoken.isEmpty { VoiceMetrics.shared.mark(.firstTextToTTS) }; speechStream.send(spoken) }
            answer = reply.display
        case .complete(_, let text, let status):
            VoiceMetrics.shared.mark(.replyComplete)
            if VoiceMetrics.shared.silent { VoiceMetrics.shared.mark(.firstPCM); VoiceMetrics.shared.mark(.playbackStart) }
            replyStatus = status
            let rest = reply.finish(status == "error" ? "" : text)
            if isLive { emitLive(done: true) }
            else {
                if status != "error" { speechStream.send(rest) }
                speechStream.finish()
            }
            answer = reply.display
        }
    }

    private func assistantText(after message: String) -> String {
        let messages = tools.app.transcript.messages
        guard let index = messages.firstIndex(where: { $0.id == message }) else { return "" }
        return messages.dropFirst(index + 1).filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n\n")
    }

    // MARK: Microphone monitor

    private func startMonitoring(_ attempt: UUID) {
        monitor?.cancel()
        let levels = audio.levels()
        monitor = Task { [weak self] in
            for await frame in levels {
                guard let self, self.generation == attempt else { return }
                self.process(frame, attempt: attempt)
            }
            VoiceDiag.log("levels stream ended; generationOK=\(self?.generation == attempt) failure=\(self?.audio.failure ?? "none")")
            // The meter stream only ends when the engine is gone: never leave the call silently stuck.
            guard let self, self.generation == attempt, !Task.isCancelled else { return }
            self.systemInterrupted(self.audio.failure ?? "Le micro s’est arrêté de façon inattendue. Réactivez-le pour reprendre.")
        }
    }

    /// One meter frame, with its own duration: endpoint while capturing, onset while
    /// idle (or still transcribing), barge-in during the agent's turn.
    @ObservationIgnored private var diagFrames = 0
    @ObservationIgnored private var diagMax = 0.0
    @ObservationIgnored private var diagSince = ProcessInfo.processInfo.systemUptime
    private func process(_ frame: VoiceLevel, attempt: UUID) {
        diagFrames += 1; diagMax = max(diagMax, frame.rms)
        if frame.time - diagSince >= 1 || diagFrames == 1 {
            VoiceDiag.log("frames=\(diagFrames) maxRMS=\(Int(diagMax)) phase=\(phase) capture=\(capture != nil) muted=\(inputMuted) awaiting=\(awaitingUser) turn=\(turnActive) state=\(tools.app.state) onsetSpeech=\(onset.hasSpeech) threshold=\(Int(preferences.threshold)) floor=\(Int(ambient.value))")
            diagFrames = 0; diagMax = 0; diagSince = frame.time
        }
        if tools.app.state != .connected {
            systemInterrupted("La connexion à Hermès a été interrompue. La réponse reste dans le chat.")
            return
        }
        let playing = audio.playing
        let next = phase == .speaking ? audio.outputLevel : inputMuted ? 0 : VoiceActivity.normalizedLevel(rms: frame.rms)
        if abs(level - next) > 0.015 { level = next }
        guard !inputMuted else { return }
        if let utterance = capture {
            utterance.elapsed += frame.duration
            if utterance.activity.sample(frame) || utterance.elapsed >= preferences.maxRecordingSeconds { endUtterance() }
            return
        }
        if !playing {
            // Learn only quiet input below the onset level; never speaker bleed.
            ambient.sample(rms: frame.rms, duration: frame.duration, multiplier: 2)
            onset.adapt(noiseFloor: ambient.value)
        }
        guard !awaitingUser else { return }
        if turnActive {
            guard var detector = barge else { return }
            let tripped = detector.sample(frame, playing: playing)
            barge = detector
            if tripped { interruptForSpeech(attempt) }
        } else if phase != .ready {
            _ = onset.sample(frame)
            if onset.hasSpeech { beginUtterance(barge: false, spoken: "", attempt: attempt) }
        }
    }

    private func beginUtterance(barge: Bool, spoken: String, attempt: UUID) {
        guard capture == nil else { return }
        VoiceDiag.log("onset → begin utterance (liveSTT=\(liveSTT))")
        VoiceMetrics.shared.utteranceStarted(barge: barge)
        let transcriber = liveSTT ? StreamingTranscriber(tools: tools) : nil
        transcriber?.onPartial = { [weak self] text in
            guard let self, self.generation == attempt else { return }
            if !text.isEmpty { VoiceMetrics.shared.mark(.sttPartial) }
            self.partial = text
        }
        let utterance = Utterance(activity: VoiceActivity(threshold: preferences.threshold, silenceDuration: preferences.endpointSilence,
                                                          confirmedSpeech: true, noiseFloor: ambient.value),
                                  barge: barge, spoken: spoken, transcriber: transcriber)
        capture = utterance
        onset = VoiceActivity(threshold: preferences.threshold, silenceDuration: preferences.endpointSilence, noiseFloor: ambient.value)
        partial = ""; phase = .listening
        let audio = audio, maxSeconds = preferences.maxRecordingSeconds
        utterance.recording = Task {
            let pcm = try await audio.startCapture(includePreRoll: true, maxSeconds: maxSeconds)
            let pump = Task { for await chunk in pcm { transcriber?.push(chunk) } }
            await utterance.untilEnded()
            do { try Task.checkCancellation() } catch { pump.cancel(); throw error }
            let recording = try await audio.finish()
            await pump.value
            return recording
        }
    }

    private func endUtterance() {
        guard let utterance = capture else { return }
        capture = nil
        utterance.end()
        VoiceMetrics.shared.mark(.endpoint, overwrite: true)
        finished.append(utterance)
        if !turnActive { phase = .transcribing }
        // Warm the reply's speech socket while the words are transcribed.
        speechStream.prepare(tools: tools)
    }

    private func dropCapture() {
        guard let utterance = capture else { return }
        capture = nil
        utterance.transcriber?.cancel(); utterance.recording?.cancel(); utterance.end()
        audio.cancelCapture()
    }

    private func interruptForSpeech(_ attempt: UUID) {
        guard generation == attempt, capture == nil else { return }
        let speaking = phase == .speaking || audio.playing
        let spoken = speaking ? reply.display : ""
        let running = tools.app.transcript.running
        bargeRequested = true; barge = nil
        if running || speaking || replyOpen { interruptedTurn = true }
        speechStream.stop(); audio.stopPlayback(); response?.cancel()
        if running { interruption = Task { await self.sendInterrupt() } }
        beginUtterance(barge: true, spoken: spoken, attempt: attempt)
    }

    private func sendInterrupt() async -> Bool {
        guard let runtimeID = tools.app.selected?.runtimeID, !runtimeID.isEmpty else { return false }
        do { try await tools.app.interruptVoice(connectionID: tools.connectionID, profile: tools.profile, runtimeID: runtimeID); return true }
        catch { return false }
    }

    private static func isEcho(_ transcript: String, spoken: String) async -> Bool {
        await Task.detached(priority: .userInitiated) { VoiceEcho.isEcho(transcript, spoken: spoken) }.value
    }

    /// One line of internal state, for the bench's failure reports.
    func benchState() -> String {
        let t = tools.app.transcript
        return "phase=\(phase) turnActive=\(turnActive) replyOpen=\(replyOpen) awaiting=\(awaitingUser) capture=\(capture != nil) finished=\(finished.count) "
            + "speechAudio=\(speechStream.hasAudio) ended=\(speechStream.ended) fallback=\(speechStream.fallback) unavailable=\(speechStream.unavailable) "
            + "queued=\(String(format: "%.1f", speechStream.queuedSeconds)) running=\(t.running) sending=\(tools.app.sending) approval=\(t.approval != nil) "
            + "answerChars=\(answer.count) replyComplete=\(reply.complete) status=\(replyStatus ?? "-") error=\(error ?? "-") notice=\(notice ?? "-")"
    }

    // MARK: GPT-Live

    private func runLive(_ preferences: VoicePreferences, attempt: UUID, configureStone: Bool) async throws {
        let status: JSONValue
        do { status = try await tools.request("/api/audio/voice-live/status") }
        catch let failure as RPCFailure where [404, 405].contains(failure.code) {
            throw VoiceLiveUnavailable("Ce serveur Hermes doit être mis à jour pour proposer GPT-Live. Vous pouvez utiliser la voix standard.")
        }
        try validate(attempt)
        guard status["ok"].bool, status["available"].bool else {
            throw VoiceLiveUnavailable("Ajoutez la clé OpenAI sur le serveur Hermes, accessible au profil « \(tools.profile) », puis réessayez GPT-Live.")
        }
        if configureStone {
            do {
                _ = try await tools.request("/api/config", method: "PUT", body: ["config": ["voice": [
                    "voice_chat_mode": "gpt-live", "gpt_live": ["voice": "stone"]
                ]]])
            } catch is CancellationError { throw CancellationError() }
            catch { try validate(attempt); throw VoiceLiveUnavailable(error.localizedDescription) }
            try validate(attempt)
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--live-transport-fixture"),
           tools.app.activeConnection?.endpoint.baseURL.host == "127.0.0.1" {
            VoiceLiveTransport.useSilentFixtureAudio()
        }
        #endif
        let transport = VoiceLiveTransport(); live = transport
        liveTranscript = VoiceLiveTranscript()
        lastLiveSpeechAt = -TimeInterval.infinity; lastLiveOutputAt = -TimeInterval.infinity
        heard = ""; answer = ""
        transport.onEvent = { [weak self] event in
            guard let self, self.generation == attempt else { return }
            _ = self.liveTranscript.receive(event)
            if event["type"].string == "session.input_transcript.delta" {
                self.lastLiveSpeechAt = ProcessInfo.processInfo.systemUptime
                self.heard = self.liveTranscript.prompt
                if !self.awaitingUser { self.phase = .listening }
                self.stopTimer?.cancel()
                let utterance = self.heard
                self.stopTimer = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                    guard let self, self.generation == attempt else { return }
                    if VoiceActivity.isStop(utterance, phrases: preferences.stopPhrases) { self.pause() }
                }
            } else if event["type"].string == "session.output_transcript.delta" {
                self.lastLiveSpeechAt = ProcessInfo.processInfo.systemUptime
                self.lastLiveOutputAt = self.lastLiveSpeechAt
                self.answer = self.liveTranscript.turns.last?.text ?? ""
                if !self.awaitingUser { self.phase = .speaking }
            }
        }
        let history = VoiceLiveProtocol.history(tools.app.transcript.messages.map { ($0.role, $0.text) })
        await VoiceAudioEngine.settleAudioWork()
        try validate(attempt)
        do {
            try await transport.start(history: history) { [tools] body in
                try await tools.request("/api/audio/voice-live/session", method: "POST", body: body)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try validate(attempt)
            throw VoiceLiveUnavailable(error.localizedDescription)
        }
        try validate(attempt)
        tools.app.speechSink = { [weak self] event in self?.receiveSpeech(event, attempt: attempt) }
        try transport.setMuted(inputMuted)
        try transport.send(VoiceLiveProtocol.append("instructions", delegation: nil,
            content: "Parle en français, naturellement et avec chaleur. Délègue à Hermes les demandes nécessitant ses connaissances, sa mémoire ou ses outils. Ne prétends jamais avoir exécuté ses actions avant son résultat."))
        phase = .listening
        if tools.app.transcript.running, let message = tools.app.transcript.messages.last(where: { $0.role == "user" }) {
            openLiveReply(delegation: nil, seed: assistantText(after: message.id))
            try await relayLiveResponse(message.id, attempt: attempt, startedAt: ProcessInfo.processInfo.systemUptime)
        }
        while true {
            try validate(attempt); try transport.check()
            for id in liveTranscript.takeDropped() {
                try transport.send(VoiceLiveProtocol.append("commentary", delegation: id,
                    content: "Hermes n’a pas reçu la transcription de cette demande. Demande à l’utilisateur de la répéter."))
                notice = "Une demande vocale n’a pas été transcrite. Répétez-la si besoin."
            }
            if let next = try liveTranscript.nextRequest(now: ProcessInfo.processInfo.systemUptime) {
                if VoiceActivity.isStop(next.prompt, phrases: preferences.stopPhrases) { return }
                // New delegations wait for the active turn; conversational interruptions
                // must not cancel backend actions or discard their final result.
                phase = .thinking
                transport.mark("hermes_submit")
                try transport.send(VoiceLiveProtocol.append("thinking", delegation: next.id, content: "Hermes examine la demande. Le travail n’est pas encore terminé."))
                guard try await waitForHermes(attempt, transport: transport) else {
                    try transport.send(VoiceLiveProtocol.append("commentary", delegation: next.id,
                        content: "Hermes est encore occupé par une autre tâche ; cette demande n’a pas été transmise."))
                    phase = .listening; continue
                }
                openLiveReply(delegation: next.id)
                let message: String
                do { message = try await tools.app.sendVoice(next.prompt, liveContext: next.context) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    try validate(attempt)
                    replyOpen = false; notice = error.localizedDescription; phase = .listening
                    try transport.send(VoiceLiveProtocol.append("commentary", delegation: next.id, content: "La demande n’a pas pu être transmise à Hermes."))
                    continue
                }
                transport.mark("hermes_admitted")
                sessionID = tools.app.selected?.storedID
                try validate(attempt)
                try await relayLiveResponse(message, attempt: attempt, startedAt: next.receivedAt)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Another Hermes turn (chat, resumed turn) is still running: queue, don't fail.
    private func waitForHermes(_ attempt: UUID, transport: VoiceLiveTransport) async throws -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        while tools.app.transcript.running || tools.app.sending {
            try validate(attempt); try transport.check()
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard elapsed < 600 else { return false }
            if elapsed > 1.5, notice == nil { notice = Self.busyNotice }
            try await Task.sleep(for: .milliseconds(100))
        }
        if notice == Self.busyNotice || notice == Self.localVoiceNotice { notice = nil }
        return true
    }

    private func openLiveReply(delegation: String?, seed: String = "") {
        liveDelegation = delegation; liveCursor = VoiceLiveReplyCursor(); liveFirstResultAt = nil
        reply = VoiceReplyText(seed: seed); replyStatus = nil; replyOpen = true
        if !seed.isEmpty { emitLive(done: false) }
    }

    /// Completed clauses go to GPT-Live as they arrive; receipts are checked in bulk
    /// (`drain`) instead of awaiting each append.
    private func emitLive(done: Bool) {
        guard let live else { return }
        let delta = liveCursor.delta(reply.text, done: done)
        for chunk in VoiceLiveProtocol.chunks(delta) {
            if liveFirstResultAt == nil {
                liveFirstResultAt = ProcessInfo.processInfo.systemUptime
                live.mark("hermes_first_result")
            }
            // A failed send surfaces through live.check() in the relay loop.
            try? live.send(VoiceLiveProtocol.append("commentary", delegation: liveDelegation, content: chunk))
        }
    }

    private func relayLiveResponse(_ message: String, attempt: UUID, startedAt: TimeInterval) async throws {
        let delegation = liveDelegation
        var lastActivity: String?
        var progress = VoiceLiveProgress(startedAt: startedAt)
        var sawText = false, announced = false
        var idleSince: TimeInterval?
        let deadline = ProcessInfo.processInfo.systemUptime + 600
        defer {
            replyOpen = false
            if awaitingUser { awaitingUser = false; if notice == Self.waitingNotice { notice = nil } }
        }
        while true {
            try validate(attempt)
            guard let live else { throw CancellationError() }
            try live.check()
            let transcript = tools.app.transcript
            let now = ProcessInfo.processInfo.systemUptime
            if transcript.approval != nil || transcript.clarification != nil || transcript.credential != nil {
                // The voice never approves; the live session stays open meanwhile.
                if !awaitingUser {
                    awaitingUser = true; phase = .waiting; notice = Self.waitingNotice
                    if !announced {
                        announced = true
                        try live.send(VoiceLiveProtocol.append("commentary", delegation: delegation,
                            content: "Hermes attend que l’utilisateur réponde à sa demande dans le chat de l’application avant de continuer."))
                    }
                }
                try await Task.sleep(for: .milliseconds(200)); continue
            } else if awaitingUser {
                awaitingUser = false; phase = .thinking
                if notice == Self.waitingNotice { notice = nil }
            }
            if !reply.text.isEmpty, !sawText { sawText = true; live.mark("hermes_first_text") }
            if reply.complete { break }
            if transcript.running || tools.app.sending { idleSince = nil }
            else if let since = idleSince, now - since >= 1.5 {
                _ = reply.finish(assistantText(after: message)); emitLive(done: true)
                break
            } else if idleSince == nil { idleSince = now }
            if let update = progress.next(now: now, lastSpeechAt: lastLiveSpeechAt, lastOutputAt: lastLiveOutputAt,
                                          running: transcript.running, receivedReply: liveFirstResultAt != nil,
                                          tools: transcript.toolSteps) {
                try live.send(VoiceLiveProtocol.append("commentary", delegation: delegation, content: update))
            }
            if let activity = transcript.activity, activity != lastActivity {
                lastActivity = activity
                try live.send(VoiceLiveProtocol.append("thinking", delegation: delegation, content: String(activity.prefix(200))))
            }
            guard now < deadline else {
                notice = "Hermes travaille encore. Retrouvez sa réponse dans le chat."
                phase = .listening; return
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        guard let live else { throw CancellationError() }
        if replyStatus == "error" {
            notice = tools.app.transcript.failure ?? "Hermes n’a pas pu terminer cette demande."
            try live.send(VoiceLiveProtocol.append("commentary", delegation: delegation, content: "Hermes n’a pas pu terminer cette demande."))
        }
        live.mark("hermes_complete")
        try await live.drain()
        // Receipt confirms context delivery only. Detect a completely silent
        // return instead of treating an unspoken result as a successful call.
        if let firstResultAt = liveFirstResultAt {
            let speechDeadline = ProcessInfo.processInfo.systemUptime + 12
            while lastLiveOutputAt < firstResultAt {
                try validate(attempt); try live.check()
                guard ProcessInfo.processInfo.systemUptime < speechDeadline else {
                    live.mark("speech_missing")
                    notice = "Hermès a répondu, mais GPT-Live ne l’a pas lu à voix haute. La réponse reste disponible dans le chat."
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try validate(attempt)
        phase = .listening
    }

    // MARK: Lifecycle

    private var voiceAPI: NativeVoiceAPI {
        NativeVoiceAPI { [tools] path, body, rpc in try await tools.request(path, method: "POST", body: body, rpc: rpc) }
    }
    private func validate(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard attempt == generation, tools.connectionID == tools.app.activeConnection?.id,
              tools.profile == tools.app.profile, sessionID == tools.app.selected?.storedID else { throw CancellationError() }
        guard tools.app.state == .connected else { throw RPCFailure("La connexion à Hermès a été interrompue. Retrouvez la réponse dans le chat, puis reprenez la voix.") }
    }
    private func acquireLeases(_ attempt: UUID) async {
        for path in ["/api/audio/tts-lease", "/api/audio/stt-lease"] {
            let id = "ios-" + UUID().uuidString
            leases.append((path, id))
            _ = try? await tools.request(path, method: "POST", body: ["lease": .string(id), "active": true])
            if generation != attempt { return }
        }
    }
    private func releaseLeases() {
        let held = leases; leases = []
        let tools = tools
        for lease in held {
            Task { _ = try? await tools.request(lease.path, method: "POST", body: ["lease": .string(lease.id), "active": false]) }
        }
    }
    private func stopLocalAudio() {
        tools.app.speechSink = nil
        live?.close(); live = nil; liveTranscript = VoiceLiveTranscript()
        stopTimer?.cancel(); stopTimer = nil
        monitor?.cancel(); monitor = nil; response?.cancel(); response = nil
        interruption?.cancel(); interruption = nil
        dropCapture()
        for utterance in finished { utterance.transcriber?.cancel(); utterance.recording?.cancel(); utterance.end() }
        finished.removeAll()
        replyOpen = false; turnActive = false; awaitingUser = false; barge = nil
        bargeRequested = false; interruptedTurn = false
        speechStream.stop(); audio.cleanup(); level = 0; partial = ""
    }
    func pause() {
        generation = UUID(); operation?.cancel(); operation = nil
        stopLocalAudio(); phase = .paused; tools.app.voiceActive = false; releaseLeases()
    }
    func toggleMicrophone() {
        guard !tools.app.demo else { return }
        if operation == nil { start(); return }
        inputMuted.toggle()
        if let live {
            do { try live.setMuted(inputMuted) } catch { pause(); self.error = error.localizedDescription }
        } else {
            if inputMuted { dropCapture() }
            audio.setInputMuted(inputMuted)
            onset = VoiceActivity(threshold: preferences.threshold, silenceDuration: preferences.endpointSilence, noiseFloor: ambient.value)
            if barge != nil { barge = VoiceBargeIn(preferences: preferences, noiseFloor: ambient.value) }
        }
        if inputMuted { level = 0 }
    }
    func systemInterrupted(_ message: String) {
        guard operation != nil else { return }
        pause(); error = message
    }
}

/// One captured utterance: endpoint state, live STT and the local recording (fallback).
@MainActor
private final class Utterance {
    var activity: VoiceActivity
    var elapsed = 0.0
    let barge: Bool
    /// Reply text playing when a barge-in started (echo guard).
    let spoken: String
    let transcriber: StreamingTranscriber?
    var recording: Task<Data, Error>!
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(activity: VoiceActivity, barge: Bool, spoken: String, transcriber: StreamingTranscriber?) {
        self.activity = activity; self.barge = barge; self.spoken = spoken; self.transcriber = transcriber
    }
    func end() { ended = true; waiter?.resume(); waiter = nil }
    func untilEnded() async {
        guard !ended else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// Non-fatal: the turn failed but the conversation keeps listening.
private struct VoiceTurnIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// GPT-Live is not available for this call: offer the standard engine.
private struct VoiceLiveUnavailable: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The call on screen: what the Live Activity's buttons act on.
@MainActor
enum VoiceCallRemote {
    static weak var current: VoiceConversation?
}
