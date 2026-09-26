import Foundation
import Observation

/// Hermes owns sentence splitting, Markdown normalization, voice and provider choice.
/// This transport schedules PCM through PhoneAudio's existing duplex graph; it never
/// changes AVAudioSession category or tears down the continuously monitored microphone.
@MainActor @Observable
final class NativeSpeechStream {
    private var receivedAudio = false
    private(set) var ended = false
    private var streamFailure: String?
    private let audio: PhoneAudio
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var playbackID: UUID?

    init(audio: PhoneAudio) { self.audio = audio }

    var failure: String? { streamFailure ?? audio.failure }
    var queuedSeconds: Double {
        let snapshot = audio.engine.snapshot
        return snapshot.outputID == playbackID ? snapshot.queuedSeconds : 0
    }
    // Large websocket frames are decoded with backpressure. Report the very first
    // scheduled buffer while enqueuePCM is still awaiting the remainder of that frame.
    var hasAudio: Bool { receivedAudio || queuedSeconds > 0.001 }
    var drained: Bool { ended && queuedSeconds < 0.001 }

    func open(tools: NativeToolSession) async throws -> Bool {
        stop()
        let attempt = generation
        let ws = try await tools.app.speechSocket(connectionID: tools.connectionID, profile: tools.profile)
        do { try validate(attempt) }
        catch { ws.cancel(with: .goingAway, reason: nil); throw error }
        socket = ws
        ws.maximumMessageSize = 2 * 1024 * 1024
        ws.resume()
        let deadline = Task {
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { ws.cancel(with: .goingAway, reason: nil) }
        }
        defer { deadline.cancel() }
        do {
            guard case .string(let text) = try await ws.receive() else { throw RPCFailure("Flux vocal Hermes invalide.") }
            try validate(attempt)
            let event = try JSONValue.decode(Data(text.utf8))
            if event["type"].string == "fallback" { stop(); return false }
            let rate = event["sample_rate"].double
            guard event["type"].string == "start", (8000...96000).contains(rate), event["channels"].int == 1 else {
                throw RPCFailure("Format vocal Hermes non pris en charge.")
            }
            let playback = UUID()
            playbackID = playback
            try audio.engine.reservePlayback(playback)
            try await audio.engine.preparePCM(sampleRate: rate, id: playback)
            try validate(attempt)
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        guard let self else { return }
                        try self.validate(attempt)
                        // A frame itself is bounded; enqueuePCM additionally splits large
                        // frames into 200ms blocks and applies <=3.2s decoded backpressure.
                        while self.queuedSeconds > 3 {
                            try await Task.sleep(for: .milliseconds(25))
                            try self.validate(attempt)
                        }
                        let message = try await ws.receive()
                        try self.validate(attempt)
                        switch message {
                        case .data(let data):
                            let produced = try await self.audio.engine.enqueuePCM(data, sampleRate: rate, id: playback)
                            try self.validate(attempt)
                            if produced { self.receivedAudio = true }
                        case .string(let text):
                            let event = try JSONValue.decode(Data(text.utf8))
                            if event["type"].string == "error" || !event["error"].string.isEmpty {
                                throw RPCFailure(event["message"].string.isEmpty ? (event["error"].string.isEmpty ? "Hermes n’a pas pu terminer la lecture vocale." : event["error"].string) : event["message"].string)
                            }
                            if event["type"].string == "end" {
                                try await self.audio.engine.finishPCM(id: playback)
                                try self.validate(attempt)
                                self.ended = true
                                return
                            }
                        @unknown default: break
                        }
                    }
                } catch {
                    guard let self, self.generation == attempt, !Task.isCancelled else { return }
                    self.streamFailure = error.localizedDescription
                    self.ended = true
                }
            }
            return true
        } catch {
            let code = (ws.response as? HTTPURLResponse)?.statusCode
            ws.cancel(with: .goingAway, reason: nil)
            guard generation == attempt else { throw CancellationError() }
            stop()
            if code == 404 || code == 405 { return false }
            throw error
        }
    }

    func send(_ text: String, done: Bool = false) async throws {
        let attempt = generation
        guard let socket else { throw RPCFailure("Le flux vocal est fermé.") }
        let data = try JSONValue.object(["text": .string(text), "done": .bool(done)]).data()
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        try validate(attempt)
    }

    func stop() {
        generation = UUID(); reader?.cancel(); reader = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        if let playbackID { audio.engine.stopPlayback(id: playbackID) }
        playbackID = nil
        ended = false; receivedAudio = false; streamFailure = nil
    }

    private func validate(_ attempt: UUID) throws {
        try Task.checkCancellation()
        guard generation == attempt else { throw CancellationError() }
    }
}
