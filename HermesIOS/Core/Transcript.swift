import Foundation

/// A display projection only. Hermes owns messages, context, memory and execution.
public struct Transcript: Sendable {
    public struct ToolStep: Identifiable, Equatable, Sendable {
        public enum State: Sendable { case running, completed, stopped }
        public var id: String
        public var name: String
        public var state: State
        /// What the tool works on, as Hermes previews it (a search, a file, a command); may be empty.
        public var context = ""
        /// Seconds the tool took, once it is done.
        public var duration: Double?
        public var startedAt: Date?

        /// The tool's own name, without an MCP server prefix (« mcp__noriven__ops_get_host » is « ops_get_host »).
        public var baseName: String {
            guard name.hasPrefix("mcp__") else { return name }
            return name.split(separator: "_", omittingEmptySubsequences: true).count > 2
                ? String(name.dropFirst(5).drop { $0 != "_" }.drop { $0 == "_" }) : name
        }
        /// The MCP server a tool comes from (noriven, noryv, memoire), empty for built-in tools.
        public var server: String {
            guard name.hasPrefix("mcp__") else { return "" }
            return String(name.dropFirst(5).prefix { $0 != "_" })
        }

        public var title: String {
            switch baseName {
            case "terminal": "Commande"
            case "web_search": "Recherche web"
            case "web_extract", "browse", "browser_navigate": "Lecture d’une page"
            case "read_file": "Lecture de fichier"
            case "write_file", "patch": "Modification de fichier"
            case "search_files": "Recherche de fichiers"
            case "clarify": "Question"
            case "memory": "Mémoire"
            case "session_search": "Recherche dans l’historique"
            case "vision_analyze": "Analyse d’image"
            case "image_generate": "Création d’image"
            case "text_to_speech": "Voix"
            case "todo", "todo_write": "Liste de tâches"
            case "delegate_task": "Délégation"
            case "cronjob": "Tâche planifiée"
            case "skill_view", "skills_list": "Compétence"
            case "meteo": "Météo"
            case "nouvelles": "Nouvelles"
            case "ios_notify": "Notification"
            case "gmail_chercher": "Recherche de courriels"
            case "gmail_lire": "Lecture d’un courriel"
            case "gmail_trier", "gmail_dossiers": "Tri des courriels"
            case "gmail_brouillon": "Brouillon de courriel"
            case "agenda_lister", "agenda_calendriers": "Agenda"
            case "agenda_creer": "Ajout à l’agenda"
            case "agenda_modifier": "Modification de l’agenda"
            case "agenda_supprimer": "Suppression dans l’agenda"
            case "noriven_chiffres": "Chiffres de Noriven"
            case "umami_stats": "Visites du site"
            case "gsc_performance", "gsc_inspect_url": "Search Console"
            case "ops_get_host": "État du serveur"
            case "ops_list_services", "ops_get_service": "Services"
            case "ops_get_backups": "Sauvegardes"
            case "ops_get_logs": "Journaux du serveur"
            case let tool where tool.hasPrefix("finance_"): "Finances"
            case let tool where tool.hasPrefix("analytics_"): "Analyse de données"
            case let tool where tool.contains("nutrition") || tool.contains("meal"): "Nutrition"
            case let tool where tool.contains("cardio") || tool.contains("activities") || tool.contains("run_route"): "Activités"
            case let tool where tool.hasPrefix("noryv_"): "Entraînement"
            case let tool where tool.hasPrefix("memory_"): "Mémoire de Noriven"
            default:
                baseName.replacingOccurrences(of: "_", with: " ").prefix(1).uppercased() + baseName.replacingOccurrences(of: "_", with: " ").dropFirst()
            }
        }

        /// An SF Symbol for the kind of tool.
        public var symbol: String {
            let tool = baseName.lowercased()
            let kinds: [(String, [String])] = [
                ("magnifyingglass", ["search", "chercher", "query"]), ("globe", ["web", "browse", "extract", "navigate"]),
                ("terminal", ["terminal", "command"]), ("pencil", ["write", "patch", "brouillon"]), ("doc.text", ["file"]),
                ("brain", ["memory", "memoire", "remember"]), ("photo", ["vision", "image"]), ("cloud.sun", ["meteo", "weather"]),
                ("newspaper", ["nouvelles", "news"]), ("envelope", ["gmail", "mail"]), ("calendar", ["agenda", "calendar"]),
                ("bell", ["notify", "push"]), ("checklist", ["todo", "task"]), ("dollarsign.circle", ["finance", "chiffres"]),
                ("chart.bar", ["analytics", "umami", "gsc", "stats"]), ("server.rack", ["ops_", "host", "service", "backup", "logs"]),
                ("fork.knife", ["nutrition", "meal"]), ("figure.run", ["noryv", "cardio", "workout", "activit"]), ("clock", ["cron"]),
                ("person.2", ["delegate"]), ("sparkles", ["skill"]), ("questionmark.bubble", ["clarify"]), ("waveform", ["speech", "voice"]),
            ]
            return kinds.first { _, words in words.contains { tool.contains($0) } }?.0 ?? "wrench.and.screwdriver"
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

    /// What the agent is doing, in words: a tool's French name (« État du serveur… ») rather than its raw name.
    public var activityLabel: String? {
        guard let activity else { return nil }
        if let step = toolSteps.last(where: { $0.name == activity }) { return step.title + "…" }
        if activity.hasPrefix("mcp__") || (activity.contains("_") && !activity.contains(" ")) {
            return ToolStep(id: "", name: activity, state: .running).title + "…"
        }
        return activity
    }

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
        case "tool.start", "tool.generating":
            running = true
            activity = p["name"].string.isEmpty ? "Utilise un outil…" : p["name"].string
            if event["type"].string == "tool.start" { updateTool(p, completed: false) }
        case "tool.complete":
            updateTool(p, completed: true)
            activity = running ? (toolSteps.last(where: { $0.state == .running })?.name ?? "Réfléchit…") : nil
        case "status.update":
            if !p["text"].string.isEmpty { activity = p["text"].string }
        // Interactive prompts arrive as server→client requests (see ServerRequests); only the
        // approval queue snapshot from `session.resume` (`pending_approval`) lives here.
        case "approval.cancelled":
            let ids = p["request_ids"].array
            if let current = approval, current["rpc_id"].isNull,
               ids.isEmpty || ids.contains(current["request_id"]) { approval = nil }
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
        let preview = Self.preview(payload["context"].string.isEmpty ? payload["preview"].string : payload["context"].string)
        let took: Double? = if case .number(let seconds) = payload["duration_s"], seconds.isFinite, seconds >= 0 { seconds } else { nil }
        if let index = toolSteps.firstIndex(where: { $0.id == id }) {
            if completed {
                toolSteps[index].state = .completed
                toolSteps[index].duration = took ?? toolSteps[index].startedAt.map { Date().timeIntervalSince($0) }
            }
            if toolSteps[index].context.isEmpty { toolSteps[index].context = preview }
        } else {
            toolSteps.append(ToolStep(id: id, name: name, state: completed ? .completed : .running, context: preview,
                                      duration: completed ? took : nil, startedAt: completed ? nil : Date()))
            if toolSteps.count > 40 { toolSteps.removeFirst(toolSteps.count - 40) }
        }
    }

    /// One readable line: no line breaks, at most 90 characters.
    private static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 90 ? String(line.prefix(89)) + "…" : line
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
        // Indexed once, so matching a row is a lookup instead of a scan of every earlier message (hydrate runs after
        // each reply, on the main thread, over histories of up to hundreds of messages).
        var byText: [String: [Int]] = [:]
        var byID: [String: Int] = [:]
        for (index, message) in old.enumerated() {
            byText[message.role + "\u{0}" + message.text, default: []].append(index)
            if byID[message.id] == nil { byID[message.id] = index }
        }
        var cursor: [String: Int] = [:]
        func firstUnused(role: String, text: String) -> Int? {
            let key = role + "\u{0}" + text
            guard let list = byText[key] else { return nil }
            var position = cursor[key] ?? 0
            while position < list.count, used.contains(old[list[position]].id) { position += 1 }
            cursor[key] = position
            return position < list.count ? list[position] : nil
        }
        for row in payload["messages"].array {
            let role = row["role"].string
            guard ["user", "assistant"].contains(role), row["display_kind"].string != "hidden" else { continue }
            let text = row["text"].string
            guard !text.isEmpty else { continue }
            let stable = row["row_id"].isNull ? nil : "row-\(row["row_id"].int)"
            // Earliest unused message with the same role and text, or with this stable row id.
            var found = firstUnused(role: role, text: text)
            if let stable, let index = byID[stable], old[index].role == role, !used.contains(old[index].id), index < (found ?? Int.max) { found = index }
            let match = found.map { old[$0] }
            let id = match?.id ?? stable ?? UUID().uuidString
            used.insert(id)
            projected.append(.init(id: id, role: role, text: text))
        }
        let inflight = payload["inflight"]
        // `session.history` carries only messages; resume snapshots also carry the live state.
        // Never let a plain history refresh mark a running turn idle or drop a pending card.
        let carriesState = payload.object.keys.contains { ["running", "inflight", "pending_approval"].contains($0) }
        if carriesState { running = payload["running"].bool }
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
        guard carriesState else { return }
        // Live prompts come from server requests (rpc_id); a snapshot only refreshes the queue copy.
        if approval?["rpc_id"].isNull != false { approval = payload["pending_approval"].isNull ? nil : payload["pending_approval"] }
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
            for event in tail where ["message.start", "message.complete", "tool.start", "tool.complete", "tool.generating", "approval.cancelled", "error"].contains(event["type"].string) { apply(event) }
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
