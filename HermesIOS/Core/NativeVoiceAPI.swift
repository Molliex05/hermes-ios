import Foundation

struct VoicePreferences {
    let threshold: Double
    let silenceDuration: Double
    let stopPhrases: [String]
    let isGPTLive: Bool

    init(_ voice: JSONValue) {
        threshold = voice["silence_threshold"].isNull ? 200 : max(1, voice["silence_threshold"].double)
        silenceDuration = voice["silence_duration"].isNull ? 3 : max(0.3, voice["silence_duration"].double)
        stopPhrases = voice["stop_phrases"].isNull ? ["stop"] : voice["stop_phrases"].array.map(\.string)
        let mode = voice["voice_chat_mode"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-")
        isGPTLive = ["gpt-live", "gptlive", "live"].contains(mode)
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
        return VoicePreferences(response["config"]["voice"])
    }

    func transcribe(_ recording: Data, mimeType: String) async throws -> String {
        let result = try await audioRequest("/api/audio/transcribe", body: [
            "data_url": .string("data:\(mimeType);base64,\(recording.base64EncodedString())"), "mime_type": .string(mimeType)
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
