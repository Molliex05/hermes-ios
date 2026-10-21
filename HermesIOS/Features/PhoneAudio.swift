import Foundation
import AVFoundation
import Observation

/// Main-thread presentation/permission boundary. The shared duplex engine performs all
/// graph/session work, metering, 16 kHz conversion, recording and playback off MainActor.
@MainActor @Observable
final class PhoneAudio {
    @ObservationIgnored let engine = VoiceAudioEngine()
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var playbackGeneration = UUID()
    private(set) var inputMuted = false
    #if DEBUG
    var fixture = false
    @ObservationIgnored private var fixtureStarted: Date?
    @ObservationIgnored private var fixtureRecording = false
    @ObservationIgnored private var fixtureListenCount = 0
    @ObservationIgnored private var fixturePlaybackStarted: Date?
    @ObservationIgnored private var fixtureBargeConsumed = false
    @ObservationIgnored private var fixtureMeter: Task<Void, Never>?
    #endif

    var mimeType: String { "audio/wav" }
    var recording: Bool {
        #if DEBUG
        if fixture { return fixtureRecording }
        #endif
        return engine.snapshot.capturing
    }
    var playing: Bool { engine.snapshot.playing }
    var outputLevel: Double { engine.snapshot.outputLevel }
    var failure: String? { engine.snapshot.failure }

    func prepare() async throws {
        let attempt = generation
        #if DEBUG
        if fixture {
            try await engine.prepareFixture()
            try validate(attempt)
            return
        }
        #endif
        if !engine.snapshot.monitoring {
            guard await AVAudioApplication.requestRecordPermission() else {
                throw RPCFailure("Autorisez le microphone dans les réglages iOS pour parler avec Hermes.")
            }
            try validate(attempt)
            try await engine.prepare()
        }
        try validate(attempt)
    }

    /// Timestamped meter frames for endpointing and barge-in, measured on the audio thread.
    func levels() -> AsyncStream<VoiceLevel> {
        #if DEBUG
        if fixture {
            let (stream, continuation) = AsyncStream<VoiceLevel>.makeStream(bufferingPolicy: .bufferingNewest(256))
            fixtureMeter?.cancel()
            fixtureMeter = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
                    guard let self else { break }
                    continuation.yield(VoiceLevel(time: ProcessInfo.processInfo.systemUptime, duration: 0.02,
                                                  rms: VoiceActivity.rms(decibels: self.fixturePower())))
                }
                continuation.finish()
            }
            return stream
        }
        #endif
        return engine.levels()
    }

    /// Marks a new listening phase (the loopback fixture speaks once per phase).
    func listeningStarted() {
        #if DEBUG
        if fixture { fixtureStarted = Date(); fixtureListenCount += 1 }
        #endif
    }

    /// Starts one utterance while leaving the shared microphone/output graph running. The
    /// 1 s pre-roll preserves the syllables that confirmed speech. Returns live 16 kHz PCM.
    func startCapture(includePreRoll: Bool = true, maxSeconds: Double = 120) async throws -> AsyncStream<Data> {
        let attempt = generation
        try await prepare()
        try validate(attempt)
        guard !inputMuted else { throw RPCFailure("Le microphone est en pause.") }
        #if DEBUG
        if fixture {
            fixtureRecording = true
            return AsyncStream { $0.finish() }
        }
        #endif
        let stream = try await engine.startCapture(includePreRoll: includePreRoll, maxSeconds: maxSeconds)
        try validate(attempt)
        return stream
    }

    func finish() async throws -> Data {
        let attempt = generation
        #if DEBUG
        if fixture {
            try validate(attempt)
            guard fixtureRecording else { throw RPCFailure("Aucun enregistrement disponible.") }
            fixtureRecording = false
            return Data(base64Encoded: "UklGRuQSAABXQVZFZm10IBAAAAABAAEAwF0AAIC7AAACABAAZGF0YcASAAA=")! + Data(repeating: 0, count: 4800)
        }
        #endif
        let data = try await engine.finishCapture()
        try validate(attempt)
        return data
    }

    func cancelCapture() {
        #if DEBUG
        if fixture { fixtureRecording = false; return }
        #endif
        engine.cancelCapture()
    }

    func play(_ dataURL: String) async throws {
        let attempt = generation, playback = UUID()
        playbackGeneration = playback
        try engine.reservePlayback(playback)
        do {
            try await engine.playFile(dataURL, id: playback)
            try validate(attempt)
            guard playback == playbackGeneration else { throw CancellationError() }
        } catch {
            engine.stopPlayback(id: playback)
            throw error
        }
    }

    func setInputMuted(_ muted: Bool) {
        inputMuted = muted
        #if DEBUG
        if muted { fixtureRecording = false; fixtureStarted = nil }
        #endif
        engine.setInputMuted(muted)
    }

    func stopPlayback() {
        playbackGeneration = UUID()
        engine.stopPlayback()
    }

    func cleanup() {
        generation = UUID(); playbackGeneration = UUID(); inputMuted = false
        #if DEBUG
        fixtureMeter?.cancel(); fixtureMeter = nil
        fixtureRecording = false; fixtureStarted = nil; fixtureListenCount = 0
        fixturePlaybackStarted = nil; fixtureBargeConsumed = false
        #endif
        engine.cleanup()
    }

    #if DEBUG
    /// Synthetic microphone for the loopback UI fixture: one 0.7 s utterance per listening
    /// phase (after 18 s on the quiet fixture's first one) and, for the barge fixture,
    /// speech 1.0–1.7 s into the first reply playback. Wall time, not read count.
    private func fixturePower() -> Double {
        guard !inputMuted else { return -90 }
        if !playing {
            // A playback cut after the burst began is the fixture's one interruption.
            if let started = fixturePlaybackStarted, Date().timeIntervalSince(started) >= 1 { fixtureBargeConsumed = true }
            fixturePlaybackStarted = nil
        } else if !fixtureBargeConsumed, ProcessInfo.processInfo.arguments.contains("--voice-barge-fixture") {
            if fixturePlaybackStarted == nil { fixturePlaybackStarted = Date() }
            let elapsed = Date().timeIntervalSince(fixturePlaybackStarted ?? Date())
            return elapsed >= 1 && elapsed < 1.7 ? -14 : -90
        }
        guard let fixtureStarted else { return -90 }
        let silence = ProcessInfo.processInfo.arguments.contains("--voice-quiet-fixture") && fixtureListenCount == 1 ? 18.0 : 0
        let elapsed = Date().timeIntervalSince(fixtureStarted)
        return elapsed >= silence && elapsed < silence + 0.7 ? -20 : -90
    }
    #endif

    private func validate(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard attempt == generation else { throw CancellationError() }
        if let failure { throw RPCFailure(failure) }
    }
}
