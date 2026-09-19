import Foundation
import AVFoundation
import Observation

/// Hermes owns sentence splitting, Markdown normalization, voice and provider choice.
@MainActor @Observable
final class NativeSpeechStream {
    private(set) var hasAudio = false
    private(set) var ended = false
    private(set) var failure: String?
    private(set) var queuedSeconds = 0.0
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var remainder = Data()
    @ObservationIgnored private var generation = UUID()

    var drained: Bool { ended && queuedSeconds < 0.001 }

    func open(tools: NativeToolSession) async throws -> Bool {
        stop()
        let ws = try await tools.app.speechSocket(connectionID: tools.connectionID, profile: tools.profile)
        socket = ws; ws.maximumMessageSize = 2 * 1024 * 1024; ws.resume()
        let deadline = Task { try? await Task.sleep(for: .seconds(15)); if !Task.isCancelled { ws.cancel(with: .goingAway, reason: nil) } }
        defer { deadline.cancel() }
        do {
            guard case .string(let text) = try await ws.receive() else { throw RPCFailure("Flux vocal Hermes invalide.") }
            let event = try JSONValue.decode(Data(text.utf8))
            if event["type"].string == "fallback" { stop(); return false }
            let rate = event["sample_rate"].double
            guard event["type"].string == "start", (8000...96000).contains(rate), event["channels"].int == 1,
                  let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { throw RPCFailure("Format vocal Hermes non pris en charge.") }
            self.format = format
            let attempt = generation
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        guard let self, self.generation == attempt else { return }
                        // Bound decoded audio. Backpressure leaves later frames on the socket.
                        while self.queuedSeconds > 5 { try await Task.sleep(for: .milliseconds(50)); try Task.checkCancellation() }
                        switch try await ws.receive() {
                        case .data(let data): try self.enqueue(data)
                        case .string(let text):
                            let event = try JSONValue.decode(Data(text.utf8))
                            if event["type"].string == "end" { self.ended = true; return }
                        @unknown default: break
                        }
                    }
                } catch {
                    guard let self, self.generation == attempt, !Task.isCancelled else { return }
                    self.failure = error.localizedDescription; self.ended = true
                }
            }
            return true
        } catch {
            let code = (ws.response as? HTTPURLResponse)?.statusCode
            stop()
            if code == 404 || code == 405 { return false }
            throw error
        }
    }

    func send(_ text: String, done: Bool = false) async throws {
        guard let socket else { throw RPCFailure("Le flux vocal est fermé.") }
        let data = try JSONValue.object(["text": .string(text), "done": .bool(done)]).data()
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func enqueue(_ data: Data) throws {
        guard let format else { return }
        remainder.append(data)
        let count = remainder.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let output = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        remainder.withUnsafeBytes { raw in
            for i in 0..<count {
                let value = UInt16(raw[i * 2]) | UInt16(raw[i * 2 + 1]) << 8
                output[i] = Float(Int16(bitPattern: value)) / 32768
            }
        }
        remainder.removeFirst(count * 2)
        if engine == nil {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio); try session.setActive(true)
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start(); self.engine = engine; self.player = player; player.play()
        }
        hasAudio = true
        let duration = Double(count) / format.sampleRate, attempt = generation
        queuedSeconds += duration
        player?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                self.queuedSeconds = max(0, self.queuedSeconds - duration)
            }
        }
    }

    func stop() {
        generation = UUID(); reader?.cancel(); reader = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil; format = nil
        remainder = Data(); queuedSeconds = 0; ended = false; hasAudio = false; failure = nil
    }
}
