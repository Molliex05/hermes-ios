import Foundation

/// Foundation-only wire contract, shared by the native voice client and tests.
enum VoiceLiveProtocol {
    /// `voiceTurn` routes a spoken chained turn to Hermes' `auxiliary.voice_chat` model.
    /// GPT-Live delegations are not voice turns: the live model already owns the voice layer.
    /// `interrupted` tells the model its previous reply was cut off by the user (barge-in).
    static func prompt(runtime: String, text: String, context: String?, voiceTurn: Bool = false, interrupted: Bool = false) -> JSONValue {
        var body: [String: JSONValue] = ["session_id": .string(runtime), "text": .string(text)]
        if let context {
            body["surface"] = "voice-live"
            body["voice_context"] = .string(String(context.suffix(6_000)))
        } else if voiceTurn {
            body["voice_turn"] = true
        }
        if interrupted { body["interrupted"] = true }
        return .object(body)
    }

    static func history(_ turns: [(role: String, text: String)]) -> JSONValue {
        var result: [JSONValue] = []; var remaining = 6_000
        for turn in turns.reversed() where ["user", "assistant"].contains(turn.role) {
            let text = String(turn.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200))
            guard !text.isEmpty else { continue }
            guard result.count < 24, text.count <= remaining else { break }
            remaining -= text.count
            result.insert(["type": "message", "role": .string(turn.role), "content": .array([
                ["type": .string(turn.role == "user" ? "input_text" : "output_text"), "text": .string(text)]
            ])], at: 0)
        }
        return .array(result)
    }

    static func append(_ type: String, delegation: String?, content: String) -> JSONValue {
        ["type": .string("session.\(type).append"), "event_id": .string(UUID().uuidString),
         "delegation_id": delegation.map(JSONValue.string) ?? .null, "content": .string(content)]
    }

    // UTF-8 bytes bound even unusual scripts/emoji below the 500-token vendor cap.
    static func chunks(_ text: String) -> [String] {
        var result: [String] = []; var chunk = ""; var bytes = 0
        for scalar in text.unicodeScalars {
            let part = String(scalar); let size = part.utf8.count
            if bytes + size > 480 { result.append(chunk); chunk = ""; bytes = 0 }
            chunk += part; bytes += size
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}

struct VoiceLiveTranscript {
    struct Fragment { let role: String; let text: String; let start: Double; let end: Double }
    struct Request { let id: String; let prompt: String; let context: String; let receivedAt: Double }
    private var pending: [(id: String, offset: Double, receivedAt: Double)] = []
    private var consumedThrough = -Double.infinity
    private(set) var fragments: [Fragment] = []
    private var delegations: Set<String> = []
    private var delegationOrder: [String] = []
    private var dropped: [String] = []

    mutating func receive(_ event: JSONValue, now: Double = ProcessInfo.processInfo.systemUptime) -> String? {
        let type = event["type"].string
        if ["session.input_transcript.delta", "session.output_transcript.delta"].contains(type) {
            fragments.append(Fragment(role: type == "session.input_transcript.delta" ? "user" : "assistant",
                                      text: event["delta"].string, start: event["start_ms"].double, end: event["end_ms"].double))
            let floor = (fragments.map(\.end).max() ?? 0) - 300_000
            fragments = Array(fragments.filter { $0.end >= floor }.suffix(512))
        }
        guard type == "session.delegation.created" else { return nil }
        let id = event["delegation"]["id"].string
        guard !id.isEmpty, delegations.insert(id).inserted else { return nil }
        pending.append((id, event["offset_ms"].isNull ? (fragments.map(\.end).max() ?? 0) : event["offset_ms"].double, now))
        delegationOrder.append(id)
        if delegationOrder.count > 512 { delegations.remove(delegationOrder.removeFirst()) }
        return id
    }

    var turns: [(role: String, text: String)] {
        var result: [(role: String, text: String)] = []
        for fragment in ordered {
            if result.last?.role == fragment.role { result[result.count - 1].text += fragment.text }
            else { result.append((fragment.role, fragment.text)) }
        }
        return result
    }
    private var ordered: [Fragment] {
        fragments.enumerated().sorted {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }.map(\.element)
    }
    var prompt: String {
        ordered.filter { $0.role == "user" && $0.end > consumedThrough }.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Delegations can arrive before their transcript. Never infer user turns from
    /// assistant backchannels, nor overwrite another delegation that is still running.
    /// A delegation whose speech is already transcribed through its offset is ready at
    /// once; otherwise late fragments get 0.4 s. One never transcribed within 3 s is
    /// dropped (see `takeDropped`) instead of ending the conversation.
    mutating func nextRequest(now: Double) throws -> Request? {
        while pending.count > 16 { dropped.append(pending.removeFirst().id) }
        while let next = pending.first {
            if next.offset <= consumedThrough { pending.removeFirst(); continue }
            let input = ordered.filter { $0.role == "user" && $0.end > consumedThrough && $0.start <= next.offset }
            let covered = input.contains { $0.end >= next.offset }
            guard covered || now - next.receivedAt >= 0.4 else { return nil }
            let text = input.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                guard now - next.receivedAt >= 3 else { return nil }
                dropped.append(pending.removeFirst().id)
                continue
            }
            pending.removeFirst()
            consumedThrough = input.map(\.end).max() ?? next.offset
            let context = ordered.filter { $0.start <= next.offset }.map {
                "\($0.role == "user" ? "User" : "Voice assistant"): \($0.text)"
            }.joined(separator: "\n")
            return Request(id: next.id, prompt: text, context: String(context.suffix(6_000)), receivedAt: next.receivedAt)
        }
        return nil
    }

    /// Delegations that will not be submitted (untranscribed or over the queue bound).
    mutating func takeDropped() -> [String] {
        defer { dropped.removeAll() }
        return dropped
    }
    var context: String {
        String(turns.map { "\($0.role == "user" ? "User" : "Voice assistant"): \($0.text)" }.joined(separator: "\n").suffix(6_000))
    }
}

/// Emit completed clauses during generation and the remaining tail on completion.
/// Long unpunctuated runs are cut at the last comma/space so GPT-Live is never starved.
struct VoiceLiveReplyCursor {
    private var cursor = VoiceTextCursor()
    mutating func delta(_ text: String, done: Bool) -> String {
        if done { return cursor.delta(text) }
        guard text.hasPrefix(cursor.sent) else { return "" }
        let pending = text.dropFirst(cursor.sent.count)
        if let end = pending.lastIndex(where: { ".!?…;:\n".contains($0) }) {
            return cursor.delta(cursor.sent + pending[...end])
        }
        guard pending.count >= 160, let cut = pending.lastIndex(where: { $0 == "," || $0 == " " }) else { return "" }
        return cursor.delta(cursor.sent + pending[...cut])
    }
}

/// Per-delegation spoken progress. Call only while the owning turn is still active.
/// Uses monotonic seconds so a device clock adjustment cannot trigger a burst.
struct VoiceLiveProgress {
    let startedAt: TimeInterval
    private var lastUpdateAt: TimeInterval?
    private var spoken: Set<String> = []
    private var hasReply = false

    mutating func next(now: TimeInterval, lastSpeechAt: TimeInterval, lastOutputAt: TimeInterval,
                       running: Bool, receivedReply: Bool, tools: [Transcript.ToolStep]) -> String? {
        hasReply = hasReply || receivedReply
        guard running, !hasReply, spoken.count < 3, now - lastSpeechAt >= 2 else { return nil }
        let acknowledgement = "Je m’en occupe."
        if lastUpdateAt == nil, lastOutputAt < startedAt - 2, now - startedAt >= 2 {
            return emit(acknowledgement, at: now)
        }
        // Give any speech (including GPT-Live's own acknowledgement) time to finish.
        guard now - max(lastUpdateAt ?? startedAt, lastSpeechAt) >= 8 else { return nil }
        // Announce only known, currently running tools; never read raw status, arguments,
        // private reasoning, or claim that a tool's action has succeeded.
        for tool in tools.reversed() where tool.state == .running {
            if let message = Self.description(tool.name), !spoken.contains(message) {
                return emit(message, at: now)
            }
        }
        let waiting = "Je travaille encore sur votre demande."
        guard !spoken.contains(waiting) else { return nil }
        return emit(waiting, at: now)
    }

    private mutating func emit(_ message: String, at time: TimeInterval) -> String {
        spoken.insert(message); lastUpdateAt = time
        return message
    }

    private static func description(_ tool: String) -> String? {
        switch tool {
        case "web_search": "Je recherche les informations sur le web."
        case "web_extract", "browse": "Je consulte les informations sur le web."
        case "read_file": "Je consulte les fichiers nécessaires."
        case "write_file", "patch": "La modification des fichiers est en cours."
        case "terminal": "Une commande est en cours d’exécution."
        default: nil
        }
    }
}

/// Tracks delivery, not playback. A data-channel send alone does not confirm context injection.
struct VoiceLiveReceipts {
    private struct Pending { let expected: String; let sentAt: Double }
    private var pending: [String: Pending] = [:]
    private(set) var failure: String?
    var isEmpty: Bool { pending.isEmpty }
    func contains(_ id: String) -> Bool { pending[id] != nil }
    mutating func sent(_ event: JSONValue, now: Double) {
        let type = event["type"].string
        guard ["session.instructions.append", "session.thinking.append", "session.commentary.append"].contains(type) else { return }
        pending[event["event_id"].string] = Pending(expected: type + "ed", sentAt: now)
    }
    mutating func receive(_ event: JSONValue) {
        let id = event["client_event_id"].string
        if event["type"].string == "error" {
            failure = "GPT-Live n’a pas confirmé la transmission. La réponse d’Hermès reste disponible dans le chat."
        } else if let item = pending[id], event["type"].string == item.expected {
            pending.removeValue(forKey: id)
        }
    }
    func check(now: Double) throws {
        if let failure { throw RPCFailure(failure) }
        if pending.values.contains(where: { now - $0.sentAt >= 30 }) {
            throw RPCFailure("GPT-Live ne confirme plus la réception des réponses. Retrouvez la réponse d’Hermès dans le chat.")
        }
    }
}
