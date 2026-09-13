import Foundation
import Observation

struct CachedWorkspace: Codable, Sendable {
    var profiles: [AgentProfile] = []
    var sessions: [Conversation] = []
    var chats: [String: ChatSnapshot] = [:]
    var drafts: [String: String] = [:]
    var selected: String?
}

@MainActor @Observable
final class AppModel {
    enum ConnectionState { case offline, connecting, connected, signInRequired }
    var connections: [SavedConnection] = []
    var activeConnection: SavedConnection?
    var state: ConnectionState = .offline
    var profiles: [AgentProfile] = []
    var sessions: [Conversation] = []
    var profile = "default"
    var selected: ChatSnapshot?
    var transcript = Transcript()
    var draft = ""
    var notice: String?
    var routines: [Routine] = []
    var botMode = true
    var opening = false
    var sending = false
    var demo = false
    var hasBooted = false
    var hasBotProtocol = false
    var draftKey: String { selected.map { key($0.profile, $0.storedID) } ?? "draft-\(profile)" }
    var agent: AgentProfile? { profiles.first { $0.name == (selected?.profile ?? profile) } }
    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (state == .connected || demo) && !opening && !sending && !transcript.running && (selected == nil || !(selected?.runtimeID.isEmpty ?? true) || demo) }

    @ObservationIgnored var toolCache: [String: JSONValue] = [:]
    @ObservationIgnored private let cache = LocalCache()
    @ObservationIgnored private var http: HermesHTTP?
    @ObservationIgnored private var socket: HermesSocket?
    @ObservationIgnored private var workspace = CachedWorkspace()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var held = ReplayBuffer()
    @ObservationIgnored private var buffering = false
    @ObservationIgnored private var streamEvents: [JSONValue] = []
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var foreground = true

    func boot() async {
        guard !hasBooted else { return }
        hasBooted = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { loadDemo(); return }
        #endif
        connections = await cache.read([SavedConnection].self, key: "connections") ?? []
        if let first = connections.first { await activate(first) }
    }

    func addConnection(_ connection: SavedConnection, username: String, password: String, token: String) async throws {
        let client = HermesHTTP(connection)
        do {
            let status = try await client.request("/api/status")
            if connection.mode == "token" { try client.useToken(token) }
            else {
                if status["auth_providers"].array.isEmpty && !status["auth_required"].bool {
                    throw RPCFailure("Activez l’authentification native de Hermes, puis connectez Hermès iOS. Consultez le guide de connexion.")
                }
                try await client.signIn(username: username, password: password)
            }
            let probe = HermesSocket()
            try await probe.open(http: client)
            let result = try await probe.call("profiles.list")
            guard !result["profiles"].array.isEmpty else { probe.close(); throw RPCFailure("Ce serveur ne renvoie aucun profil Hermes.") }
            probe.close(); client.invalidate()
            connections.removeAll { $0.id == connection.id }
            connections.insert(connection, at: 0)
            try await cache.save(connections, key: "connections")
            await activate(connection)
        } catch {
            client.invalidate()
            if !connections.contains(where: { $0.id == connection.id }) { Keychain.delete(connection.id.uuidString) }
            throw error
        }
    }

    func activate(_ connection: SavedConnection) async {
        await persistNow()
        reconnectTask?.cancel(); reconnectTask = nil
        refreshTask?.cancel(); streamTask?.cancel()
        socket?.close(); http?.invalidate()
        connectionGeneration = UUID(); selectionGeneration = UUID()
        let generation = connectionGeneration
        activeConnection = connection; demo = false; state = .connecting
        connections.removeAll { $0.id == connection.id }
        connections.insert(connection, at: 0)
        try? await cache.save(connections, key: "connections")
        guard generation == connectionGeneration else { return }
        opening = false; sending = false; buffering = false; held = ReplayBuffer(); streamEvents = []
        let restored = await cache.read(CachedWorkspace.self, key: connection.id.uuidString) ?? CachedWorkspace()
        guard generation == connectionGeneration else { return }
        workspace = restored
        profiles = workspace.profiles; sessions = workspace.sessions
        selected = workspace.selected.flatMap { workspace.chats[$0] }
        profile = selected?.profile ?? profiles.first?.name ?? "default"
        transcript = Transcript(messages: selected?.messages ?? [], lastSequence: selected?.lastSequence ?? 0)
        draft = workspace.drafts[draftKey] ?? ""
        http = HermesHTTP(connection)
        startReconnect()
    }

    private func startReconnect() {
        guard foreground, !demo, http != nil, reconnectTask == nil else { return }
        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while let self, !Task.isCancelled, generation == self.connectionGeneration, self.foreground {
                self.state = .connecting
                do {
                    guard let http = self.http else { return }
                    let channel = HermesSocket()
                    self.socket = channel
                    channel.onEvent = { [weak self] in self?.receive($0) }
                    channel.onDisconnect = { [weak self] error in self?.disconnected(error) }
                    self.buffering = true; self.held = ReplayBuffer()
                    try await channel.open(http: http)
                    try Task.checkCancellation()
                    guard generation == self.connectionGeneration else { return }
                    try await self.refreshProfiles()
                    guard generation == self.connectionGeneration, !Task.isCancelled else { return }
                    if let selected = self.selected {
                        do { try await self.attach(selected, generation: self.selectionGeneration) }
                        catch let error as RPCFailure where error.code > 0 && error.code != 401 {
                            self.selected?.runtimeID = ""; self.buffering = false
                            self.notice = error.localizedDescription
                        }
                    } else {
                        self.buffering = false
                    }
                    guard generation == self.connectionGeneration, !Task.isCancelled else { return }
                    self.state = .connected
                    try await self.refreshSessions()
                    guard generation == self.connectionGeneration, !Task.isCancelled else { return }
                    self.reconnectTask = nil
                    return
                } catch {
                    guard !Task.isCancelled, generation == self.connectionGeneration else { return }
                    self.socket?.close()
                    if (error as? RPCFailure)?.code == 401 {
                        self.state = .signInRequired; self.notice = error.localizedDescription
                        self.reconnectTask = nil; return
                    }
                    attempt += 1
                    if attempt >= 2 { self.state = .offline }
                    do { try await Task.sleep(for: .seconds(min(pow(2, Double(attempt - 1)), 20) + Double.random(in: 0...0.4))) }
                    catch { return }
                }
            }
        }
    }

    private func disconnected(_ error: Error) {
        flushStream()
        state = .offline; opening = false
        if sending {
            for i in transcript.messages.indices where transcript.messages[i].delivery == .sending { transcript.messages[i].delivery = .uncertain }
        }
        scheduleSave()
        startReconnect()
    }

    func setForeground(_ active: Bool) async {
        foreground = active
        if active {
            if state != .connected { reconnectTask = nil; startReconnect() }
        } else {
            await persistNow()
            reconnectTask?.cancel(); reconnectTask = nil
            socket?.close(); state = .offline
        }
    }

    func refreshProfiles() async throws {
        guard let socket else { return }
        let generation = connectionGeneration
        let result = try await socket.call("profiles.list", ["include_sessions": true])
        guard generation == connectionGeneration else { return }
        profiles = result["profiles"].array.map(AgentProfile.init)
        hasBotProtocol = result["bot_mode_protocol"].bool
        if !profiles.contains(where: { $0.name == profile }), let first = profiles.first { profile = first.name }
        scheduleSave()
    }

    func refreshSessions() async throws {
        guard let socket else { return }
        let generation = connectionGeneration
        let owner = profile
        let result = try await socket.call("session.list", ["profile": .string(owner), "limit": 100])
        guard profile == owner, generation == connectionGeneration else { return }
        sessions = result["sessions"].array.map { Conversation($0, profile: owner) }
        scheduleSave()
    }

    func changeProfile(_ name: String) async {
        guard name != profile else { return }
        saveCurrent()
        selectionGeneration = UUID(); buffering = false; held = ReplayBuffer(); opening = false
        selected = nil; transcript = Transcript(); profile = name; sessions = []
        draft = workspace.drafts[draftKey] ?? ""
        do { try await refreshSessions() } catch { notice = error.localizedDescription }
    }

    func openBot(_ bot: AgentProfile) async {
        if demo { openDemoBot(bot); return }
        guard !opening, let socket else { return }
        saveCurrent()
        opening = true
        let generation = UUID(); selectionGeneration = generation
        let cached = bot.canonicalID.flatMap { workspace.chats[key(bot.name, $0)] }
        selected = cached ?? ChatSnapshot(storedID: bot.canonicalID ?? "", profile: bot.name, title: bot.title)
        profile = bot.name
        transcript = Transcript(messages: cached?.messages ?? [], lastSequence: cached?.lastSequence ?? 0)
        draft = workspace.drafts[draftKey] ?? ""
        defer { if generation == selectionGeneration { opening = false } }
        do {
            // Exact canonical registry lookup, including hidden sessions. Failure is never absence.
            let result = try await socket.call("session.list", ["profile": .string(bot.name), "title": "Bot Chat", "include_hidden": true])
            var canonical = result["sessions"].array.first
            if canonical == nil, bot.canonicalID != nil { throw RPCFailure("Le Bot Chat est temporairement indisponible. Réessayez dans un instant.") }
            if canonical == nil {
                guard hasBotProtocol else { throw RPCFailure("Mettez Hermes à jour pour utiliser le Bot Mode natif.") }
                let created = try await socket.call("session.create", ["profile": .string(bot.name), "title": "Bot Chat", "hidden": true, "follow_profile_config": true])
                do {
                    _ = try await socket.call("session.title", ["session_id": created["session_id"], "title": "Bot Chat"])
                    canonical = ["id": created["stored_session_id"], "title": "Bot Chat"]
                } catch {
                    // A second client may have won the canonical-title race. Adopt only a proven winner.
                    let lookup = try await socket.call("session.list", ["profile": .string(bot.name), "title": "Bot Chat", "include_hidden": true])
                    guard let winner = lookup["sessions"].array.first else { throw error }
                    canonical = winner
                }
            }
            guard generation == selectionGeneration, let row = canonical else { return }
            await openConversation(Conversation(row, profile: bot.name), title: bot.title)
        } catch { if generation == selectionGeneration { selected?.runtimeID = ""; notice = error.localizedDescription } }
    }

    func openConversation(_ conversation: Conversation, title: String? = nil) async {
        saveCurrent()
        let generation = UUID(); selectionGeneration = generation
        let cached = workspace.chats[key(conversation.profile, conversation.id)]
        selected = cached ?? ChatSnapshot(storedID: conversation.id, profile: conversation.profile, title: title ?? conversation.title)
        if let title { selected?.title = title }
        profile = conversation.profile
        transcript = Transcript(messages: selected?.messages ?? [], lastSequence: selected?.lastSequence ?? 0)
        draft = workspace.drafts[draftKey] ?? ""
        opening = true
        defer { if generation == selectionGeneration { opening = false } }
        guard !demo, state == .connected, let selected else { return }
        do { try await attach(selected, generation: generation) }
        catch { if generation == selectionGeneration { notice = error.localizedDescription } }
    }

    private func attach(_ chat: ChatSnapshot, generation: UUID) async throws {
        guard let socket else { return }
        buffering = true; held = ReplayBuffer()
        defer { if generation == selectionGeneration { buffering = false } }
        let canReplay = !chat.runtimeID.isEmpty && chat.epoch == socket.epoch && chat.lastSequence > 0 && !transcript.messages.contains(where: { $0.delivery != .confirmed })
        let response = try await socket.call("session.resume", ["profile": .string(chat.profile), "session_id": .string(chat.storedID), "omit_messages": .bool(canReplay)])
        guard generation == selectionGeneration else { return }
        let runtime = response["session_id"].string
        guard !runtime.isEmpty else { throw RPCFailure("Hermes n’a pas retourné de session active.") }
        selected?.runtimeID = runtime
        let stored = response["session_key"].string.isEmpty ? response["stored_session_id"].string : response["session_key"].string
        if !stored.isEmpty { selected?.storedID = stored }
        selected?.epoch = socket.epoch
        let replay = try await socket.call("session.events.since", ["session_id": .string(runtime), "last_seen": .number(Double(canReplay && runtime == chat.runtimeID ? chat.lastSequence : 0))], timeout: 12)
        guard generation == selectionGeneration else { return }
        if canReplay && runtime == chat.runtimeID && !replay["truncated"].bool && replay["epoch"].string == socket.epoch {
            let events = held.drain(replayed: replay["events"].array, after: transcript.lastSequence, session: runtime)
            for event in events { transcript.apply(event) }
            if !response["pending_approval"].isNull { transcript.approval = response["pending_approval"] }
            if !response["pending_clarify"].isNull { transcript.clarification = response["pending_clarify"] }
            if !events.contains(where: { $0["type"].string == "message.complete" }) { transcript.running = response["running"].bool }
        } else {
            let full = response["messages_omitted"].bool ? try await socket.call("session.resume", ["profile": .string(chat.profile), "session_id": .string(chat.storedID)]) : response
            guard generation == selectionGeneration else { return }
            let fresh = try await socket.call("session.events.since", ["session_id": .string(runtime), "last_seen": 0], timeout: 12)
            guard generation == selectionGeneration else { return }
            let events = held.drain(replayed: fresh["events"].array, after: 0, session: runtime)
            transcript.recover(full, events: events, latestSequence: max(fresh["latest_seq"].int, events.map { $0["seq"].int }.max() ?? 0))
        }
        scheduleSave()
    }

    func newChat() {
        saveCurrent(); selectionGeneration = UUID(); opening = false; buffering = false; held = ReplayBuffer()
        selected = nil; transcript = Transcript(); draft = workspace.drafts[draftKey] ?? ""
    }

    func send() async {
        guard canSend else { return }
        if demo { await demoReply(); return }
        guard let socket else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDraftKey = draftKey
        let generation = selectionGeneration
        sending = true
        defer { sending = false }
        do {
            if selected == nil {
                let result = try await socket.call("session.create", ["profile": .string(profile)])
                guard generation == selectionGeneration else { return }
                selected = ChatSnapshot(storedID: result["stored_session_id"].string, runtimeID: result["session_id"].string, profile: profile, title: String(text.prefix(60)), epoch: socket.epoch)
            }
            guard let chat = selected else { return }
            let optimistic = ChatMessage(role: "user", text: text, delivery: .sending)
            transcript.messages.append(optimistic)
            draft = ""; workspace.drafts[draftKey] = ""; workspace.drafts[originalDraftKey] = ""
            transcript.running = true; transcript.activity = "Réfléchit…"
            await persistNow()
            do {
                _ = try await socket.call("prompt.submit", ["session_id": .string(chat.runtimeID), "text": .string(text)])
                guard generation == selectionGeneration else { return }
                if let i = transcript.messages.firstIndex(where: { $0.id == optimistic.id }) { transcript.messages[i].delivery = .confirmed }
            } catch {
                guard generation == selectionGeneration else { return }
                let rpc = error as? RPCFailure
                if let i = transcript.messages.firstIndex(where: { $0.id == optimistic.id }) { transcript.messages[i].delivery = (rpc?.code ?? -1) > 0 ? .failed : .uncertain }
                transcript.running = false; transcript.activity = nil
                notice = "Envoi à vérifier : \(error.localizedDescription) Le message ne sera pas renvoyé automatiquement."
            }
            scheduleSave()
        } catch { notice = error.localizedDescription }
    }

    func interrupt() async {
        guard let selected, let socket else { return }
        do { _ = try await socket.call("session.interrupt", ["session_id": .string(selected.runtimeID)]) }
        catch { notice = error.localizedDescription }
    }

    func answerApproval(_ choice: String) async {
        guard let selected, let approval = transcript.approval, let socket else { return }
        do {
            let result = try await socket.call("approval.respond", ["session_id": .string(selected.runtimeID), "request_id": approval["request_id"], "choice": .string(choice)])
            if result["resolved"].bool { transcript.approval = nil }
            else { notice = "Cette demande n’est plus active. La conversation va se mettre à jour." }
        } catch { notice = error.localizedDescription }
    }

    func answerClarification(_ text: String, qid: String? = nil) async {
        guard let request = transcript.clarification, let socket else { return }
        var params: [String: JSONValue] = ["request_id": request["request_id"], "answer": .string(text)]
        if let qid { params["question_id"] = .string(qid) }
        do {
            _ = try await socket.call("clarify.respond", .object(params))
            if qid == nil { transcript.clarification = nil }
        } catch { notice = error.localizedDescription }
    }

    func answerCredential(_ value: String) async {
        guard let request = transcript.credential, let socket else { return }
        let sudo = request["event_type"].string == "sudo.request"
        do {
            _ = try await socket.call(sudo ? "sudo.respond" : "secret.respond", .object(["request_id": request["request_id"], sudo ? "password" : "value": .string(value)]))
            transcript.credential = nil
        } catch { notice = error.localizedDescription }
    }

    func loadRoutines() async {
        guard let socket else { return }
        let owner = selected?.profile ?? profile
        do {
            let result = try await socket.call("cron.manage", ["action": "list", "profile": .string(owner), "include_disabled": true])
            guard owner == (selected?.profile ?? profile) else { return }
            guard result["scoped"].string == owner else { throw RPCFailure("Mettez Hermes à jour pour gérer les routines de ce profil.") }
            routines = result["jobs"].array.map(Routine.init)
        } catch { notice = error.localizedDescription }
    }

    func toggleRoutine(_ routine: Routine) async {
        guard let socket else { return }
        do {
            let result = try await socket.call("cron.manage", ["action": .string(routine.paused ? "resume" : "pause"), "profile": .string(selected?.profile ?? profile), "name": .string(routine.id)])
            try checkResult(result)
            await loadRoutines()
        } catch { notice = error.localizedDescription }
    }

    func createRoutine(name: String, prompt: String, schedule: String) async throws {
        guard let socket else { throw RPCFailure("Connectez Hermes pour créer une routine.") }
        let owner = selected?.profile ?? profile
        let result = try await socket.call("cron.manage", ["action": "add", "profile": .string(owner), "name": .string("[bot:\(owner)] \(name)"), "prompt": .string(prompt), "schedule": .string(schedule), "deliver": .string("bot-chat:\(owner)")])
        try checkResult(result)
        await loadRoutines()
    }

    func createBot(name: String, description: String, soul: String, clone: String) async throws {
        guard let socket else { throw RPCFailure("Connectez Hermes pour créer un agent.") }
        var params: [String: JSONValue] = ["name": .string(name), "description": .string(description), "soul": .string(soul), "share_auth": true, "no_alias": true]
        if !clone.isEmpty { params["clone_from"] = .string(clone) }
        let result = try await socket.call("profiles.create", .object(params), timeout: 90)
        try checkResult(result)
        try await refreshProfiles()
    }

    func editBot(name: String, description: String, soul: String) async throws {
        guard let socket else { return }
        let result = try await socket.call("profiles.configure", ["name": .string(name), "description": .string(description), "soul": .string(soul)])
        try checkResult(result)
        guard result["applied"]["soul"].bool && result["applied"]["description"].bool else { throw RPCFailure("Hermes n’a pas confirmé toutes les modifications du profil.") }
        try await refreshProfiles()
    }

    func describeBot(_ name: String) async throws -> JSONValue {
        guard let socket else { throw RPCFailure("Connectez Hermes pour modifier ce profil.") }
        return try await socket.call("profiles.describe", ["name": .string(name)])
    }

    func groupRequest(_ method: String, params: JSONValue = [:], connectionID: UUID) async throws -> JSONValue {
        guard activeConnection?.id == connectionID, state == .connected, let socket else { throw RPCFailure("Reconnectez le serveur de ce groupe.") }
        let result = try await socket.call(method, params)
        guard activeConnection?.id == connectionID else { throw CancellationError() }
        return result
    }

    /// Each tool stays pinned to the server and profile that opened it.
    func toolRequest(_ path: String, method: String = "GET", body: JSONValue? = nil,
                     query: [URLQueryItem] = [], connectionID: UUID?, profile expectedProfile: String,
                     rpc: Bool = false) async throws -> JSONValue {
        guard activeConnection?.id == connectionID, profile == expectedProfile,
              let http, state == .connected else { throw RPCFailure("Reconnectez cet agent pour accéder à ses outils.") }
        let generation = connectionGeneration
        let result: JSONValue
        if rpc {
            guard let socket else { throw RPCFailure("Hermes est déconnecté.") }
            var params = body?.object ?? [:]; params["profile"] = .string(expectedProfile)
            result = try await socket.call(path, .object(params))
        } else {
            result = try await http.request(path, method: method, body: body,
                query: query + [URLQueryItem(name: "profile", value: expectedProfile)])
        }
        try Task.checkCancellation()
        guard generation == connectionGeneration, profile == expectedProfile else { throw CancellationError() }
        try checkResult(result)
        return result
    }

    private func checkResult(_ result: JSONValue) throws {
        if result["success"] == .bool(false) || !result["error"].isNull { throw RPCFailure(result["error"].string.isEmpty ? "Hermes n’a pas pu effectuer cette action." : result["error"].string) }
    }

    private func receive(_ event: JSONValue) {
        let type = event["type"].string
        if type.hasSuffix(".changed") {
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(700))
                    try await self?.refreshProfiles(); try await self?.refreshSessions()
                } catch { }
            }
        }
        if buffering { held.held.append(event); return }
        guard event["session_id"].string == selected?.runtimeID else { return }
        if type == "message.delta" || type == "reasoning.delta" || type == "thinking.delta" {
            streamEvents.append(event)
            if streamTask == nil {
                streamTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(33))
                    self?.flushStream()
                }
            }
        } else {
            flushStream(); transcript.apply(event); scheduleSave()
            if type == "message.complete" {
                Task { [weak self] in await self?.refreshCompletedHistory(); try? await self?.refreshSessions() }
            }
        }
    }

    private func refreshCompletedHistory() async {
        guard let socket, let chat = selected, !transcript.running else { return }
        let generation = selectionGeneration
        let sequence = transcript.lastSequence
        do {
            let history = try await socket.call("session.history", ["session_id": .string(chat.runtimeID)])
            guard generation == selectionGeneration, sequence == transcript.lastSequence, !transcript.running, !sending else { return }
            transcript.hydrate(history)
            scheduleSave()
        } catch { /* The streamed final answer remains visible; retry on the next attach. */ }
    }

    private func flushStream() {
        streamTask?.cancel(); streamTask = nil
        let events = streamEvents; streamEvents.removeAll(keepingCapacity: true)
        for event in events where event["session_id"].string == selected?.runtimeID { transcript.apply(event) }
        if !events.isEmpty { scheduleSave() }
    }

    func draftChanged() { workspace.drafts[draftKey] = draft; scheduleSave() }

    private func key(_ profile: String, _ stored: String) -> String { "\(profile):\(stored)" }

    private func saveCurrent() {
        flushStream()
        workspace.drafts[draftKey] = draft
        if var chat = selected, !chat.storedID.isEmpty {
            chat.messages = Array(transcript.messages.suffix(500))
            chat.lastSequence = transcript.lastSequence
            workspace.chats[key(chat.profile, chat.storedID)] = chat
            selected = chat
        }
        workspace.selected = selected.flatMap { $0.storedID.isEmpty ? nil : key($0.profile, $0.storedID) }
    }

    private func scheduleSave() {
        guard !demo else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.persistNow()
        }
    }

    private func persistNow() async {
        guard !demo, let activeConnection else { return }
        saveCurrent()
        workspace.profiles = profiles; workspace.sessions = sessions
        do { try await cache.save(workspace, key: activeConnection.id.uuidString) }
        catch { notice = "Le cache local n’a pas pu être enregistré. Votre historique reste chez Hermes." }
    }

    func removeConnection(_ connection: SavedConnection) async {
        if activeConnection?.id == connection.id {
            saveTask?.cancel(); reconnectTask?.cancel(); reconnectTask = nil
            socket?.close(); http?.invalidate(); http = nil; socket = nil
            connectionGeneration = UUID(); selectionGeneration = UUID()
            activeConnection = nil; selected = nil; profiles = []; sessions = []; draft = ""
            transcript = Transcript(); workspace = CachedWorkspace(); state = .offline
        }
        Keychain.delete(connection.id.uuidString)
        connections.removeAll { $0.id == connection.id }
        do { try await cache.remove(connection.id.uuidString); try await cache.remove(connection.id.uuidString + "-groups"); try await cache.save(connections, key: "connections") }
        catch { notice = error.localizedDescription }
    }

    func loadDemo() {
        demo = true; state = .connected; hasBotProtocol = true
        profiles = [
            ["name": "default", "display_name": "Hermes", "description": "Votre complice au quotidien.", "model": "Hermes 4", "skill_count": 12],
            ["name": "research", "display_name": "Atlas", "description": "Curieux de tout. Précis sur l’essentiel.", "model": "Hermes 4", "skill_count": 8],
            ["name": "studio", "display_name": "Studio", "description": "Des idées aux choses qui existent.", "model": "Hermes 4", "skill_count": 6]
        ].map { AgentProfile(.object($0)) }
        selected = ChatSnapshot(storedID: "demo-default", profile: "default", title: "Hermes")
        transcript.messages = [
            .init(role: "user", text: "J’aimerais une journée un peu plus légère."),
            .init(role: "assistant", text: "On fait de la place.\n\nChoisis **une seule chose** qui rendrait ta journée satisfaisante. Le reste peut attendre.\n\nQu’est-ce qui compte le plus pour toi aujourd’hui ?")
        ]
        if ProcessInfo.processInfo.arguments.contains("--demo-onboarding") { demo = false; connections = []; activeConnection = nil; selected = nil; profiles = []; state = .offline }
    }

    private func openDemoBot(_ bot: AgentProfile) {
        saveCurrent()
        let storedID = "demo-\(bot.name)"
        selected = workspace.chats[key(bot.name, storedID)] ?? ChatSnapshot(storedID: storedID, profile: bot.name, title: bot.title)
        profile = bot.name
        transcript = Transcript(messages: selected?.messages ?? [])
        draft = workspace.drafts[draftKey] ?? ""
        if transcript.messages.isEmpty {
            transcript.messages = [.init(role: "assistant", text: "Bonjour, je suis \(bot.title). \(bot.detail)\n\nQu’est-ce qu’on explore ensemble ?")]
        }
    }

    private func demoReply() async {
        let text = draft; draft = ""
        transcript.messages.append(.init(role: "user", text: text))
        transcript.running = true
        for word in "Ceci est un aperçu d’Hermès iOS. Connectez votre agent Hermes pour retrouver vos conversations, vos profils et vos outils.".split(separator: " ") {
            try? await Task.sleep(for: .milliseconds(60))
            transcript.apply(["type": "message.delta", "payload": ["text": .string(String(word) + " ")]])
        }
        if let i = transcript.messages.indices.last { transcript.messages[i].streaming = false }
        transcript.running = false
    }
}
