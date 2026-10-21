import Foundation
import Observation

/// One `/api/audio/speak-stream` session per spoken reply. Hermes owns sentence splitting,
/// Markdown normalization, voice and provider choice. The socket opens early (while the
/// user's words are transcribed) and text is sent the moment deltas arrive; the server
/// sends `start` only with its first PCM chunk, so nothing here waits for it. PCM is
/// scheduled through PhoneAudio's duplex graph without touching the microphone.
@MainActor @Observable
final class NativeSpeechStream {
    private var receivedAudio = false
    /// `end`, `fallback`, a failure or an unavailable socket was observed.
    private(set) var ended = false
    /// The server could not synthesize this reply: use `POST /api/audio/speak`.
    private(set) var fallback = false
    /// No streaming socket (older server, refused upgrade): use `POST /api/audio/speak`.
    private(set) var unavailable = false
    private var streamFailure: String?
    private let audio: PhoneAudio
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var outbox: [JSONValue] = []
    @ObservationIgnored private var doneSent = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var playbackID: UUID?
    @ObservationIgnored private(set) var openedAt: Double?

    init(audio: PhoneAudio) { self.audio = audio }

    var failure: String? { streamFailure ?? audio.failure }
    var isActive: Bool { opening != nil || socket != nil }
    var queuedSeconds: Double {
        let snapshot = audio.engine.snapshot
        return snapshot.outputID == playbackID && playbackID != nil ? snapshot.queuedSeconds : 0
    }
    // Large websocket frames are decoded with backpressure. Report the very first
    // scheduled buffer while enqueuePCM is still awaiting the remainder of that frame.
    var hasAudio: Bool { VoiceMetrics.shared.silent || receivedAudio || queuedSeconds > 0.001 }
    var drained: Bool { VoiceMetrics.shared.silent || (ended && queuedSeconds < 0.001) }
    /// The reply must be spoken through the regular speech endpoint instead.
    var needsFallback: Bool { !VoiceMetrics.shared.silent && (unavailable || fallback || (streamFailure != nil && !hasAudio)) }

    /// Opens a fresh session unless one is already warm. Never throws: a socket that
    /// cannot open marks the session `unavailable`.
    func prepare(tools: NativeToolSession) {
        guard !VoiceMetrics.shared.silent, !isActive || ended else { return }
        stop()
        let attempt = generation
        openedAt = ProcessInfo.processInfo.systemUptime
        opening = Task { [weak self] in
            do {
                let ws = try await tools.app.speechSocket(connectionID: tools.connectionID, profile: tools.profile)
                guard let self, self.generation == attempt, !Task.isCancelled else { ws.cancel(with: .goingAway, reason: nil); return }
                ws.maximumMessageSize = 2 * 1024 * 1024
                self.socket = ws; self.opening = nil
                ws.resume()
                self.reader = Task { [weak self] in await self?.read(ws, attempt: attempt) }
                for frame in self.outbox { self.transmit(frame, on: ws, attempt: attempt) }
                self.outbox.removeAll()
            } catch {
                guard let self, self.generation == attempt else { return }
                self.opening = nil; self.unavailable = true; self.ended = true
            }
        }
    }

    /// Sends text as it arrives (in order); queued while the socket is still opening.
    func send(_ text: String) {
        guard !VoiceMetrics.shared.silent, !text.isEmpty, !doneSent else { return }
        enqueue(["text": .string(text)])
    }

    /// End of the reply's text. The socket stays open until the server's `end`.
    func finish() {
        guard !VoiceMetrics.shared.silent, !doneSent else { return }
        doneSent = true
        enqueue(["done": true])
    }

    /// Barge-in/teardown: disconnecting is the server's stop signal.
    func stop() {
        generation = UUID(); opening?.cancel(); opening = nil; reader?.cancel(); reader = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        if let playbackID { audio.engine.stopPlayback(id: playbackID) }
        playbackID = nil; outbox.removeAll(); doneSent = false; openedAt = nil
        ended = false; fallback = false; unavailable = false; receivedAudio = false; streamFailure = nil
    }

    private func enqueue(_ frame: JSONValue) {
        if let socket { transmit(frame, on: socket, attempt: generation) }
        else if opening != nil { outbox.append(frame) }
    }

    private func transmit(_ frame: JSONValue, on ws: URLSessionWebSocketTask, attempt: UUID) {
        guard let data = try? frame.data() else { return }
        // Completion-handler sends keep MainActor call order on the socket.
        ws.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt, !self.ended else { return }
                self.streamFailure = "La lecture vocale a été interrompue."; self.ended = true
            }
        }
    }

    private func read(_ ws: URLSessionWebSocketTask, attempt: UUID) async {
        var parser = SpeakStreamReader()
        do {
            while !Task.isCancelled {
                try validate(attempt)
                // A frame itself is bounded; enqueuePCM additionally splits large
                // frames into 200ms blocks and applies <=3.2s decoded backpressure.
                while queuedSeconds > 3 {
                    try await Task.sleep(for: .milliseconds(25))
                    try validate(attempt)
                }
                let message = try await ws.receive()
                try validate(attempt)
                switch message {
                case .string(let text):
                    switch try parser.text(text) {
                    case .prepare(let rate):
                        let playback = UUID()
                        playbackID = playback
                        try audio.engine.reservePlayback(playback)
                        try await audio.engine.preparePCM(sampleRate: rate, id: playback)
                    case .finish:
                        if let playbackID { try await audio.engine.finishPCM(id: playbackID) }
                        try validate(attempt)
                        ended = true; return
                    case .fallback:
                        fallback = true; ended = true; return
                    case nil: break
                    }
                case .data(let data):
                    let rate = try parser.binary()
                    guard let playbackID else { throw RPCFailure("Flux vocal Hermes invalide.") }
                    VoiceMetrics.shared.mark(.firstPCM)
                    let produced = try await audio.engine.enqueuePCM(data, sampleRate: rate, id: playbackID)
                    VoiceMetrics.shared.mark(.playbackStart)
                    try validate(attempt)
                    if produced { receivedAudio = true }
                @unknown default: break
                }
            }
        } catch {
            guard generation == attempt, !Task.isCancelled, !(error is CancellationError) else { return }
            let code = (ws.response as? HTTPURLResponse)?.statusCode
            if parser.sampleRate == nil, code == 404 || code == 405 { unavailable = true }
            else { streamFailure = error.localizedDescription }
            ended = true
        }
    }

    private func validate(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
    }
}
