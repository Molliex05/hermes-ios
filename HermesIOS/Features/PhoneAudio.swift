import Foundation
import AVFoundation
import Observation

/// Main-thread presentation/permission boundary. The shared duplex engine performs all
/// graph/session work, recording, conversion, and playback on its serial audio worker.
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
    @ObservationIgnored private var fixtureCaptureCount = 0
    @ObservationIgnored private var fixturePlaybackStarted: Date?
    @ObservationIgnored private var fixtureBargeConsumed = false
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

    /// Starts one utterance while leaving the shared microphone/output graph running.
    /// On barge-in, the bounded pre-roll preserves the syllables that triggered detection.
    func start(includePreRoll: Bool = false) async throws {
        let attempt = generation
        try await prepare()
        try validate(attempt)
        guard !inputMuted else { throw RPCFailure("Le microphone est en pause.") }
        #if DEBUG
        if fixture {
            if includePreRoll { fixtureBargeConsumed = true }
            fixtureStarted = Date(); fixtureRecording = true; fixtureCaptureCount += 1
            return
        }
        #endif
        try await engine.startCapture(includePreRoll: includePreRoll)
        try validate(attempt)
    }

    func power() -> Double {
        #if DEBUG
        if fixture {
            guard !inputMuted else { return -90 }
            if !fixtureRecording {
                guard !fixtureBargeConsumed, ProcessInfo.processInfo.arguments.contains("--voice-barge-fixture") else { return -90 }
                guard playing else { fixturePlaybackStarted = nil; return -90 }
                if fixturePlaybackStarted == nil { fixturePlaybackStarted = Date() }
                let elapsed = Date().timeIntervalSince(fixturePlaybackStarted ?? Date())
                return elapsed >= 1 && elapsed < 1.7 ? -14 : -90
            }
            guard let fixtureStarted else { return -90 }
            // Wall time, not number of reads: animation and VAD can sample independently.
            let silence = ProcessInfo.processInfo.arguments.contains("--voice-quiet-fixture") && fixtureCaptureCount == 1 ? 18.0 : 0
            let elapsed = Date().timeIntervalSince(fixtureStarted)
            return elapsed >= silence && elapsed < silence + 0.7 ? -20 : -90
        }
        #endif
        return engine.snapshot.inputPower
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
        fixtureRecording = false; fixtureStarted = nil; fixtureCaptureCount = 0
        fixturePlaybackStarted = nil; fixtureBargeConsumed = false
        #endif
        engine.cleanup()
    }

    private func validate(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard attempt == generation else { throw CancellationError() }
        if let failure { throw RPCFailure(failure) }
    }
}
