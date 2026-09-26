import Foundation
import Observation

struct CachedWorkspace: Codable, Sendable {
    var profiles: [AgentProfile] = []
    var sessions: [Conversation] = []
    var historyIndex: ConversationIndex?
    var chats: [String: ChatSnapshot] = [:]
    var drafts: [String: String] = [:]
    var selected: String?
    var attachments: [String: [DraftAttachment]]?
    var imageCleanup: [String: [String]]?
    var activity: ConversationActivity?
    var botConversations: [String: Conversation]?
}

@MainActor @Observable
final class AppModel {
    enum ConnectionState { case offline, connecting, connected, signInRequired }
    var connections: [SavedConnection] = []
    var activeConnection: SavedConnection?
    var state: ConnectionState = .offline
    var profiles: [AgentProfile] = []
    var botConversations: [String: Conversation] = [:]
    var sessions: [Conversation] = []
    var historyRevision = 0
    @ObservationIgnored private let historyRequests = HistoryRequests()
    @ObservationIgnored private var historyIndex = ConversationIndex()
    var profile = "default" {
        didSet { if !demo, oldValue != profile { sessions = historyIndex[profile]; routines = [] } }
    }
    var selected: ChatSnapshot?
    var transcript = Transcript()
    var draft = ""
    var attachmentDrafts: [String: [DraftAttachment]] = [:]
    var attachments: [DraftAttachment] { attachmentDrafts[draftKey] ?? [] }
    var voiceActive = false
    var importingAttachments = false
    @ObservationIgnored private var imageCleanup: [String: [String]] = [:]
    var navigationRevision = UUID()
    var notice: String?
    var chatError: String?
    var toast: String?
    private var conversationActivity = ConversationActivity()
    @ObservationIgnored private var chatVisible = true
    private var ownershipConflictContext: String?
    var canContinueInNewChat: Bool { notice == RPCFailure.ownershipMessage && ownershipConflictContext == attachmentContext && !sending && !voiceActive }
    var commandOutput: String?
    var routines: [Routine] = []
    var botMode = true
    var opening = false
    var sending = false
    var demo = false
    var hasBooted = false
    var notificationRoutingReady = false
    var hasBotProtocol = false
    var draftKey: String { selected.map { key($0.profile, $0.storedID) } ?? "draft-\(profile)" }
    var agent: AgentProfile? { profiles.first { $0.name == (selected?.profile ?? profile) } }
    var canSend: Bool { (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !importingAttachments && !voiceActive && (state == .connected || demo) && !opening && !sending && !transcript.running && (selected == nil || !(selected?.runtimeID.isEmpty ?? true) || demo) }

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
    @ObservationIgnored private var hydratedSelection: UUID?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var foreground = true

    func boot() async {
        guard !hasBooted else { return }
        hasBooted = true
        defer { notificationRoutingReady = true }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { loadDemo(); return }
        #endif
        connections = await cache.read([SavedConnection].self, key: "connections") ?? []
        if let first = connections.first { await activate(first) }
    }

    func openNotification(_ target: NotificationTarget) async {
        // Notification taps can precede boot, or arrive during an in-flight upload.
        // Keep the target durable until it can be selected without losing a draft.
        while !notificationRoutingReady || sending || voiceActive {
            if notificationRoutingReady && connections.isEmpty {
                notice = "Reconnectez le serveur de cette notification dans les réglages."
                PushNotifications.shared.opened(target)
                return
            }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        guard !Task.isCancelled, PushNotifications.shared.pendingTarget == target else { return }
        guard let connection = connections.first(where: { $0.id == target.connectionID }) else {
            notice = "Le serveur de cette notification n’est plus enregistré sur cet iPhone."
            PushNotifications.shared.opened(target); return
        }
        if activeConnection?.id != connection.id { await activate(connection) }
        guard !Task.isCancelled, PushNotifications.shared.pendingTarget == target else { return }
        navigationRevision = UUID()
        let row: JSONValue = ["id": .string(target.sessionID), "title": "Conversation"]
        await openConversation(Conversation(row, profile: target.profile))
        if !Task.isCancelled { PushNotifications.shared.opened(target) }
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
        saveTask?.cancel(); saveTask = nil
        await persistNow()
        reconnectTask?.cancel(); reconnectTask = nil
        refreshTask?.cancel(); streamTask?.cancel()
        socket?.close(); http?.invalidate()
        connectionGeneration = UUID(); selectionGeneration = UUID()
        let generation = connectionGeneration
        activeConnection = connection; demo = false; state = .connecting; routines = []
        connections.removeAll { $0.id == connection.id }
        connections.insert(connection, at: 0)
        try? await cache.save(connections, key: "connections")
        guard generation == connectionGeneration else { return }
        opening = false; sending = false; buffering = false; held = ReplayBuffer(); streamEvents = []
        let restored = await cache.read(CachedWorkspace.self, key: connection.id.uuidString) ?? CachedWorkspace()
        guard generation == connectionGeneration else { return }
        workspace = restored
        conversationActivity = restored.activity ?? ConversationActivity()
        chatError = nil; toast = nil
        attachmentDrafts = restored.attachments ?? [:]
        imageCleanup = restored.imageCleanup ?? [:]
        profiles = workspace.profiles
        botConversations = workspace.botConversations ?? [:]
        historyIndex = workspace.historyIndex ?? ConversationIndex(legacy: workspace.sessions)
        selected = workspace.selected.flatMap { workspace.chats[$0] }
        profile = selected?.profile ?? profiles.first?.name ?? "default"
        sessions = historyIndex[profile]
        transcript = Transcript(messages: selected?.messages ?? [], lastSequence: selected?.lastSequence ?? 0)
        draft = workspace.drafts[draftKey] ?? ""
        conversationActivity.visit(profile: profile)
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
                    channel.onEvent = { [weak self, weak channel] event in
                        guard let self, let channel, self.socket === channel, generation == self.connectionGeneration else { return }
                        self.receive(event)
                    }
                    channel.onRequestsChanged = { [weak self, weak channel] in
                        guard let self, let channel, self.socket === channel, generation == self.connectionGeneration else { return }
                        self.syncServerRequests()
                    }
                    channel.onDisconnect = { [weak self, weak channel] error in
                        guard let self, let channel, self.socket === channel, generation == self.connectionGeneration else { return }
                        self.disconnected(error)
                    }
                    self.buffering = true; self.held = ReplayBuffer()
                    try await channel.open(http: http)
                    try Task.checkCancellation()
                    guard generation == self.connectionGeneration else { return }
                    while let selected = self.selected {
                        let selection = self.selectionGeneration
                        do { try await self.attach(selected, generation: selection) }
                        catch is CancellationError {
                            try Task.checkCancellation()
                            guard generation == self.connectionGeneration else { return }
                            if selection != self.selectionGeneration { continue }
                            throw CancellationError()
                        } catch let error as RPCFailure where error.code > 0 && error.code != 401 && !error.retryableSessionResume {
                            if selection == self.selectionGeneration {
                                self.selected?.runtimeID = ""; self.notice = error.localizedDescription
                            }
                        }
                        if selection == self.selectionGeneration { break }
                    }
                    self.buffering = false
                    guard generation == self.connectionGeneration, !Task.isCancelled else { return }
                    self.state = .connected
                    self.reconnectTask = nil
                    self.scheduleListRefresh(delay: 0)
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
            if state != .connected, !sending { startReconnect() }
        } else {
            let lease = BackgroundLease(name: "Save Hermès conversation")
            defer { lease.end() }
            // Keep the channel until an in-flight submission is acknowledged.
            if !sending { suspendConnection() }
            await persistNow()
        }
    }

    private func suspendConnection() {
        reconnectTask?.cancel(); reconnectTask = nil
        refreshTask?.cancel(); refreshTask = nil
        flushStream()
        socket?.close(); state = .offline
    }

    private func scheduleListRefresh(delay: Double = 0.7) {
        guard foreground, state == .connected else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            // Independent reads: a slow roster must never block the chat or history.
            async let roster: Void = self.refreshProfiles()
            do { try await self.refreshSessions() } catch { }
            do { try await roster } catch { }
        }
    }

    func refreshProfiles() async throws {
        guard let socket else { return }
        let generation = connectionGeneration
        let result = try await socket.call("profiles.list", ["include_sessions": true])
        try Task.checkCancellation()
        guard generation == connectionGeneration, self.socket === socket else { return }
        guard case .array = result["profiles"] else { throw RPCFailure("Hermes a renvoyé une liste de profils invalide.") }
        profiles = result["profiles"].array.map(AgentProfile.init)
        let canonical = result["profiles"].array.compactMap { row -> Conversation? in
            let session = row["canonical_session"]
            guard !session["id"].string.isEmpty else { return nil }
            return Conversation(session, profile: row["name"].string)
        }
        botConversations = Dictionary(canonical.map { ($0.profile, $0) }, uniquingKeysWith: { _, latest in latest })
        observeConversations(canonical, establishesBaseline: false)
        hasBotProtocol = result["bot_mode_protocol"].bool
        if selected == nil, !profiles.contains(where: { $0.name == profile }), let first = profiles.first { profile = first.name }
        scheduleSave()
    }

    func refreshSessions() async throws {
        guard !demo else { return }
        guard state == .connected, let socket else { throw RPCFailure("Connexion à Hermes en cours…", code: -1) }
        let generation = connectionGeneration
        let owner = profile
        let scope = "\(ObjectIdentifier(socket))|\(owner)"
        let result = try await historyRequests.load(scope: scope) {
            try await socket.call("session.list", ["profile": .string(owner), "limit": 100])
        }
        try Task.checkCancellation()
        guard generation == connectionGeneration, self.socket === socket, state == .connected else { throw CancellationError() }
        guard case .array = result["sessions"] else { throw RPCFailure("Hermes a renvoyé une liste de conversations invalide.") }
        let rows = result["sessions"].array.map { Conversation($0, profile: owner) }
        observeConversations(rows, baselineProfile: owner)
        historyIndex.update(rows, profile: owner)
        if profile == owner { sessions = historyIndex[owner]; historyRevision += 1 }
        scheduleSave()
    }

    func changeProfile(_ name: String) async {
        guard !sending, !voiceActive, name != profile else { return }
        saveCurrent()
        selectionGeneration = UUID(); buffering = false; held = ReplayBuffer(); opening = false
        selected = nil; transcript = Transcript(); profile = name
        chatError = nil; conversationActivity.visit(profile: name)
        draft = workspace.drafts[draftKey] ?? ""
        do { try await refreshSessions() } catch { notice = error.localizedDescription }
    }

    func openBot(_ bot: AgentProfile) async {
        guard !sending, !voiceActive else { return }
        if demo { openDemoBot(bot); return }
        guard !opening, let socket else { return }
        saveCurrent()
        opening = true
        let generation = UUID(); selectionGeneration = generation
        let cached = bot.canonicalID.flatMap { workspace.chats[key(bot.name, $0)] }
        selected = cached ?? ChatSnapshot(storedID: bot.canonicalID ?? "", profile: bot.name, title: bot.title)
        profile = bot.name
        chatError = nil; conversationActivity.visit(profile: bot.name)
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
                let created = try await socket.call("session.create", ["close_on_disconnect": false, "profile": .string(bot.name), "title": "Bot Chat", "hidden": true, "follow_profile_config": true])
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
        } catch {
            if generation == selectionGeneration {
                selected?.runtimeID = ""
                if foreground, !(error is CancellationError) { notice = error.localizedDescription }
            }
        }
    }

    func openConversation(_ conversation: Conversation, title: String? = nil) async {
        guard !sending, !voiceActive else { return }
        saveCurrent()
        let generation = UUID(); selectionGeneration = generation
        let cached = workspace.chats[key(conversation.profile, conversation.id)]
        selected = cached ?? ChatSnapshot(storedID: conversation.id, profile: conversation.profile, title: title ?? conversation.title)
        if let title { selected?.title = title }
        profile = conversation.profile
        chatError = nil; conversationActivity.visit(profile: conversation.profile)
        transcript = Transcript(messages: selected?.messages ?? [], lastSequence: selected?.lastSequence ?? 0)
        draft = workspace.drafts[draftKey] ?? ""
        opening = true
        defer { if generation == selectionGeneration { opening = false; markCurrentConversationRead() } }
        guard !demo, state == .connected, let selected else { return }
        do { try await attach(selected, generation: generation) }
        catch {
            if generation == selectionGeneration {
                self.selected?.runtimeID = ""; hydratedSelection = nil
                if foreground, !(error is CancellationError) { notice = error.localizedDescription }
            }
        }
    }

    private func attach(_ chat: ChatSnapshot, generation: UUID) async throws {
        guard let socket else { return }
        let connection = connectionGeneration
        func validate() throws {
            try Task.checkCancellation()
            guard generation == selectionGeneration, connection == connectionGeneration, self.socket === socket else { throw CancellationError() }
        }
        buffering = true; held = ReplayBuffer()
        defer { if generation == selectionGeneration { buffering = false } }
        let canReplay = !chat.runtimeID.isEmpty && chat.epoch == socket.epoch && chat.lastSequence > 0 && !transcript.messages.contains(where: { $0.delivery != .confirmed })
        let response = try await socket.call("session.resume", ["close_on_disconnect": false, "profile": .string(chat.profile), "session_id": .string(chat.storedID), "omit_messages": .bool(canReplay)])
        try validate()
        let runtime = response["session_id"].string
        guard !runtime.isEmpty else { throw RPCFailure("Hermes n’a pas retourné de session active.") }
        selected?.runtimeID = runtime
        let stored = response["session_key"].string.isEmpty ? response["stored_session_id"].string : response["session_key"].string
        if !stored.isEmpty { selected?.storedID = stored }
        selected?.epoch = socket.epoch
        let replay = try await socket.call("session.events.since", ["session_id": .string(runtime), "last_seen": .number(Double(canReplay && runtime == chat.runtimeID ? chat.lastSequence : 0))], timeout: 40)
        try validate()
        if canReplay && runtime == chat.runtimeID && !replay["truncated"].bool && replay["epoch"].string == socket.epoch {
            let events = held.drain(replayed: replay["events"].array, after: transcript.lastSequence, session: runtime)
            for event in events { transcript.apply(event) }
            if !response["pending_approval"].isNull { transcript.approval = response["pending_approval"] }
            if !response["pending_clarify"].isNull { transcript.clarification = response["pending_clarify"] }
            if !events.contains(where: { $0["type"].string == "message.complete" }) { transcript.running = response["running"].bool }
        } else {
            let full = response["messages_omitted"].bool ? try await socket.call("session.resume", ["close_on_disconnect": false, "profile": .string(chat.profile), "session_id": .string(chat.storedID)]) : response
            try validate()
            // Reuse the first replay when the same response already carried the full snapshot.
            let fresh = response["messages_omitted"].bool
                ? try await socket.call("session.events.since", ["session_id": .string(runtime), "last_seen": 0], timeout: 40)
                : replay
            try validate()
            let events = held.drain(replayed: fresh["events"].array, after: 0, session: runtime)
            transcript.recover(full, events: events, latestSequence: max(fresh["latest_seq"].int, events.map { $0["seq"].int }.max() ?? 0))
        }
        syncServerRequests()
        hydratedSelection = generation
        markCurrentConversationRead()
        scheduleSave()
    }

    func newChat() {
        guard !sending, !voiceActive else { return }
        saveCurrent(); selectionGeneration = UUID(); opening = false; buffering = false; held = ReplayBuffer()
        selected = nil; transcript = Transcript(); draft = workspace.drafts[draftKey] ?? ""
        chatError = nil
    }

    func continueInNewChat() async {
        guard ownershipConflictContext == attachmentContext, !sending, !opening, !voiceActive,
              state == .connected, let socket else { return }
        let source = draftKey, text = draft, files = attachments
        let selection = selectionGeneration, connection = connectionGeneration, owner = profile
        opening = true
        defer { if selection == selectionGeneration { opening = false } }
        do {
            let result = try await socket.call("session.create", ["close_on_disconnect": false, "profile": .string(owner)])
            guard selection == selectionGeneration, connection == connectionGeneration, self.socket === socket else { return }
            guard !result["session_id"].string.isEmpty, !result["stored_session_id"].string.isEmpty else { throw RPCFailure("Hermes n’a pas confirmé l’ouverture du nouveau fil.") }
            saveCurrent()
            workspace.drafts[source] = ""; attachmentDrafts[source] = nil
            selected = ChatSnapshot(storedID: result["stored_session_id"].string, runtimeID: result["session_id"].string, profile: owner, title: "Nouvelle conversation", epoch: socket.epoch)
            hydratedSelection = selectionGeneration
            transcript = Transcript(); draft = text; attachmentDrafts[draftKey] = files
            workspace.drafts[draftKey] = text; ownershipConflictContext = nil
            await persistNow()
        } catch { if selection == selectionGeneration, connection == connectionGeneration { notice = error.localizedDescription } }
    }

    func addAttachment(data: Data, name: String, mimeType: String, context: String) async throws {
        guard context == attachmentContext, !sending else { throw RPCFailure("Revenez à la conversation choisie avant d’ajouter ce fichier.") }
        guard data.count <= DraftAttachment.maximumBytes, !data.isEmpty else { throw RPCFailure("Choisissez un fichier de 10 Mo maximum, non vide.") }
        guard attachments.count < DraftAttachment.maximumCount else { throw RPCFailure("Ajoutez jusqu’à quatre pièces jointes par message.") }
        let item = DraftAttachment(name: name, mimeType: mimeType, size: data.count)
        try await cache.saveAttachment(data, id: item.id)
        guard context == attachmentContext, !sending else { await cache.removeAttachment(item.id); throw CancellationError() }
        attachmentDrafts[draftKey, default: []].append(item)
        scheduleSave()
    }

    var attachmentContext: String { "\(activeConnection?.id.uuidString ?? "demo")|\(draftKey)" }

    func removeAttachment(_ item: DraftAttachment) {
        guard !sending else { return }
        attachmentDrafts[draftKey]?.removeAll { $0.id == item.id }
        Task { await cache.removeAttachment(item.id) }
        scheduleSave()
    }

    func send() async {
        guard canSend else { return }
        chatError = nil
        if demo { await demoReply(); return }
        do { _ = try await submit(draft.trimmingCharacters(in: .whitespacesAndNewlines), consumeDraft: true) }
        catch is CancellationError { }
        catch {
            if (error as? RPCFailure)?.sessionOwnedElsewhere == true || error.localizedDescription == RPCFailure.ownershipMessage { notice = error.localizedDescription }
            else { chatError = error.localizedDescription }
        }
    }

    /// A spoken turn never consumes the user's typed draft or its attachments.
    func sendVoice(_ text: String) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCFailure("Aucune parole détectée.") }
        return try await submit(text, consumeDraft: false)
    }

    private func submit(_ input: String, consumeDraft: Bool) async throws -> String {
        guard !sending, !opening, !transcript.running, state == .connected, let socket else { throw RPCFailure("Attendez que Hermes soit prêt avant de parler ou d’envoyer un message.") }
        let originalDraftKey = draftKey
        let generation = selectionGeneration
        let connection = connectionGeneration
        let pending = consumeDraft ? attachments : []
        var text = input
        if text.isEmpty { text = pending.allSatisfy(\.isImage) ? "Que vois-tu dans ces images ?" : "Examine ces fichiers." }
        sending = true
        let lease = BackgroundLease(name: "Send message to Hermès") { [weak self] in
            guard let self, connection == self.connectionGeneration, !self.foreground else { return }
            // Expiration is a transport interruption, never an automatic resend/agent stop.
            self.suspendConnection()
        }
        defer {
            lease.end()
            if connection == connectionGeneration {
                sending = false
                if !foreground { suspendConnection() }
                else if state != .connected { startReconnect() }
            }
        }
        func validate() throws {
            try Task.checkCancellation()
            guard generation == selectionGeneration, connection == connectionGeneration, self.socket === socket else { throw CancellationError() }
        }
        if selected == nil {
            let result = try await socket.call("session.create", ["close_on_disconnect": false, "profile": .string(profile)])
            try validate()
            selected = ChatSnapshot(storedID: result["stored_session_id"].string, runtimeID: result["session_id"].string, profile: profile, title: String(text.prefix(60)), epoch: socket.epoch)
            hydratedSelection = selectionGeneration
            attachmentDrafts[draftKey] = attachmentDrafts.removeValue(forKey: originalDraftKey)
            workspace.drafts[draftKey] = draft
            workspace.drafts[originalDraftKey] = nil
        }
        guard let chat = selected, !chat.runtimeID.isEmpty else { throw RPCFailure("Rouvrez cette conversation pour envoyer un message.") }
        let runtime = chat.runtimeID
        if consumeDraft, let command = SlashInput(text) {
            guard pending.isEmpty else { throw RPCFailure("Envoyez vos pièces jointes dans un message séparé de la commande.") }
            if ["new", "reset", "clear"].contains(command.name) { throw RPCFailure("Utilisez le bouton Nouvelle conversation pour ouvrir un nouveau fil. Votre Bot Chat reste disponible dans le sélecteur d’agent.") }
            var current = command
            var result: JSONValue = .null
            for _ in 0..<4 {
                do { result = try await socket.call("command.dispatch", ["session_id": .string(runtime), "name": .string(current.name), "arg": .string(current.argument)], timeout: 120) }
                catch let error as RPCFailure where error.code == 4018 {
                    result = try await socket.call("slash.exec", ["session_id": .string(runtime), "command": .string(current.text)], timeout: 120)
                }
                try validate()
                if result["type"].string != "alias" { break }
                guard let alias = SlashInput(result["target"].string.hasPrefix("/") ? result["target"].string : "/" + result["target"].string) else { throw RPCFailure("Hermes a renvoyé une commande invalide.") }
                current = alias
            }
            switch result["type"].string {
            case "send", "skill":
                guard !result["message"].string.isEmpty else { throw RPCFailure("Cette commande n’a pas fourni de message.") }
                text = result["message"].string
            case "prefill":
                draft = result["message"].string; scheduleSave(); return ""
            case "exec", "plugin", "":
                commandOutput = result["output"].string.isEmpty ? "Commande transmise à Hermes." : result["output"].string
                draft = ""; workspace.drafts[draftKey] = ""; await refreshCompletedHistory(); scheduleSave(); return ""
            default: throw RPCFailure("Ce type de commande nécessite une autre interface Hermes.")
            }
        }
        // A timed-out image attach has a known path: detach it before any new turn.
        for path in imageCleanup[runtime] ?? [] {
            _ = try await socket.call("image.detach", ["session_id": .string(runtime), "path": .string(path)])
            try validate()
        }
        imageCleanup[runtime] = nil
        var refs: [String] = []
        var imagePaths: [String] = []
        do {
            for var item in pending {
                if item.runtimeID != runtime || item.remotePath == nil {
                    let data = try await cache.attachment(item.id)
                    try validate()
                    let result = try await socket.call("file.attach", ["session_id": .string(runtime), "name": .string(item.name), "data_url": .string("data:\(item.mimeType);base64,\(data.base64EncodedString())")], timeout: 90)
                    try validate()
                    guard result["attached"].bool, !result["path"].string.isEmpty else { throw RPCFailure("Hermes n’a pas accepté le fichier.") }
                    item.remotePath = result["path"].string; item.remoteReference = result["ref_text"].string; item.runtimeID = runtime
                    if let index = attachmentDrafts[draftKey]?.firstIndex(where: { $0.id == item.id }) { attachmentDrafts[draftKey]?[index] = item }
                    scheduleSave()
                }
                if item.isImage { imagePaths.append(item.remotePath!) }
                else if let ref = item.remoteReference, !ref.isEmpty { refs.append(ref) }
                else { throw RPCFailure("Hermes n’a pas renvoyé de référence pour ce fichier.") }
            }
            for path in imagePaths {
                imageCleanup[runtime, default: []].append(path)
                await persistNow()
                try validate()
                // Hermes accepts file URLs; percent encoding also preserves spaces and quotes.
                let quoted = URL(fileURLWithPath: path).absoluteString
                _ = try await socket.call("image.attach", ["session_id": .string(runtime), "path": .string(quoted)])
                try validate()
            }
        } catch {
            // Keep cleanup paths even on cancellation/disconnect; never silently attach them to a later voice turn.
            throw error
        }
        let prompt = (refs + [text]).joined(separator: "\n\n")
        let display = text + (pending.isEmpty ? "" : "\n\n" + pending.map { "📎 " + $0.name }.joined(separator: "\n"))
        let optimistic = ChatMessage(role: "user", text: display, delivery: .sending)
        transcript.messages.append(optimistic)
        if consumeDraft {
            draft = ""; workspace.drafts[draftKey] = ""; workspace.drafts[originalDraftKey] = ""
            attachmentDrafts[draftKey] = nil
        }
        transcript.toolSteps = []; transcript.running = true; transcript.activity = "Réfléchit…"; transcript.failure = nil
        await persistNow()
        do {
            try validate()
            _ = try await socket.call("prompt.submit", ["session_id": .string(runtime), "text": .string(prompt)])
            imageCleanup[runtime] = nil
            try validate()
            if let i = transcript.messages.firstIndex(where: { $0.id == optimistic.id }) { transcript.messages[i].delivery = .confirmed }
        } catch {
            guard generation == selectionGeneration, connection == connectionGeneration, self.socket === socket else { throw CancellationError() }
            // A history refresh may already have confirmed this turn while its RPC
            // acknowledgement was delayed. Never downgrade that authoritative receipt.
            let delivery = transcript.submissionFailed(id: optimistic.id, error: error)
            if delivery == .confirmed { await persistNow(); return optimistic.id }
            if let refusal = error as? RPCFailure, refusal.sessionOwnedElsewhere {
                // Hermes rejects ownership before admitting or persisting this prompt.
                // Keep the draft, not a duplicate failed bubble in the transcript.
                transcript.messages.removeAll { $0.id == optimistic.id }
                transcript.running = false; transcript.activity = nil; transcript.failure = nil
                if consumeDraft {
                    attachmentDrafts[draftKey] = pending; draft = input
                    ownershipConflictContext = attachmentContext
                }
                await persistNow()
                throw RPCFailure(RPCFailure.ownershipMessage, code: refusal.code, reason: refusal.reason)
            }
            if delivery == .failed {
                if consumeDraft { attachmentDrafts[draftKey] = pending; draft = input }
                await persistNow()
                throw RPCFailure("Hermes a refusé ce message : \(error.localizedDescription)")
            }
            // Keep the last known execution state. Resume will resolve receipt and
            // running status from Hermes; never resubmit a prompt with an unknown outcome.
            await persistNow()
            if self.socket === socket {
                suspendConnection()
                if foreground { startReconnect() }
            }
            throw CancellationError()

        }
        for item in pending { await cache.removeAttachment(item.id) }
        await persistNow()
        return optimistic.id
    }

    func interrupt() async {
        guard let selected, let socket else { return }
        do { _ = try await socket.call("session.interrupt", ["session_id": .string(selected.runtimeID)]) }
        catch { chatError = error.localizedDescription }
    }

    private func syncServerRequests() {
        guard let socket, let session = selected?.runtimeID else { return }
        let inbox = socket.requests
        let approval = inbox.payload(session: session, methods: ["approval"])
        let clarification = inbox.payload(session: session, methods: ["clarify"])
        let credential = inbox.payload(session: session, methods: ["sudo", "secret", "vault.code", "vault.unlock_prompt"])
        if approval != nil || transcript.approval?["rpc_id"].isNull == false { transcript.approval = approval }
        if clarification != nil || transcript.clarification?["rpc_id"].isNull == false { transcript.clarification = clarification }
        if credential != nil || transcript.credential?["rpc_id"].isNull == false { transcript.credential = credential }
    }

    @discardableResult func answerApproval(_ choice: String, request: JSONValue) async -> Bool {
        guard let selected, let socket else { return false }
        guard request["choices"].array.contains(.string(choice)) else { return false }
        let generation = selectionGeneration
        do {
            if !request["rpc_id"].isNull { try await socket.answerRequest(request["rpc_id"].string, result: ["choice": .string(choice)]) }
            else {
                let result = try await socket.call("approval.respond", ["session_id": .string(selected.runtimeID), "request_id": request["request_id"], "choice": .string(choice)])
                guard result["resolved"].bool else { throw RPCFailure("Cette demande n’est plus active.") }
                if generation == selectionGeneration, transcript.approval?["request_id"] == request["request_id"] { transcript.approval = nil }
            }
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    @discardableResult func answerClarification(_ text: String, request: JSONValue, qid: String? = nil) async -> Bool {
        guard let socket else { return false }
        let generation = selectionGeneration
        do {
            if !request["rpc_id"].isNull {
                if let qid { try await socket.lockAnswer(request["rpc_id"].string, question: qid, answer: text) }
                else { try await socket.answerRequest(request["rpc_id"].string, result: ["answer": .string(text)]) }
            } else {
                var params: [String: JSONValue] = ["request_id": request["request_id"], "answer": .string(text)]
                if let qid { params["question_id"] = .string(qid) }
                let result = try await socket.call("clarify.respond", .object(params))
                if result["status"].string == "expired" || result["resolved"] == false { throw RPCFailure("Cette question a expiré.") }
                if qid == nil, generation == selectionGeneration, transcript.clarification?["request_id"] == request["request_id"] { transcript.clarification = nil }
            }
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    @discardableResult func answerCredential(_ value: String, request: JSONValue) async -> Bool {
        guard let socket else { return false }
        let generation = selectionGeneration
        do {
            if !request["rpc_id"].isNull { try await socket.answerRequest(request["rpc_id"].string, result: ["value": .string(value)]) }
            else {
                let sudo = request["event_type"].string == "sudo.request"
                _ = try await socket.call(sudo ? "sudo.respond" : "secret.respond", .object(["request_id": request["request_id"], sudo ? "password" : "value": .string(value)]))
                if generation == selectionGeneration, transcript.credential?["request_id"] == request["request_id"] { transcript.credential = nil }
            }
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    func loadRoutines() async {
        guard let socket else { return }
        let owner = selected?.profile ?? profile
        let generation = connectionGeneration
        do {
            let result = try await socket.call("cron.manage", ["action": "list", "profile": .string(owner), "include_disabled": true])
            guard generation == connectionGeneration, owner == (selected?.profile ?? profile) else { return }
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

    var visibleBots: [AgentProfile] {
        profiles.filter { $0.hidden != true || $0.name == profile }.sorted { ($0.pinned == true ? 0 : 1) < ($1.pinned == true ? 0 : 1) }
    }

    func editBotPresentation(name: String, title: String, pinned: Bool, hidden: Bool) async throws {
        guard let socket else { throw RPCFailure("Reconnectez Hermes.") }
        let roster = try await socket.call("profiles.list")
        guard let row = roster["profiles"].array.first(where: { $0["name"].string == name }) else { throw RPCFailure("Ce profil n’existe plus.") }
        var meta = row["ui_meta"]["hermes-bots"].object
        meta["title"] = .string(title); meta["pinned"] = .bool(pinned); meta["hidden"] = .bool(hidden)
        var params: [String: JSONValue] = ["name": .string(name), "ui_meta": ["hermes-bots": .object(meta)]]
        if !row["ui_meta_revisions"].isNull {
            params["ui_meta_expected_revisions"] = ["hermes-bots": .number(Double(row["ui_meta_revisions"]["hermes-bots"].int))]
        }
        let result = try await socket.call("profiles.configure", .object(params))
        guard result["applied"]["ui_meta"].bool else { throw RPCFailure("Le profil a changé ailleurs. Réessayez pour conserver ses dernières modifications.") }
        try await refreshProfiles()
    }

    func deleteBot(_ name: String) async throws {
        guard name != "default", let http, state == .connected else { throw RPCFailure("Le profil principal doit être conservé.") }
        let generation = connectionGeneration
        _ = try await http.request("/api/profiles/" + name, method: "DELETE")
        guard generation == connectionGeneration else { throw CancellationError() }
        if profile == name { await changeProfile("default") }
        workspace.chats = workspace.chats.filter { $0.value.profile != name }
        conversationActivity.remove(profile: name)
        botConversations[name] = nil
        historyIndex.update([], profile: name)
        try await refreshProfiles(); await persistNow()
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

    func speechSocket(connectionID: UUID?, profile expected: String) async throws -> URLSessionWebSocketTask {
        guard activeConnection?.id == connectionID, profile == expected, let http, state == .connected else { throw RPCFailure("Reconnectez cet agent pour parler.") }
        let generation = connectionGeneration
        let request = try await http.socketRequest(path: "/api/audio/speak-stream", query: [URLQueryItem(name: "profile", value: expected)])
        guard generation == connectionGeneration, profile == expected else { throw CancellationError() }
        return http.socketSession.webSocketTask(with: request)
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
            result = try await socket.call(path, .object(params), timeout: ["cli.exec", "skills.manage", "session.compress"].contains(path) ? 240 : 40)
        } else {
            var scopedBody = body?.object
            if scopedBody != nil { scopedBody?["profile"] = .string(expectedProfile) }
            result = try await http.request(path, method: method, body: scopedBody.map(JSONValue.object),
                query: query + [URLQueryItem(name: "profile", value: expectedProfile)])
        }
        try Task.checkCancellation()
        guard generation == connectionGeneration, profile == expectedProfile else { throw CancellationError() }
        try checkResult(result)
        return result
    }

    private func checkResult(_ result: JSONValue) throws {
        if result["ok"] == .bool(false) || result["success"] == .bool(false) || (!result["error"].isNull && result["error"] != false && result["error"] != "") {
            let reason = [result["error"].string, result["error"]["message"].string, result["reason"].string, result["message"].string].first { !$0.isEmpty }
            throw RPCFailure(reason ?? "Hermes n’a pas pu effectuer cette action.")
        }
    }

    private func receive(_ event: JSONValue) {
        let type = event["type"].string
        if type.hasSuffix(".changed") { scheduleListRefresh() }
        if buffering { held.held.append(event); return }
        guard event["session_id"].string == selected?.runtimeID else { return }
        if type == "message.delta", !event["payload"]["text"].string.isEmpty,
           transcript.messages.last?.streaming != true {
            // First visible token bypasses batching; later fragments stay capped at ~30 fps.
            flushStream(); transcript.apply(event); scheduleSave(); return
        }
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

    func isUnread(_ conversation: Conversation) -> Bool {
        conversationActivity.isUnread(profile: conversation.profile, id: conversation.id)
    }

    func hasUnread(profile: String) -> Bool { conversationActivity.hasUnread(profile: profile) }
    func lastVisited(profile: String) -> Date? { conversationActivity.lastVisited(profile: profile) }

    func markConversationRead(_ conversation: Conversation) {
        conversationActivity.markRead(profile: conversation.profile, id: conversation.id)
        scheduleSave()
    }

    func conversationStatus(_ conversation: Conversation) -> String? {
        if selected?.storedID == conversation.id, selected?.profile == conversation.profile {
            if transcript.approval != nil { return "Votre accord" }
            if transcript.clarification != nil || transcript.credential != nil { return "Votre réponse" }
            if transcript.running { return "En cours" }
        }
        return isUnread(conversation) ? "Non lue" : nil
    }

    func observeConversations(_ rows: [Conversation], establishesBaseline: Bool = true, baselineProfile: String? = nil) {
        conversationActivity.observe(rows, establishesBaseline: establishesBaseline, emptyProfile: baselineProfile)
        markCurrentConversationRead()
        scheduleSave()
    }

    func setChatVisible(_ visible: Bool) {
        chatVisible = visible
        if visible { markCurrentConversationRead() }
    }

    private func markCurrentConversationRead() {
        guard foreground, chatVisible, !opening, let selected,
              demo || (hydratedSelection == selectionGeneration && !selected.runtimeID.isEmpty && state == .connected) else { return }
        conversationActivity.markRead(profile: selected.profile, id: selected.storedID)
        scheduleSave()
    }

    private func key(_ profile: String, _ stored: String) -> String { "\(profile):\(stored)" }

    private func saveCurrent() {
        flushStream()
        workspace.imageCleanup = imageCleanup
        workspace.attachments = attachmentDrafts
        workspace.activity = conversationActivity
        workspace.botConversations = botConversations
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
        guard !demo, saveTask == nil else { return }
        let generation = connectionGeneration
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, generation == self.connectionGeneration, !Task.isCancelled else { return }
            await self.persistNow()
            if generation == self.connectionGeneration { self.saveTask = nil }
        }
    }

    private func persistNow() async {
        guard !demo, let activeConnection else { return }
        saveCurrent()
        workspace.profiles = profiles; workspace.sessions = sessions; workspace.historyIndex = historyIndex
        do { try await cache.save(workspace, key: activeConnection.id.uuidString) }
        catch { notice = "Le cache local n’a pas pu être enregistré. Votre historique reste chez Hermes." }
    }

    func removeConnection(_ connection: SavedConnection) async {
        let push = PushNotifications.shared
        if push.enabled.contains(connection.id) {
            await push.setEnabled(false, for: connection)
            guard !push.enabled.contains(connection.id) else {
                notice = "Reconnectez ce serveur pour y désactiver les notifications avant de retirer la connexion."
                return
            }
        }
        if activeConnection?.id == connection.id {
            saveTask?.cancel(); saveTask = nil; reconnectTask?.cancel(); reconnectTask = nil
            socket?.close(); http?.invalidate(); http = nil; socket = nil
            connectionGeneration = UUID(); selectionGeneration = UUID()
            activeConnection = nil; selected = nil; profiles = []; sessions = []; draft = ""
            transcript = Transcript(); workspace = CachedWorkspace(); historyIndex = ConversationIndex(); attachmentDrafts = [:]; state = .offline
            conversationActivity = ConversationActivity(); botConversations = [:]; chatError = nil; toast = nil
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
        sessions = []
        // Preview history uses the same rows and navigation as a connected profile.
        for agent in profiles {
            let examples = [
                ("demo-\(agent.name)", "Une journée plus légère", "Choisir l’essentiel et laisser un peu de place au reste.", 0),
                ("demo-\(agent.name)-idea", "Et si on lançait cette idée ?", "Les premières pistes pour transformer une intuition en projet.", 0),
                ("demo-\(agent.name)-week", "Préparer la semaine", "Trois priorités, quelques rendez-vous et du temps pour soi.", 1),
                ("demo-\(agent.name)-read", "Un peu de curiosité", "Lectures, inspirations et choses à explorer.", 4)
            ]
            for (index, item) in examples.enumerated() {
                let date = Calendar.current.date(byAdding: .day, value: -item.3, to: Date())!.addingTimeInterval(Double(-index * 1200))
                sessions.append(Conversation(["id": .string(item.0), "title": .string(item.1), "preview": .string(item.2), "last_active": .number(date.timeIntervalSince1970)], profile: agent.name))
                if index > 0 { workspace.chats[key(agent.name, item.0)] = ChatSnapshot(storedID: item.0, profile: agent.name, title: item.1, messages: [.init(role: "assistant", text: item.2)]) }
            }
        }
        for index in sessions.indices { sessions[index].messageCount = 2 }
        conversationActivity.observe(sessions)
        // A representative unread conversation uses the same local reading model as real history.
        for index in sessions.indices where sessions[index].id.hasSuffix("-idea") {
            sessions[index].messageCount = 3
            sessions[index].preview = "Une nouvelle piste à explorer ensemble."
        }
        conversationActivity.observe(sessions)
        conversationActivity.visit(profile: "default")
        if ProcessInfo.processInfo.arguments.contains("--demo-onboarding") { demo = false; connections = []; activeConnection = nil; selected = nil; profiles = []; state = .offline }
    }

    private func openDemoBot(_ bot: AgentProfile) {
        saveCurrent()
        let storedID = "demo-\(bot.name)"
        selected = workspace.chats[key(bot.name, storedID)] ?? ChatSnapshot(storedID: storedID, profile: bot.name, title: bot.title)
        profile = bot.name
        chatError = nil; conversationActivity.visit(profile: bot.name)
        conversationActivity.markRead(profile: bot.name, id: storedID)
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
