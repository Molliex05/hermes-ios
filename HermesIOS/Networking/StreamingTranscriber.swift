import Foundation

/// Live STT for one utterance over Hermes' `WS /api/audio/transcribe-stream`. The provider
/// key stays on the server. PCM (16 kHz s16le mono, pre-roll first) streams while the
/// user speaks; `finish` sends `eos` and waits for the final transcript. Any error —
/// including the immediate "no live STT" answer for providers such as groq — makes the
/// caller fall back to `POST /api/audio/transcribe` with the locally recorded utterance.
@MainActor
final class StreamingTranscriber {
    var onPartial: ((String) -> Void)?
    /// The profile has no live STT wire: don't try again during this conversation.
    private(set) var unavailable = false
    private var socket: URLSessionWebSocketTask?
    private var opening: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var outbox: [Data] = []
    private var outboxBytes = 0
    private var endRequested = false
    private var result: Result<String, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(tools: NativeToolSession) {
        opening = Task { [weak self] in
            do {
                let ws = try await tools.app.audioSocket("/api/audio/transcribe-stream", connectionID: tools.connectionID, profile: tools.profile)
                guard let self, self.result == nil, !Task.isCancelled else { ws.cancel(with: .goingAway, reason: nil); return }
                self.socket = ws; self.opening = nil
                ws.resume()
                self.reader = Task { [weak self] in await self?.read(ws) }
                self.transmit(.string(TranscribeStreamEvent.hello))
                for chunk in self.outbox { self.transmit(.data(chunk)) }
                self.outbox.removeAll(); self.outboxBytes = 0
                if self.endRequested { self.transmit(.string(TranscribeStreamEvent.endOfSpeech)) }
            } catch {
                self?.resolve(.failure(error))
            }
        }
    }

    func push(_ pcm: Data) {
        guard result == nil, !endRequested, !pcm.isEmpty else { return }
        if socket != nil { transmit(.data(pcm)); return }
        // Bounded while the socket opens (~30 s); the local recording remains the fallback.
        guard outboxBytes + pcm.count <= 960_000 else { return }
        outbox.append(pcm); outboxBytes += pcm.count
    }

    /// End of speech: the final transcript, or an error meaning "use the recording".
    func finish(timeout: Double = 6) async throws -> String {
        if result == nil, !endRequested {
            endRequested = true
            if socket != nil { transmit(.string(TranscribeStreamEvent.endOfSpeech)) }
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.resolve(.failure(RPCFailure("La transcription en direct ne répond pas.")))
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if result != nil { continuation.resume() } else { waiters.append(continuation) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        try Task.checkCancellation()
        return try (result ?? .failure(CancellationError())).get()
    }

    /// Disconnecting without `eos` cancels the server-side session.
    func cancel() { resolve(.failure(CancellationError())) }

    private func transmit(_ message: URLSessionWebSocketTask.Message) {
        socket?.send(message) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in self?.resolve(.failure(error)) }
        }
    }

    private func read(_ ws: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled, result == nil {
                guard case .string(let text) = try await ws.receive() else { continue }
                switch TranscribeStreamEvent(text) {
                case .partial(let partial): if result == nil, !partial.isEmpty { onPartial?(partial) }
                case .final(let transcript): resolve(.success(transcript))
                case .error(let message):
                    if message == TranscribeStreamEvent.unavailableMessage { unavailable = true }
                    resolve(.failure(RPCFailure(message)))
                case .ignored: break
                }
            }
        } catch {
            if [404, 405].contains((ws.response as? HTTPURLResponse)?.statusCode ?? 0) { unavailable = true }
            resolve(.failure(error))
        }
    }

    private func resolve(_ outcome: Result<String, Error>) {
        guard result == nil else { return }
        result = outcome
        opening?.cancel(); opening = nil; reader?.cancel(); reader = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        outbox.removeAll(); outboxBytes = 0; onPartial = nil
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
