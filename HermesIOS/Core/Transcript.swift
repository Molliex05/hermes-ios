import Foundation

/// A display projection only. Hermes owns messages, context, memory and execution.
public struct Transcript: Sendable {
    public struct ToolStep: Identifiable, Equatable, Sendable {
        public enum State: Sendable { case running, completed, stopped }
        public var id: String
        public var name: String
        public var state: State
        public var title: String {
            switch name {
            case "terminal": "Commande"
            case "web_search": "Recherche web"
            case "web_extract", "browse": "Consultation web"
            case "read_file": "Lecture de fichier"
            case "write_file", "patch": "Modification de fichier"
            case "clarify": "Question"
            default: name.replacingOccurrences(of: "_", with: " ")
            }
        }
    }
    public var messages: [ChatMessage] = []
    public var toolSteps: [ToolStep] = []
    public var lastSequence = 0
    public var running = false
    public var activity: String?
    public var approval: JSONValue?
    public var clarification: JSONValue?
    public var credential: JSONValue?
    public var failure: String?
    public var lastActivityAt = Date()

    public func isWaitingForResponse(at date: Date) -> Bool {
        running && approval == nil && clarification == nil && credential == nil
            && ["Réfléchit…", "En cours…"].contains(activity ?? "")
            && date.timeIntervalSince(lastActivityAt) >= 15
    }

    public init(messages: [ChatMessage] = [], lastSequence: Int = 0) {
        self.messages = messages; self.lastSequence = lastSequence
    }

    /// A lost RPC reply is not a rejected turn. Only native acknowledgement/history
    /// can confirm receipt; unrelated tool events on a shared session cannot.
    @discardableResult
    public mutating func submissionFailed(id: String, error: Error) -> ChatMessage.Delivery? {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return nil }
        guard messages[i].delivery != .confirmed else { return .confirmed }
        let rejected = (error as? RPCFailure)?.rejectsPromptBeforeAdmission == true
        messages[i].delivery = rejected ? .failed : .uncertain
        if rejected { running = false; activity = nil }
        return messages[i].delivery
    }

    public mutating func apply(_ event: JSONValue) {
        let seq = event["seq"].int
        if seq > 0 {
            guard seq > lastSequence else { return }
            lastSequence = seq
        }
        lastActivityAt = Date()
        let p = event["payload"]
        switch event["type"].string {
        case "message.start":
            toolSteps = []
            running = true; failure = nil; activity = "Réfléchit…"
        case "message.delta":
            guard !p["text"].string.isEmpty else { return }
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
                let interrupted = ["error", "interrupted", "cancelled"].contains(p["status"].string)
                if !text.isEmpty || !interrupted { messages[index].text = text }
                messages[index].streaming = false
                if messages[index].text.isEmpty { messages.remove(at: index) }
            } else if !text.isEmpty, messages.last?.text != text || messages.last?.role != "assistant" {
                messages.append(.init(role: "assistant", text: text))
            }
            running = false; activity = nil; approval = nil; clarification = nil; credential = nil
            finishOpenTools()
            if p["status"].string == "error" { failure = p["error"].string }
        case "thinking.delta", "reasoning.delta":
            running = true; activity = "Réfléchit…"
        case "tool.start", "tool.progress", "tool.generating":
            running = true
            activity = p["name"].string.isEmpty ? "Utilise un outil…" : p["name"].string
            if event["type"].string == "tool.start" { updateTool(p, completed: false) }
        case "tool.complete":
            updateTool(p, completed: true)
            activity = running ? (toolSteps.last(where: { $0.state == .running })?.name ?? "Réfléchit…") : nil
        case "status.update":
            if !p["text"].string.isEmpty { activity = p["text"].string }
        case "approval.request": approval = p
        case "clarify.request": clarification = p
        case "sudo.request", "secret.request":
            var request = p.object
            request["event_type"] = event["type"]
            credential = .object(request)
        case "approval.expire": if p["request_id"].isNull || approval?["request_id"] == p["request_id"] { approval = nil }
        case "clarify.expire": if p["request_id"].isNull || clarification?["request_id"] == p["request_id"] { clarification = nil }
        case "sudo.expire", "secret.expire": if p["request_id"].isNull || credential?["request_id"] == p["request_id"] { credential = nil }
        case "error":
            failure = p["message"].string; running = false; activity = nil; approval = nil; clarification = nil; credential = nil
            finishOpenTools()
            for i in messages.indices { messages[i].streaming = false }
        default: break
        }
    }

    private mutating func updateTool(_ payload: JSONValue, completed: Bool) {
        let id = payload["tool_id"].string, name = payload["name"].string
        guard !id.isEmpty, !name.isEmpty else { return }
        if let index = toolSteps.firstIndex(where: { $0.id == id }) {
            if completed { toolSteps[index].state = .completed }
        } else {
            toolSteps.append(ToolStep(id: id, name: name, state: completed ? .completed : .running))
            if toolSteps.count > 40 { toolSteps.removeFirst(toolSteps.count - 40) }
        }
    }

    private mutating func finishOpenTools() {
        for index in toolSteps.indices where toolSteps[index].state == .running { toolSteps[index].state = .stopped }
    }

    private mutating func appendDelta(_ text: String) {
        guard !text.isEmpty else { return }
        if let i = messages.lastIndex(where: { $0.streaming }) { messages[i].text += text }
        else { messages.append(.init(role: "assistant", text: text, streaming: true)) }
    }

    /// Preserve view identities through hydration so a refresh doesn't recreate every bubble.
    public mutating func hydrate(_ payload: JSONValue) {
        lastActivityAt = Date()
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
        if !running { finishOpenTools() }
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
        if !running { credential = nil }
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
        let turnStart = ordered.lastIndex(where: { $0["type"].string == "message.start" })
        if running, let start = turnStart,
           let user = messages.lastIndex(where: { $0.role == "user" }) {
            messages.removeSubrange((user + 1)...)
            for event in ordered[start...] { apply(event) }
        } else if running {
            // A snapshot may have no visible user row (for example a background turn).
            // When a start is retained, never mix older turns into that live tail.
            let tail = turnStart.map { ordered[$0...] } ?? ordered[...]
            let deltaText = tail.filter { $0["type"].string == "message.delta" }.map { $0["payload"]["text"].string }.joined()
            if let i = messages.lastIndex(where: { $0.streaming }) {
                messages[i].text = Self.mergeStream(snapshot: messages[i].text, replay: deltaText)
            }
            // Reconcile tools and control cards even after the ring loses message.start.
            // Keep this inside the running branch: an idle snapshot is authoritative,
            // and old lifecycle events must not make a finished turn appear active again.
            for event in tail where ["message.start", "message.complete", "tool.start", "tool.complete", "tool.progress", "tool.generating", "approval.request", "clarify.request", "sudo.request", "secret.request", "approval.expire", "clarify.expire", "sudo.expire", "secret.expire", "error"].contains(event["type"].string) { apply(event) }
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
