import Foundation

struct VoicePreferences {
    let threshold: Double
    let silenceDuration: Double
    let stopPhrases: [String]
    let isGPTLive: Bool
    let bargeIn: Bool
    let bargeInGraceSeconds: Double
    let bargeInThresholdMultiplier: Double
    let maxRecordingSeconds: Double
    /// `stt.streaming`: the server may offer `/api/audio/transcribe-stream` for this profile.
    let liveTranscription: Bool

    /// Hermes' 3 s default suits push-to-talk; a hands-free phone loop ends the turn after
    /// 0.55 s (speech resumed while transcribing is merged, so a pause loses nothing).
    /// Any value the user configured explicitly wins, like the desktop's silence window.
    var endpointSilence: Double { silenceDuration == 3 ? 0.55 : silenceDuration }

    init(_ voice: JSONValue, stt: JSONValue = .null) {
        threshold = Self.number(voice["silence_threshold"], default: 200, range: 1...32767)
        silenceDuration = Self.number(voice["silence_duration"], default: 3, range: 0.3...30)
        maxRecordingSeconds = Self.number(voice["max_recording_seconds"], default: 120, range: 5...300)
        switch stt["streaming"] {
        case .bool(let value): liveTranscription = value
        case .number(let value): liveTranscription = value != 0
        case .string(let value): liveTranscription = ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespaces).lowercased())
        default: liveTranscription = false
        }
        switch voice["stop_phrases"] {
        case .string(let value): stopPhrases = Self.phrases([.string(value)])
        case .array(let values): stopPhrases = Self.phrases(values)
        default: stopPhrases = ["stop"]
        }
        if case .bool(let enabled) = voice["barge_in"] { bargeIn = enabled }
        else { bargeIn = true }
        bargeInGraceSeconds = Self.number(voice["barge_in_grace_seconds"], default: 0.5, range: 0...5)
        bargeInThresholdMultiplier = Self.number(voice["barge_in_threshold_multiplier"], default: 3, range: 1...10)
        let mode = voice["voice_chat_mode"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-")
        isGPTLive = ["gpt-live", "gptlive", "live"].contains(mode)
    }

    static func bounded(_ value: Double, default fallback: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private static func number(_ value: JSONValue, default fallback: Double, range: ClosedRange<Double>) -> Double {
        guard case .number(let number) = value else { return fallback }
        return bounded(number, default: fallback, range: range)
    }

    private static func phrases(_ values: [JSONValue]) -> [String] {
        values.compactMap { value in
            guard case .string(let phrase) = value else { return nil }
            let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

/// Config travels over the same native RPC connection as chat. Standard voice
/// must not depend on the newer, optional GPT-Live status HTTP route.
@MainActor
struct NativeVoiceAPI {
    let request: @MainActor (_ path: String, _ body: JSONValue, _ rpc: Bool) async throws -> JSONValue

    func preferences() async throws -> VoicePreferences {
        let response = try await request("config.get", ["key": "full"], true)
        // Keep only non-secret voice preferences; don't retain the full config.
        return VoicePreferences(response["config"]["voice"], stt: response["config"]["stt"])
    }

    func transcribe(_ recording: Data, mimeType: String) async throws -> String {
        try Task.checkCancellation()
        let dataURL = await Task.detached(priority: .userInitiated) {
            "data:\(mimeType);base64,\(recording.base64EncodedString())"
        }.value
        try Task.checkCancellation()
        let result = try await audioRequest("/api/audio/transcribe", body: [
            "data_url": .string(dataURL), "mime_type": .string(mimeType)
        ], unavailable: "Ce serveur Hermes ne propose pas la transcription depuis l’iPhone. Mettez Hermes à jour ou vérifiez que son API audio est accessible à cette adresse.")
        return result["transcript"].string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speech(_ text: String) async throws -> String {
        let result = try await audioRequest("/api/audio/speak", body: ["text": .string(text)],
            unavailable: "Ce serveur Hermes ne propose pas la lecture vocale sur l’iPhone. La réponse reste dans le chat. Mettez Hermes à jour ou vérifiez l’accès à son API audio.")
        return result["data_url"].string
    }

    private func audioRequest(_ path: String, body: JSONValue, unavailable: String) async throws -> JSONValue {
        do { return try await request(path, body, false) }
        catch let failure as RPCFailure where [404, 405].contains(failure.code) {
            throw RPCFailure(unavailable, code: failure.code)
        }
    }
}
