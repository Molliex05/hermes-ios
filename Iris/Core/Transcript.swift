import Foundation

/// A display projection only. Hermes owns messages, context, memory and execution.
public struct Transcript: Sendable {
    public var messages: [ChatMessage] = []
    public var lastSequence = 0
    public var running = false
    public var activity: String?
    public var approval: JSONValue?
    public var clarification: JSONValue?
    public var credential: JSONValue?
    public var failure: String?

    public init(messages: [ChatMessage] = [], lastSequence: Int = 0) {
        self.messages = messages; self.lastSequence = lastSequence
    }

    public mutating func apply(_ event: JSONValue) {
        let seq = event["seq"].int
        if seq > 0 {
            guard seq > lastSequence else { return }
            lastSequence = seq
        }
        let p = event["payload"]
        switch event["type"].string {
        case "message.start":
            running = true; failure = nil; activity = "Réfléchit…"
        case "message.delta":
            running = true; activity = nil
            appendDelta(p["text"].string)
        case "message.interim":
            let text = p["text"].string
            if let index = messages.lastIndex(where: { $0.streaming }) {
                if !text.isEmpty { messages[index].text = text }
                messages[index].streaming = false
            } else if !text.isEmpty { messages.append(.init(role: "assistant", text: text)) }
        case "message.complete":
            let text = p["text"].string
            if let index = messages.lastIndex(where: { $0.streaming }) {
                messages[index].text = text; messages[index].streaming = false
                if text.isEmpty { messages.remove(at: index) }
            } else if !text.isEmpty, messages.last?.text != text || messages.last?.role != "assistant" {
                messages.append(.init(role: "assistant", text: text))
            }
            running = false; activity = nil; approval = nil; clarification = nil
            if p["status"].string == "error" { failure = p["error"].string }
            for i in messages.indices where messages[i].delivery == .sending { messages[i].delivery = .confirmed }
        case "thinking.delta", "reasoning.delta":
            running = true; activity = "Réfléchit…"
        case "tool.start", "tool.progress", "tool.generating":
            activity = p["name"].string.isEmpty ? "Utilise un outil…" : p["name"].string
        case "tool.complete": activity = nil
        case "status.update":
            if !p["text"].string.isEmpty { activity = p["text"].string }
        case "approval.request": approval = p
        case "clarify.request": clarification = p
        case "sudo.request", "secret.request":
            var request = p.object
            request["event_type"] = event["type"]
            credential = .object(request)
        case "approval.expire": approval = nil
        case "clarify.expire": clarification = nil
        case "sudo.expire", "secret.expire": credential = nil
        case "error": failure = p["message"].string; running = false; activity = nil
        default: break
        }
    }

    private mutating func appendDelta(_ text: String) {
        guard !text.isEmpty else { return }
        if let i = messages.lastIndex(where: { $0.streaming }) { messages[i].text += text }
        else { messages.append(.init(role: "assistant", text: text, streaming: true)) }
    }

    /// Preserve view identities through hydration so a refresh doesn't recreate every bubble.
    public mutating func hydrate(_ payload: JSONValue) {
        let old = messages
        var used = Set<String>()
        var projected: [ChatMessage] = []
        for row in payload["messages"].array {
            let role = row["role"].string
            guard ["user", "assistant"].contains(role), row["display_kind"].string != "hidden" else { continue }
            let text = row["text"].string
            guard !text.isEmpty else { continue }
            let stable = row["row_id"].isNull ? nil : "row-\(row["row_id"].int)"
            let match = old.first { !used.contains($0.id) && $0.role == role && ($0.text == text || (stable != nil && $0.id == stable)) }
            let id = match?.id ?? stable ?? UUID().uuidString
            used.insert(id)
            projected.append(.init(id: id, role: role, text: text))
        }
        let inflight = payload["inflight"]
        running = payload["running"].bool
        if !inflight.isNull {
            let user = inflight["user"].string
            if !user.isEmpty, projected.last(where: { $0.role == "user" })?.text != user {
                let previous = old.last { $0.role == "user" && $0.text == user }
                let id = previous?.id ?? UUID().uuidString
                used.insert(id)
                projected.append(.init(id: id, role: "user", text: user))
            }
            let assistant = inflight["assistant"].string
            if !assistant.isEmpty, running {
                let previous = old.last { $0.streaming }
                projected.append(.init(id: previous?.id ?? UUID().uuidString, role: "assistant", text: assistant, streaming: true))
            }
        }
        // Never silently discard a send whose acknowledgement was lost.
        for m in old where m.delivery != .confirmed && !used.contains(m.id) {
            if !projected.contains(where: { $0.id == m.id }) {
                var pending = m
                if pending.delivery == .sending { pending.delivery = .uncertain }
                projected.append(pending)
            }
        }
        messages = projected
        approval = payload["pending_approval"].isNull ? nil : payload["pending_approval"]
        clarification = payload["pending_clarify"].isNull ? nil : payload["pending_clarify"]
        activity = running ? "En cours…" : nil
        if !inflight["error"].string.isEmpty { failure = inflight["error"].string }
    }

    /// Rebase a gap onto Hermes' snapshot plus its replay ring. When the current turn's start
    /// is retained, rebuild that tail exactly. Otherwise overlap the retained delta suffix
    /// with the cumulative in-flight text. A completion always replaces the entire answer.
    public mutating func recover(_ payload: JSONValue, events: [JSONValue], latestSequence: Int) {
        hydrate(payload)
        lastSequence = 0
        let ordered = events.sorted { $0["seq"].int < $1["seq"].int }
        if running, let start = ordered.lastIndex(where: { $0["type"].string == "message.start" }),
           let user = messages.lastIndex(where: { $0.role == "user" }) {
            messages.removeSubrange((user + 1)...)
            for event in ordered[start...] { apply(event) }
        } else if running {
            let deltaText = ordered.filter { $0["type"].string == "message.delta" }.map { $0["payload"]["text"].string }.joined()
            if let i = messages.lastIndex(where: { $0.streaming }) {
                messages[i].text = Self.mergeStream(snapshot: messages[i].text, replay: deltaText)
            }
            // Control cards are stateful; don't drop them just because the text ring overflowed.
            for event in ordered where ["message.complete", "approval.request", "clarify.request", "error"].contains(event["type"].string) { apply(event) }
        }
        lastSequence = max(lastSequence, latestSequence)
    }

    public static func mergeStream(snapshot: String, replay: String) -> String {
        if snapshot.hasSuffix(replay) || replay.isEmpty { return snapshot }
        if replay.hasPrefix(snapshot) { return replay }
        // KMP: longest suffix of the snapshot matching a prefix of the retained stream.
        let pattern = Array(replay)
        var prefix = [Int](repeating: 0, count: pattern.count)
        if pattern.count > 1 {
            for i in 1..<pattern.count {
                var j = prefix[i - 1]
                while j > 0 && pattern[i] != pattern[j] { j = prefix[j - 1] }
                if pattern[i] == pattern[j] { j += 1 }
                prefix[i] = j
            }
        }
        var matched = 0
        for character in snapshot {
            while matched > 0 && (matched == pattern.count || pattern[matched] != character) { matched = prefix[matched - 1] }
            if matched < pattern.count && pattern[matched] == character { matched += 1 }
        }
        // No provable overlap: keep the known snapshot until an authoritative completion.
        guard matched > 0 else { return snapshot }
        return snapshot + String(pattern.dropFirst(matched))
    }
}

/// Holds live events while missing events are fetched; sort and deduplicate before dispatch.
public struct ReplayBuffer: Sendable {
    public var held: [JSONValue] = []
    public init() {}
    public mutating func drain(replayed: [JSONValue], after sequence: Int, session: String) -> [JSONValue] {
        let combined = (replayed + held).filter { $0["session_id"].string == session }
        held.removeAll(keepingCapacity: true)
        var seen = Set<Int>()
        return combined.sorted { $0["seq"].int < $1["seq"].int }.filter {
            let seq = $0["seq"].int
            return seq == 0 || (seq > sequence && seen.insert(seq).inserted)
        }
    }
}
