import Foundation
import Network
import Observation
@preconcurrency import UserNotifications
import WidgetKit

struct CachedWorkspace: Codable, Sendable {
    var profiles: [AgentProfile] = []
    var sessions: [Conversation] = []
    var historyIndex: ConversationIndex?
    /// Loaded chats only. Each chat lives in its own file (`LocalCache.chatKey`), written when it changes.
    var chats: [String: ChatSnapshot] = [:]
    /// Every cached chat key with its last use; the oldest beyond `chatLimit` are pruned.
    var chatIndex: [String: Date] = [:]
    var drafts: [String: String] = [:]
    var selected: String?
    var attachments: [String: [DraftAttachment]]?
    var imageCleanup: [String: [String]]?
    var activity: ConversationActivity?
    var botConversations: [String: Conversation]?
    /// True when an older single-file cache carried its chats inline: they are rewritten as chat files.
    var migratedChats = false
    static let chatLimit = 30

    private enum CodingKeys: String, CodingKey {
        case profiles, sessions, historyIndex, chats, chatIndex, drafts, selected, attachments, imageCleanup, activity, botConversations
    }
    init() {}
    // Display cache: a field that no longer decodes costs that field, never the whole workspace.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = (try? c.decodeIfPresent([AgentProfile].self, forKey: .profiles)) ?? []
        sessions = (try? c.decodeIfPresent([Conversation].self, forKey: .sessions)) ?? []
        historyIndex = try? c.decodeIfPresent(ConversationIndex.self, forKey: .historyIndex)
        chats = (try? c.decodeIfPresent([String: ChatSnapshot].self, forKey: .chats)) ?? [:]
        chatIndex = (try? c.decodeIfPresent([String: Date].self, forKey: .chatIndex)) ?? [:]
        drafts = (try? c.decodeIfPresent([String: String].self, forKey: .drafts)) ?? [:]
        selected = try? c.decodeIfPresent(String.self, forKey: .selected)
        attachments = try? c.decodeIfPresent([String: [DraftAttachment]].self, forKey: .attachments)
        imageCleanup = try? c.decodeIfPresent([String: [String]].self, forKey: .imageCleanup)
        activity = try? c.decodeIfPresent(ConversationActivity.self, forKey: .activity)
        botConversations = try? c.decodeIfPresent([String: Conversation].self, forKey: .botConversations)
        if !chats.isEmpty {
            migratedChats = true
            for key in chats.keys where chatIndex[key] == nil { chatIndex[key] = .distantPast }
        }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profiles, forKey: .profiles); try c.encode(sessions, forKey: .sessions)
        try c.encodeIfPresent(historyIndex, forKey: .historyIndex); try c.encode(chatIndex, forKey: .chatIndex)
        try c.encode(drafts, forKey: .drafts); try c.encodeIfPresent(selected, forKey: .selected)
        try c.encodeIfPresent(attachments, forKey: .attachments); try c.encodeIfPresent(imageCleanup, forKey: .imageCleanup)
        try c.encodeIfPresent(activity, forKey: .activity); try c.encodeIfPresent(botConversations, forKey: .botConversations)
    }
}

@MainActor @Observable
final class AppModel {
    enum ConnectionState { case offline, connecting, connected, signInRequired }
    var connections: [SavedConnection] = []
    var activeConnection: SavedConnection?
    var state: ConnectionState = .offline {
        didSet {
            if state == .connected, oldValue != .connected { presence.reset() }
            refreshPresence()
        }
    }
    var profiles: [AgentProfile] = []
    var botConversations: [String: Conversation] = [:]
    var sessions: [Conversation] = []
    var historyRevision = 0
    @ObservationIgnored private let historyRequests = HistoryRequests()
    @ObservationIgnored private var historyIndex = ConversationIndex()
    var profile = "default" {
        didSet { if !demo, oldValue != profile { sessions = historyIndex[profile]; routines = [] } }
    }
    var selected: ChatSnapshot? {
        didSet {
            guard oldValue?.storedID != selected?.storedID || oldValue?.profile != selected?.profile else { return }
            refreshPresence()
        }
    }
    var transcript = Transcript() {
        // No `oldValue`: copying the transcript on every streamed token would be costly.
        didSet {
            let running = transcript.running
            if running != lastTurnRunning { lastTurnRunning = running; turnRunningChanged(running) }
        }
    }
    @ObservationIgnored private var lastTurnRunning = false
    var draft = ""
    var attachmentDrafts: [String: [DraftAttachment]] = [:]
    var attachments: [DraftAttachment] { attachmentDrafts[draftKey] ?? [] }
    /// A voice call keeps running like a phone call: screen locked or app in the background,
    /// the socket and audio stay up (UIBackgroundModes `audio`) until the call ends.
    var voiceActive = false {
        didSet {
            if oldValue && !voiceActive && !foreground && !sending { suspendConnection() }
            refreshPresence()
            if voiceActive != oldValue { voiceActive ? startCallActivity() : LiveActivities.shared.endCall() }
        }
    }
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
    /// Changes when the chat should put the cursor in the composer (a notification opened the conversation).
    var composerFocusRequest = UUID()
    var demo = false
    var hasBooted = false
    /// True until the saved connections are read: no onboarding flash on a cold start.
    var booting = true
    var notificationRoutingReady = false
    var hasBotProtocol = false
    var draftKey: String { selected.map { key($0.profile, $0.storedID) } ?? "draft-\(profile)" }
    var agent: AgentProfile? { profiles.first { $0.name == (selected?.profile ?? profile) } }
    var canSend: Bool { (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) && !importingAttachments && !voiceActive && (state == .connected || demo) && !opening && !sending && !transcript.running && (selected == nil || !(selected?.runtimeID.isEmpty ?? true) || demo) }

    /// Push channel for spoken replies, fed straight from the socket (before UI batching).
    /// Only events of the selected runtime are delivered; the voice session owns the subscription.
    enum SpeechEvent: Sendable {
        case delta(runtime: String, text: String)
        /// The turn ended: `text` is Hermes' final answer, `status` its native completion status.
        case complete(runtime: String, text: String, status: String)
    }
    @ObservationIgnored var speechSink: ((SpeechEvent) -> Void)?

    /// Display warm-start only (each tool reloads from Hermes); bounded so it can't grow per screen visited.
    @ObservationIgnored var toolCache: [String: JSONValue] = [:] {
        didSet { if toolCache.count > 60 { toolCache = [:] } }
    }
    @ObservationIgnored private let cache = LocalCache()
    @ObservationIgnored private var dirtyChats = Set<String>()
    @ObservationIgnored private var chatFingerprints: [String: Int] = [:]
    @ObservationIgnored private var saveAgain = false
    @ObservationIgnored private var heldOverflow = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathSignature: String?
    @ObservationIgnored private var reconnectWaiting = false
    /// Methods whose contract has no `profile` param: the dispatcher rejects unknown keys (4000).
    private static let profilelessMethods: Set<String> = [
        "browser.controller.detach", "browser.controller.heartbeat", "browser.controller.register", "browser.controller.result",
        "client.capabilities", "diagnostics.share_nous", "gateway.capabilities", "image.generate", "learning.delete",
        "learning.detail", "learning.edit", "learning.frames", "model.disconnect", "model.save_key",
        "onboarding.ensure_setup_profile", "onboarding.ensure_setup_session", "onboarding.mark_seen",
        "onboarding.record_failed_start", "onboarding.reset_setup_profile", "onboarding.state", "paste.collapse", "ping",
        "plugins.list", "reload.env", "reload.mcp", "tools.list", "tools.show", "toolsets.list"
    ]
    @ObservationIgnored private var http: HermesHTTP?
    @ObservationIgnored private var socket: HermesSocket?
    @ObservationIgnored private var workspace = CachedWorkspace()
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var suspendTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var held = ReplayBuffer()
    @ObservationIgnored private var buffering = false
    @ObservationIgnored private var streamEvents: [JSONValue] = []
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private var hydratedSelection: UUID?
    @ObservationIgnored private var connectionGeneration = UUID()
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private lazy var presence = PresenceBeacon(client: { [weak self] in self?.http },
                                                                    installationID: { PushNotifications.shared.installationID })
    // MARK: Live Activities

    private func startCallActivity() {
        guard !demo else { return }
        LiveActivities.shared.endReply(quiet: true)
        LiveActivities.shared.startCall(title: agent?.title ?? "Hermès", profile: selected?.profile ?? profile, phase: "listening", muted: false)
    }

    /// A reply in progress gets a Lock Screen/Dynamic Island activity only when the user leaves the app: while the app
    /// is in front it would be noise, and starting an activity costs a call on the main thread plus two requests.
    /// ActivityKit only starts one while the app is still in front, so this runs when the scene goes inactive.
    func appBecameInactive() {
        guard !demo, transcript.running, !voiceActive, state == .connected else { return }
        LiveActivities.shared.register = { [weak self] token, id, started in await self?.registerActivity(token: token, id: id, started: started) }
        LiveActivities.shared.unregister = { [weak self] id in await self?.unregisterActivity(id: id) }
        LiveActivities.shared.startReply(title: agent?.title ?? "Hermès", profile: selected?.profile ?? profile)
    }

    private func turnRunningChanged(_ running: Bool) {
        guard !demo else { return }
        if !running {
            LiveActivities.shared.finishReply(foreground: foreground)
            if foreground, !voiceActive, transcript.failure == nil { Haptics.done() }
        }
    }

    private func registerActivity(token: String, id: String, started: Double) async {
        guard !demo, let http, let connection = activeConnection, let selected, PushNotifications.shared.enabled.contains(connection.id) else { return }
        let body: JSONValue = .object(["installation_id": .string(PushNotifications.shared.installationID), "connection_id": .string(connection.id.uuidString),
                                       "profile": .string(selected.profile), "session_id": .string(selected.storedID), "activity_id": .string(id),
                                       "token": .string(token), "environment": .string(PushNotifications.apnsEnvironment), "kind": .string("reply"),
                                       "started_at": .number(started)])
        _ = try? await http.request("/api/plugins/hermes-ios-push/activities", method: "PUT", body: body)
    }

    private func unregisterActivity(id: String) async {
        guard !demo, let http else { return }
        _ = try? await http.request("/api/plugins/hermes-ios-push/activities/\(PushNotifications.shared.installationID)/\(id)", method: "DELETE")
    }

    /// Set by `hermesios://voice` (widget); the chat opens the voice sheet, also after a cold launch.
    var pendingVoiceLaunch = false
    @ObservationIgnored private var widgetRefreshedAt = Date.distantPast
    @ObservationIgnored private var widgetUnavailable = false

    /// `hermesios://voice` opens a call; any other widget link just opens the app.
    func handle(url: URL) {
        guard url.scheme == "hermesios" else { return }
        if url.host == "voice" { pendingVoiceLaunch = true }
    }

    /// Saves the Noriven snapshot for the widgets and asks WidgetKit to redraw. Best effort and quiet:
    /// a server without the plugin (404) or without access is remembered until the next connection.
    func refreshWidgets(retryUnavailable: Bool = false) async {
        if retryUnavailable { widgetUnavailable = false }      // a new connection retries a plugin installed meanwhile
        guard !demo, !widgetUnavailable, let http, Date.now.timeIntervalSince(widgetRefreshedAt) > 15 * 60 else { return }
        widgetRefreshedAt = .now
        if await WidgetRefresh.run(using: http) == .unavailable { widgetUnavailable = true }
    }

    /// The connection is wanted while the app is visible or a voice call is running.
    private var connectionWanted: Bool { foreground || voiceActive }

    func boot() async {
        guard !hasBooted else { return }
        hasBooted = true
        defer { notificationRoutingReady = true; booting = false }
        PushNotifications.shared.suppressesPresentation = { [weak self] envelope in self?.suppressesBanner(for: envelope) ?? false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { loadDemo(); return }
        #endif
        startPathMonitor()
        LiveActivities.shared.endOrphans()
        ActivityActions.handler = { [weak self] action in
            switch action {
            case .toggleMute: VoiceCallRemote.current?.toggleMicrophone()
            case .endCall: VoiceCallRemote.current?.pause()
            case .stopReply: Task { [weak self] in await self?.interrupt() }
            }
        }
        connections = await cache.read([SavedConnection].self, key: "connections") ?? []
        booting = false
        if let first = connections.first { await activate(first) }
    }

    /// Wi-Fi/cellular switches and returning coverage reconnect at once instead of waiting
    /// for the heartbeat (up to ~60 s) or the exponential backoff.
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            let signature = path.availableInterfaces.map { "\($0.type)-\($0.name)" }.joined(separator: ",")
            Task { @MainActor [weak self] in self?.networkChanged(usable: usable, signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "org.hermesios.path", qos: .utility))
        pathMonitor = monitor
    }

    private func networkChanged(usable: Bool, signature: String) {
        let previous = pathSignature
        pathSignature = usable ? signature : nil
        guard usable, connectionWanted, !demo, http != nil, state != .signInRequired else { return }
        if state == .connected {
            // Same network, or a change while a send awaits its receipt: leave the channel alone.
            guard let previous, previous != signature, !sending, let socket else { return }
            Task { [weak self] in
                guard await !socket.probe(), let self, self.socket === socket else { return }
                socket.close(); self.disconnected(RPCFailure("Le réseau a changé.", code: -1))
            }
        } else if (previous == nil || previous != signature) && (reconnectTask == nil || reconnectWaiting) {
            // A usable path appeared: retry now rather than sleeping out the backoff.
            reconnectTask?.cancel(); reconnectTask = nil; reconnectWaiting = false
            socket?.close()
            startReconnect()
        }
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
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
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
        guard !Task.isCancelled else { return }
        if let reply = PushNotifications.shared.takeReply(for: target) { await sendNotificationReply(reply, target: target) }
        else { composerFocusRequest = UUID() }         // ready to write: the keyboard opens on the conversation
        PushNotifications.shared.opened(target)
    }

    /// The text typed on a notification's « Répondre » field goes to the conversation it came from, once that
    /// conversation is open and idle. If it cannot be sent (agent still answering, connection down) it is left in the
    /// composer, never lost and never sent to another conversation.
    private func sendNotificationReply(_ text: String, target: NotificationTarget) async {
        let previous = draft
        for _ in 0..<40 {
            if selected?.storedID == target.sessionID, state == .connected, !opening, !sending, !transcript.running { break }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
        }
        draft = text
        if selected?.storedID == target.sessionID, canSend {
            await send()
            // Consumed: the reader's own draft comes back. Refused: the reply stays in front of them.
            draft = draft.isEmpty ? previous : (previous.isEmpty ? draft : previous + "\n" + draft)
        } else {
            draft = previous.isEmpty ? text : previous + "\n" + text
            notice = "Votre réponse est prête dans le champ : touchez Envoyer."
            composerFocusRequest = UUID()
        }
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
        toolCache = [:]; dirtyChats = []; chatFingerprints = [:]
        connectionGeneration = UUID(); selectionGeneration = UUID()
        let generation = connectionGeneration
        activeConnection = connection; demo = false; state = .connecting; routines = []
        let ordered = [connection] + connections.filter { $0.id != connection.id }
        if ordered != connections { connections = ordered; try? await cache.save(connections, key: "connections") }
        guard generation == connectionGeneration else { return }
        opening = false; sending = false; buffering = false; held = ReplayBuffer(); streamEvents = []
        let restored = await cache.read(CachedWorkspace.self, key: connection.id.uuidString) ?? CachedWorkspace()
        guard generation == connectionGeneration else { return }
        workspace = restored
        if restored.migratedChats { dirtyChats = Set(restored.chats.keys) }
        conversationActivity = restored.activity ?? ConversationActivity()
        chatError = nil; toast = nil
        attachmentDrafts = restored.attachments ?? [:]
        imageCleanup = restored.imageCleanup ?? [:]
        profiles = workspace.profiles
        botConversations = workspace.botConversations ?? [:]
        historyIndex = workspace.historyIndex ?? ConversationIndex(legacy: workspace.sessions)
        let restoredChat = await loadChat(workspace.selected)
        guard generation == connectionGeneration else { return }
        selected = restoredChat
        profile = selected?.profile ?? profiles.first?.name ?? "default"
        sessions = historyIndex[profile]
        transcript = Transcript(messages: selected?.messages ?? [], lastSequence: selected?.lastSequence ?? 0)
        draft = workspace.drafts[draftKey] ?? ""
        conversationActivity.visit(profile: profile)
        http = HermesHTTP(connection)
        startReconnect()
    }

    private func startReconnect() {
        guard connectionWanted, !demo, http != nil, reconnectTask == nil else { return }
        let generation = connectionGeneration
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while let self, !Task.isCancelled, generation == self.connectionGeneration, self.connectionWanted {
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
                    self.reconnectWaiting = true
                    defer { self.reconnectWaiting = false }
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
        refreshPresence()
        if active {
            clearDeliveredForSelected()
            if state != .connected, !sending { startReconnect() }
            suspendTask?.cancel(); suspendTask = nil
            LiveActivities.shared.endReply(quiet: true)
        } else {
            let lease = BackgroundLease(name: "Save Hermès conversation")
            defer { lease.end() }
            await persistNow()
            // Keep the channel until an in-flight submission is acknowledged, and for a voice call. Otherwise a short
            // grace period: leaving the app for a few seconds must not cost a full reconnect on return.
            if !sending && !voiceActive {
                let hold = BackgroundLease(name: "Hermès socket grace")
                suspendTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    if let self, !Task.isCancelled, !self.foreground, !self.sending, !self.voiceActive { self.suspendConnection() }
                    hold.end()
                }
            }
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
        let cached = await loadChat(bot.canonicalID.map { key(bot.name, $0) })
        guard !opening, !sending, !voiceActive else { return }
        saveCurrent()
        opening = true
        let generation = UUID(); selectionGeneration = generation
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
        let cached = demo ? workspace.chats[key(conversation.profile, conversation.id)] : await loadChat(key(conversation.profile, conversation.id))
        guard !sending, !voiceActive else { return }
        saveCurrent()
        let generation = UUID(); selectionGeneration = generation
        selected = cached ?? ChatSnapshot(storedID: conversation.id, profile: conversation.profile, title: title ?? conversation.title)
        if let title { selected?.title = title }
        profile = conversation.profile
        chatError = nil; conversationActivity.visit(profile: conversation.profile)
        transcript = Transcript(messages: selected?.messages ?? [], lastSequence: selected?.lastSequence ?? 0)
        draft = workspace.drafts[draftKey] ?? ""
        opening = true
        defer { if generation == selectionGeneration { opening = false; markCurrentConversationRead(); clearDeliveredForSelected() } }
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
        buffering = true; held = ReplayBuffer(); heldOverflow = false
        defer { if generation == selectionGeneration { buffering = false } }
        // The selected chat's transcript carries the authoritative replay watermark.
        let sequence = transcript.lastSequence
        let canReplay = !chat.runtimeID.isEmpty && chat.epoch == socket.epoch && sequence > 0 && !transcript.messages.contains(where: { $0.delivery != .confirmed })
        let response = try await socket.call("session.resume", ["close_on_disconnect": false, "profile": .string(chat.profile), "session_id": .string(chat.storedID), "omit_messages": .bool(canReplay)])
        try validate()
        let runtime = response["session_id"].string
        guard !runtime.isEmpty else { throw RPCFailure("Hermes n’a pas retourné de session active.") }
        selected?.runtimeID = runtime
        let stored = response["session_key"].string.isEmpty ? response["stored_session_id"].string : response["session_key"].string
        if !stored.isEmpty { selected?.storedID = stored }
        selected?.epoch = socket.epoch
        let replay = try await socket.call("session.events.since", ["session_id": .string(runtime), "last_seen": .number(Double(canReplay && runtime == chat.runtimeID ? sequence : 0))], timeout: 40)
        try validate()
        if canReplay && runtime == chat.runtimeID && !replay["truncated"].bool && !heldOverflow && replay["epoch"].string == socket.epoch {
            let events = held.drain(replayed: replay["events"].array, after: transcript.lastSequence, session: runtime)
            for event in events { transcript.apply(event) }
            // Queue copy only; a live approval arrives as a server request (syncServerRequests).
            if !response["pending_approval"].isNull, transcript.approval?["rpc_id"].isNull != false { transcript.approval = response["pending_approval"] }
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
        if demo { let text = draft; draft = ""; await demoReply(text); return }
        do { _ = try await submit(draft.trimmingCharacters(in: .whitespacesAndNewlines), consumeDraft: true) }
        catch is CancellationError { }
        catch {
            if (error as? RPCFailure)?.sessionOwnedElsewhere == true || error.localizedDescription == RPCFailure.ownershipMessage { notice = error.localizedDescription }
            else { chatError = error.localizedDescription }
        }
    }

    /// Whether a card's quick reply can go now: Hermès connected and free, no voice call.
    var canSendQuickReply: Bool {
        !importingAttachments && !voiceActive && (state == .connected || demo) && !opening && !sending && !transcript.running
            && (selected == nil || !(selected?.runtimeID.isEmpty ?? true) || demo)
    }

    /// A quick reply from a card, sent as its own message: the typed draft and its attachments stay where they are, and
    /// the text is never read as a slash command.
    func sendQuickReply(_ text: String) async {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, canSendQuickReply else { return }
        chatError = nil
        if demo { await demoReply(reply); return }
        do { _ = try await submit(reply, consumeDraft: false) }
        catch is CancellationError { }
        catch {
            if (error as? RPCFailure)?.sessionOwnedElsewhere == true || error.localizedDescription == RPCFailure.ownershipMessage { notice = error.localizedDescription }
            else { chatError = error.localizedDescription }
        }
    }

    /// A spoken turn never consumes the user's typed draft or its attachments.
    /// Chained voice turns pass `voiceTurn` (Hermes' fast `auxiliary.voice_chat` route);
    /// `interrupted` marks a turn that follows a barge-in over the previous reply.
    func sendVoice(_ text: String, liveContext: String? = nil, voiceTurn: Bool = false, interrupted: Bool = false) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCFailure("Aucune parole détectée.") }
        return try await submit(text, consumeDraft: false, liveContext: liveContext, voiceTurn: voiceTurn, interrupted: interrupted)
    }

    private func submit(_ input: String, consumeDraft: Bool, liveContext: String? = nil, voiceTurn: Bool = false, interrupted: Bool = false) async throws -> String {
        guard !sending, !opening, !transcript.running, state == .connected, let socket else { throw RPCFailure("Attendez que Hermes soit prêt avant de parler ou d’envoyer un message.") }
        let originalDraftKey = draftKey
        let generation = selectionGeneration
        let connection = connectionGeneration
        let pending = consumeDraft ? attachments : []
        var text = input
        if text.isEmpty { text = pending.allSatisfy(\.isImage) ? "Que vois-tu dans ces images ?" : "Examine ces fichiers." }
        sending = true
        let lease = BackgroundLease(name: "Send message to Hermès") { [weak self] in
            guard let self, connection == self.connectionGeneration, !self.connectionWanted else { return }
            // Expiration is a transport interruption, never an automatic resend/agent stop.
            self.suspendConnection()
        }
        defer {
            lease.end()
            if connection == connectionGeneration {
                sending = false
                if !connectionWanted { suspendConnection() }
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
                    let mime = item.mimeType
                    let dataURL = await Task.detached(priority: .userInitiated) { "data:\(mime);base64,\(data.base64EncodedString())" }.value
                    try validate()
                    let result = try await socket.call("file.attach", ["session_id": .string(runtime), "name": .string(item.name), "data_url": .string(dataURL)], timeout: 90)
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
            _ = try await socket.call("prompt.submit", VoiceLiveProtocol.prompt(runtime: runtime, text: prompt, context: liveContext, voiceTurn: voiceTurn, interrupted: interrupted))
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
                if connectionWanted { startReconnect() }
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

    func interruptVoice(connectionID: UUID?, profile expected: String, runtimeID: String) async throws {
        guard activeConnection?.id == connectionID, profile == expected,
              selected?.runtimeID == runtimeID, state == .connected, let socket else { throw CancellationError() }
        _ = try await socket.call("session.interrupt", ["session_id": .string(runtimeID)], timeout: 10)
        try Task.checkCancellation()
        guard activeConnection?.id == connectionID, profile == expected, selected?.runtimeID == runtimeID else { throw CancellationError() }
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
                // Queue entry restored from `session.resume`: `resolved` is the number of entries settled.
                let result = try await socket.call("approval.respond", ["session_id": .string(selected.runtimeID), "request_id": request["request_id"], "choice": .string(choice)])
                guard result["resolved"].int > 0 || result["resolved"].bool else {
                    if generation == selectionGeneration, transcript.approval?["request_id"] == request["request_id"] { transcript.approval = nil }
                    throw RPCFailure("Cette demande n’est plus active.")
                }
                if generation == selectionGeneration, transcript.approval?["request_id"] == request["request_id"] { transcript.approval = nil }
            }
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    @discardableResult func answerClarification(_ text: String, request: JSONValue, qid: String? = nil) async -> Bool {
        if demo { return true }                     // the preview has no server to lock answers with
        guard let socket else { return false }
        let generation = selectionGeneration
        do {
            // Clarify is a server→client request only; every answer is locked per question id.
            guard !request["rpc_id"].isNull, let question = qid ?? request["questions"].array.first?["qid"].string, !question.isEmpty else {
                if generation == selectionGeneration { transcript.clarification = nil }
                throw RPCFailure("Cette question a expiré.")
            }
            try await socket.lockAnswer(request["rpc_id"].string, question: question, answer: text)
            return true
        } catch { notice = error.localizedDescription; return false }
    }

    /// Cancels a clarification the way the desktop does: an empty answer set settles the request.
    @discardableResult func dismissClarification(request: JSONValue) async -> Bool {
        guard let socket, !request["rpc_id"].isNull else { transcript.clarification = nil; return false }
        do { try await socket.answerRequest(request["rpc_id"].string, result: ["answers": [:]]); return true }
        catch { notice = error.localizedDescription; return false }
    }

    @discardableResult func answerCredential(_ value: String, request: JSONValue) async -> Bool {
        guard let socket else { return false }
        let generation = selectionGeneration
        do {
            guard !request["rpc_id"].isNull else {
                if generation == selectionGeneration { transcript.credential = nil }
                throw RPCFailure("Cette demande a expiré.")
            }
            try await socket.answerRequest(request["rpc_id"].string, result: ["value": .string(value)])
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
        for chatKey in workspace.chatIndex.keys where chatKey.hasPrefix(name + ":") { workspace.chatIndex[chatKey] = nil }
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
        try await audioSocket("/api/audio/speak-stream", connectionID: connectionID, profile: expected)
    }

    /// An authenticated, profile-scoped audio WebSocket (`speak-stream`, `transcribe-stream`).
    func audioSocket(_ path: String, connectionID: UUID?, profile expected: String) async throws -> URLSessionWebSocketTask {
        guard activeConnection?.id == connectionID, profile == expected, let http, state == .connected else { throw RPCFailure("Reconnectez cet agent pour parler.") }
        let generation = connectionGeneration
        let request = try await http.socketRequest(path: path, query: [URLQueryItem(name: "profile", value: expected)])
        guard generation == connectionGeneration, profile == expected else { throw CancellationError() }
        return http.socketSession.webSocketTask(with: request)
    }

    /// Each tool stays pinned to the server and profile that opened it.
    func toolRequest(_ path: String, method: String = "GET", body: JSONValue? = nil,
                     query: [URLQueryItem] = [], connectionID: UUID?, profile expectedProfile: String,
                     rpc: Bool = false, pinned: Bool = false) async throws -> JSONValue {
        guard activeConnection?.id == connectionID, pinned || profile == expectedProfile,
              let http, state == .connected else { throw RPCFailure("Reconnectez cet agent pour accéder à ses outils.") }
        let generation = connectionGeneration
        let result: JSONValue
        if rpc {
            guard let socket else { throw RPCFailure("Hermes est déconnecté.") }
            var params = body?.object ?? [:]
            if !Self.profilelessMethods.contains(path) { params["profile"] = .string(expectedProfile) }
            result = try await socket.call(path, .object(params), timeout: ["cli.exec", "skills.manage", "session.compress", "profiles.create", "plugins.manage"].contains(path) ? 240 : 40)
        } else {
            var scopedBody = body?.object
            if scopedBody != nil { scopedBody?["profile"] = .string(expectedProfile) }
            result = try await http.request(path, method: method, body: scopedBody.map(JSONValue.object),
                query: query + [URLQueryItem(name: "profile", value: expectedProfile)])
        }
        try Task.checkCancellation()
        guard generation == connectionGeneration, pinned || profile == expectedProfile else { throw CancellationError() }
        try checkResult(result)
        return result
    }

    private func checkResult(_ result: JSONValue) throws {
        // A native confirmation prompt (expensive model, consent) is an answer for the screen, not a failure.
        if result["confirm_required"].bool || result["consent_required"].bool { return }
        if result["ok"] == .bool(false) || result["success"] == .bool(false) || (!result["error"].isNull && result["error"] != false && result["error"] != "") {
            let reason = [result["error"].string, result["error"]["message"].string, result["reason"].string, result["message"].string].first { !$0.isEmpty }
            throw RPCFailure(reason ?? "Hermes n’a pas pu effectuer cette action.")
        }
    }

    private func receive(_ event: JSONValue) {
        let type = event["type"].string
        switch type {
        case "sessions.changed": scheduleListRefresh()
        case "cron.changed": if !routines.isEmpty { Task { [weak self] in await self?.loadRoutines() } }
        default: break
        }
        if buffering {
            // Bounded: an overflow forces a full snapshot recovery instead of an exact replay.
            if held.held.count < 5_000 { held.held.append(event) } else { heldOverflow = true }
            return
        }
        if type == "session.reclaimed", let chat = selected, !chat.runtimeID.isEmpty,
           [event["session_id"].string, event["payload"]["session_id"].string].contains(chat.runtimeID) {
            reattachSelected(); return
        }
        guard let runtime = selected?.runtimeID, event["session_id"].string == runtime else { return }
        if let speechSink {
            switch type {
            case "message.delta" where !event["payload"]["text"].string.isEmpty:
                speechSink(.delta(runtime: runtime, text: event["payload"]["text"].string))
            case "message.complete":
                speechSink(.complete(runtime: runtime, text: event["payload"]["text"].string, status: event["payload"]["status"].string))
            case "error":
                speechSink(.complete(runtime: runtime, text: "", status: "error"))
            default: break
            }
        }
        if type == "message.delta", !event["payload"]["text"].string.isEmpty,
           transcript.messages.last?.streaming != true {
            // First visible token bypasses batching; later fragments stay capped at ~30 fps.
            flushStream(); transcript.apply(event); scheduleSave(delay: Self.streamingSaveDelay); return
        }
        if type == "message.delta" || type == "reasoning.delta" || type == "thinking.delta" {
            streamEvents.append(event)
            if streamTask == nil {
                streamTask = Task { [weak self] in
                    // Cancelled only by flushStream, which has already delivered the batch.
                    do { try await Task.sleep(for: .milliseconds(33)) } catch { return }
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

    /// Hermes reclaimed the live runtime (idle reaper, owner restart): bind the chat again.
    private func reattachSelected() {
        guard let chat = selected, state == .connected else { return }
        selected?.runtimeID = ""; hydratedSelection = nil
        let generation = selectionGeneration
        Task { [weak self] in
            do { try await self?.attach(chat, generation: generation) }
            catch is CancellationError { }
            catch { if let self, generation == self.selectionGeneration { self.notice = error.localizedDescription } }
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
        if !events.isEmpty { scheduleSave(delay: Self.streamingSaveDelay) }
    }

    private static let streamingSaveDelay = Duration.seconds(8)

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
        refreshPresence()
        if visible { markCurrentConversationRead(); clearDeliveredForSelected() }
    }

    /// An automatic alert is redundant while its conversation is on screen or a voice call is running.
    private func suppressesBanner(for envelope: NotificationEnvelope) -> Bool {
        if voiceActive { return true }
        guard foreground, chatVisible, let connection = activeConnection, let selected, let session = envelope.sessionID else { return false }
        return envelope.connectionID == connection.id && envelope.profile == selected.profile && session == selected.storedID
    }

    private func clearDeliveredForSelected() {
        guard !demo, foreground, chatVisible, let connection = activeConnection, let selected else { return }
        PushNotifications.shared.clearDelivered(connection: connection.id, profile: selected.profile, session: selected.storedID)
    }

    /// Presence follows the conversation on screen, or the voice call (which also runs in the background).
    private func refreshPresence() {
        var target: PresenceBeacon.Target?
        if !demo, let connection = activeConnection, let selected, http != nil, state == .connected,
           PushNotifications.shared.enabled.contains(connection.id), voiceActive || (foreground && chatVisible) {
            target = .init(connectionID: connection.id, profile: selected.profile, sessionID: selected.storedID)
        }
        presence.update(target)
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
        // `selected` is not reassigned here: that would invalidate every view reading it twice a second.
        if let chat = selected, !chat.storedID.isEmpty {
            let chatKey = key(chat.profile, chat.storedID)
            var hasher = Hasher()
            hasher.combine(transcript.lastSequence); hasher.combine(transcript.messages.count)
            hasher.combine(chat.runtimeID); hasher.combine(chat.title); hasher.combine(chat.epoch)
            for message in transcript.messages.suffix(3) { hasher.combine(message.id); hasher.combine(message.text.count); hasher.combine(message.delivery) }
            let fingerprint = hasher.finalize()
            if chatFingerprints[chatKey] != fingerprint || workspace.chats[chatKey] == nil {
                var stored = chat
                stored.messages = Array(transcript.messages.suffix(500))
                stored.lastSequence = transcript.lastSequence
                workspace.chats[chatKey] = stored
                chatFingerprints[chatKey] = fingerprint
                dirtyChats.insert(chatKey)
            }
            workspace.chatIndex[chatKey] = Date()
        }
        workspace.selected = selected.flatMap { $0.storedID.isEmpty ? nil : key($0.profile, $0.storedID) }
    }

    /// The chat stays in memory once loaded; otherwise it is read from its own cache file.
    private func loadChat(_ chatKey: String?) async -> ChatSnapshot? {
        guard let chatKey else { return nil }
        if let chat = workspace.chats[chatKey] { return chat }
        guard !demo, let connection = activeConnection, workspace.chatIndex[chatKey] != nil else { return nil }
        let generation = connectionGeneration
        let chat = await cache.read(ChatSnapshot.self, key: LocalCache.chatKey(connection: connection.id.uuidString, chat: chatKey))
        guard generation == connectionGeneration else { return nil }
        if let chat, workspace.chats[chatKey] == nil { workspace.chats[chatKey] = chat }
        return workspace.chats[chatKey]
    }

    /// `delay` is how long changes are gathered before the write. Streamed text uses a long one: the reply is
    /// recoverable from the server (`events.since`), and rewriting the chat file every second drains the battery.
    private func scheduleSave(delay: Duration = .milliseconds(700)) {
        guard !demo else { return }
        // A change made while a write is in flight gets its own save once that write finishes.
        if saveTask != nil { saveAgain = true; return }
        let generation = connectionGeneration
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, generation == self.connectionGeneration, !Task.isCancelled else { return }
            self.saveAgain = false
            await self.persistNow()
            guard generation == self.connectionGeneration else { return }
            self.saveTask = nil
            if self.saveAgain { self.saveAgain = false; self.scheduleSave() }
        }
    }

    private func persistNow() async {
        guard !demo, let activeConnection else { return }
        let connection = activeConnection.id.uuidString
        saveCurrent()
        workspace.profiles = profiles; workspace.sessions = sessions; workspace.historyIndex = historyIndex
        // Keep the most recently used chats (and always the open one); forget the rest.
        let current = workspace.selected
        let pruned = workspace.chatIndex.sorted { $0.value > $1.value }.dropFirst(CachedWorkspace.chatLimit).map(\.key).filter { $0 != current }
        for chatKey in pruned {
            workspace.chatIndex[chatKey] = nil; workspace.chats[chatKey] = nil
            chatFingerprints[chatKey] = nil; dirtyChats.remove(chatKey)
        }
        let changed = dirtyChats.compactMap { chatKey in workspace.chats[chatKey].map { (chatKey, $0) } }
        dirtyChats.removeAll()
        do {
            try await cache.save(workspace, key: connection)
            for (chatKey, chat) in changed { try await cache.save(chat, key: LocalCache.chatKey(connection: connection, chat: chatKey)) }
            for chatKey in pruned { try? await cache.remove(LocalCache.chatKey(connection: connection, chat: chatKey)) }
            workspace.migratedChats = false
        } catch {
            dirtyChats.formUnion(changed.map(\.0))
            notice = "Le cache local n’a pas pu être enregistré. Votre historique reste chez Hermes."
        }
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
        NotificationKeyStore.remove(for: connection.id)
        connections.removeAll { $0.id == connection.id }
        await cache.removeChats(connection: connection.id.uuidString)
        do { try await cache.remove(connection.id.uuidString); try await cache.remove(connection.id.uuidString + "-groups"); try await cache.save(connections, key: "connections") }
        catch { notice = error.localizedDescription }
    }

    #if DEBUG
    /// A run of about 8 km around Saint-Constant, as `[lat,lon]` pairs for the demo route card.
    private static var demoLoop: String {
        (0..<48).map { step -> String in
            let angle = Double(step) / 47 * 2 * .pi
            return String(format: "[%.5f,%.5f]", 45.3706 + 0.0105 * sin(angle) + 0.0012 * sin(angle * 3),
                          -73.5653 + 0.016 * (1 - cos(angle)) + 0.0015 * sin(angle * 2))
        }.joined(separator: ",")
    }
    #endif

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
        #if DEBUG
        // Every kind of rich card, to look at them (and for the UI tests).
        if ProcessInfo.processInfo.arguments.contains("--demo-calendar") { Task { await CalendarLink.seedDemoEvent() } }
        // The agent asks a few questions, one at a time (`choices` with `questions`).
        if ProcessInfo.processInfo.arguments.contains("--demo-questions") {
            let fence = "```"
            transcript.messages = [
                .init(role: "user", text: "Aide-moi à chercher une maison."),
                .init(role: "assistant", text: """
                Avec plaisir. Trois questions pour bien cibler :

                \(fence)ui
                {"type":"choices","questions":[
                {"prompt":"Quel budget maximum ?","options":[{"label":"450 000 $","detail":"Maisons à rafraîchir, terrains plus petits","icon":"dollarsign.circle"},{"label":"500 000 $","detail":"Le gros de l’offre à Saint-Constant","icon":"house"},{"label":"550 000 $","detail":"Plus récent, garage double","icon":"sparkles"}]},
                {"prompt":"Quels secteurs ?","multiple":true,"options":["Saint-Constant","Delson","Candiac","La Prairie"]},
                {"prompt":"Le plus important ?","options":[{"label":"Un grand terrain","icon":"leaf"},{"label":"Un garage","icon":"car"},{"label":"Près de l’autoroute 30","icon":"road.lanes"}]}]}
                \(fence)
                """)
            ]
        }
        // Hermes' own clarification request (its `clarify` tool), several questions.
        if ProcessInfo.processInfo.arguments.contains("--demo-clarify") {
            transcript.clarification = .object([
                "rpc_id": "demo", "request_id": "demo-clarify",
                "questions": .array([
                    .object(["qid": "q1", "question": "Pour le souper de vendredi, je réserve où ?", "choices": .array(["Chez Julie", "Au restaurant", "On reste à la maison"])]),
                    .object(["qid": "q2", "question": "Pour combien de personnes ?", "choices": .array(["2", "4", "6"])])
                ])
            ])
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-cards") {
            let fence = "```"
            transcript.messages = [
                .init(role: "user", text: "Trouve-moi des maisons à Saint-Constant sous 500 000 $"),
                .init(role: "assistant", text: """
                J’ai trouvé quatre maisons qui collent à ton budget. La deuxième a le plus grand terrain.

                \(fence)ui
                {"type":"carousel","title":"Maisons à vendre · Saint-Constant","items":[
                {"title":"Cottage rénové, 3 chambres","subtitle":"Rue des Érables · garage double","price":"479 000 $","image":"https://picsum.photos/seed/maison-erables/600/400","url":"https://www.apple.com","badges":["3 ch.","2 sdb","Garage"]},
                {"title":"Plain-pied avec grand terrain","subtitle":"Montée Saint-Régis · 9 800 pi²","price":"449 900 $","image":"https://picsum.photos/seed/maison-terrain/600/400","url":"https://www.apple.com","badges":["3 ch.","1 sdb"]},
                {"title":"Jumelé récent","subtitle":"Secteur Le Petit-Village","price":"499 000 $","image":"https://picsum.photos/seed/maison-jumele/600/400","url":"https://www.apple.com","badges":["4 ch.","2 sdb"],"rating":4.6},
                {"title":"Bungalow à rafraîchir","subtitle":"Près de la gare · idéal premier achat","price":"399 000 $","image":"https://picsum.photos/seed/maison-bungalow/600/400","url":"https://www.apple.com","badges":["2 ch.","1 sdb"]}]}
                \(fence)

                \(fence)ui
                {"type":"choices","options":["Planifie des visites","Seulement avec garage","Élargis à Candiac"]}
                \(fence)
                """),
                .init(role: "user", text: "Un bon barbier près de chez moi ?"),
                .init(role: "assistant", text: """
                Trois barbiers bien notés à moins de 10 minutes :

                \(fence)ui
                {"type":"places","title":"Barbiers près de Saint-Constant","items":[
                {"name":"Barbier du Village","address":"Rue Saint-Pierre, Saint-Constant","lat":45.3706,"lon":-73.5653,"note":"Sans rendez-vous le samedi","phone":"450 555 0101"},
                {"name":"Studio Coupe Delson","address":"Boulevard Georges-Gagné, Delson","lat":45.3727,"lon":-73.5466,"note":"Ouvert jusqu’à 20 h"},
                {"name":"La Lame Candiac","address":"Chemin Saint-François-Xavier, Candiac","lat":45.3836,"lon":-73.5199,"note":"Réservation en ligne"}]}
                \(fence)
                """),
                .init(role: "user", text: "Il fera quoi cette semaine ?"),
                .init(role: "assistant", text: """
                Frais et assez ensoleillé, avec de la pluie jeudi.

                \(fence)ui
                {"type":"weather","place":"Saint-Constant","now":{"temp":7,"condition":"Partiellement nuageux","feels":4},"days":[
                {"day":"Mer","high":9,"low":2,"condition":"Soleil"},{"day":"Jeu","high":8,"low":4,"condition":"Pluie"},
                {"day":"Ven","high":11,"low":3,"condition":"Nuageux"},{"day":"Sam","high":13,"low":5,"condition":"Ensoleillé"}]}
                \(fence)
                """),
                .init(role: "user", text: "Où en est Noriven ce mois-ci ?"),
                .init(role: "assistant", text: """
                Un bon mois : le revenu monte et les dépenses restent stables.

                \(fence)ui
                {"type":"metrics","title":"Noriven · octobre","items":[{"label":"Revenu","value":"12 400 $","delta":"+8 %"},{"label":"Dépenses","value":"4 150 $","delta":"+1 %","trend":"flat"},{"label":"Profit","value":"8 250 $","delta":"+12 %"},{"label":"MRR","value":"3 900 $","delta":"-2 %"}]}
                \(fence)
                """),
                .init(role: "assistant", text: """
                Résumé du jour : quart de jour jusqu’à 15 h, barbier à 17 h, ciel gris et 7°. Hier, protéines un peu basses.

                \(fence)ui
                {"type":"brief","greeting":"Bonjour Maxime","date":"Jeudi 29 octobre","weather":{"temp":7,"condition":"Nuageux","high":9,"low":2},
                "sections":[{"kind":"agenda","title":"Aujourd’hui","items":[{"time":"06:45","text":"Quart de jour","detail":"jusqu’à 15 h"},{"time":"17:00","text":"Barbier du Village"},{"time":"18:30","text":"Souper chez Julie"}]},
                {"kind":"training","items":[{"text":"Pull · dos et biceps","detail":"45 min"}]},
                {"kind":"nutrition","text":"Hier : 2 150 kcal sur 2 400 et 128 g de protéines sur 160. Vise un dîner riche en protéines."},
                {"kind":"email","items":[{"text":"Facture AWS d’octobre","detail":"84,20 $","reply":"Montre-moi la facture AWS"},{"text":"2 courriels classés dans Infolettres"}]},
                {"kind":"news","items":[{"titre":"Pont Mercier, Jacques-Cartier : nos ponts arrivent-ils en fin de vie?","source":"Le Reflet","url":"https://www.lereflet.qc.ca/","il_y_a":"il y a 4 h"},
                {"titre":"iPhone Duo could capture nearly 30% of foldable market in 2027","source":"9to5Mac","url":"https://9to5mac.com/","image":"https://picsum.photos/seed/iphone-duo/300/300","il_y_a":"il y a 45 min"}]}],
                "focus":"Une seule chose : 20 minutes de mobilité après le quart."}
                \(fence)
                """),
                .init(role: "user", text: "Quoi de neuf dans les nouvelles ?"),
                .init(role: "assistant", text: """
                Trois titres ce soir, dont un près de chez toi.

                \(fence)ui
                {"type":"news","title":"À la une","items":[
                {"titre":"Pont Mercier, Jacques-Cartier : nos ponts arrivent-ils en fin de vie?","source":"Le Reflet","url":"https://www.lereflet.qc.ca/","image":"https://picsum.photos/seed/pont-mercier/800/450","il_y_a":"il y a 4 h"},
                {"titre":"Ottawa instaure de nouvelles amendes visant les conseils frauduleux","source":"Le Devoir","url":"https://www.ledevoir.com/","il_y_a":"il y a 49 min"},
                {"titre":"iPhone Duo could capture nearly 30% of foldable market in 2027","source":"9to5Mac","url":"https://9to5mac.com/","image":"https://picsum.photos/seed/iphone-duo/300/300","il_y_a":"il y a 45 min"}]}
                \(fence)
                """),
                .init(role: "user", text: "Et le MRR de Glutax sur six mois ?"),
                .init(role: "assistant", text: """
                Il monte depuis mai ; l’objectif de 4 000 $ est en vue.

                \(fence)ui
                {"type":"chart","title":"MRR Glutax","unit":"$","value":"3 900 $","delta":"+22 %","goal":4000,"points":[{"label":"mai","value":3200},{"label":"juin","value":3350},{"label":"juil.","value":3300},{"label":"août","value":3550},{"label":"sept.","value":3720},{"label":"oct.","value":3900}]}
                \(fence)
                """),
                .init(role: "user", text: "État du VPS ?"),
                .init(role: "assistant", text: """
                Tout tourne normalement. Seul le contrôle des sauvegardes ne répond pas : il cherche encore sur Google Drive.

                \(fence)ui
                {"type":"status","title":"noriven-prod","subtitle":"En ligne depuis 7 j 22 h · 14 conteneurs","gauges":[{"label":"CPU","value":9,"unit":"%"},{"label":"Mémoire","value":2.1,"max":7.8,"unit":"Go"},{"label":"Disque","value":27.6,"max":115,"unit":"Go"}],
                "items":[{"name":"Noriven","state":"ok","detail":"4 services"},{"name":"Glutax","state":"ok","detail":"3 services"},{"name":"Minori","state":"ok","detail":"2 services"},{"name":"Authentification","state":"ok","detail":"3 services"},{"name":"Sauvegardes","state":"unknown","detail":"Contrôle absent"}]}
                \(fence)
                """),
                .init(role: "user", text: "Mes dépenses d’octobre ?"),
                .init(role: "assistant", text: """
                Six dépenses ce mois-ci, surtout l’hébergement.

                \(fence)ui
                {"type":"list","title":"Dépenses · octobre","items":[
                {"title":"AWS","subtitle":"Hébergement · 12 oct.","value":"84,20 $","icon":"server.rack","tone":"negative","reply":"Détaille la facture AWS"},
                {"title":"Hetzner","subtitle":"Serveur de prod · 1 oct.","value":"62,00 $","icon":"cpu","tone":"negative"},
                {"title":"Apple Developer","subtitle":"Abonnement annuel","value":"129,00 $","icon":"apple.logo","badge":"Annuel","tone":"warning"},
                {"title":"Figma","subtitle":"Design · 5 oct.","value":"20,00 $","icon":"paintpalette","tone":"negative"},
                {"title":"Google Workspace","subtitle":"Courriels · 3 oct.","value":"8,40 $","icon":"envelope","tone":"negative"},
                {"title":"Remboursement Stripe","subtitle":"Frais corrigés","value":"+12,00 $","icon":"arrow.uturn.backward","tone":"positive"},
                {"title":"Domaine noriven.com","subtitle":"Renouvellement","value":"24,99 $","icon":"globe","tone":"negative"}],
                "total":{"label":"Total du mois","value":"316,59 $"}}
                \(fence)
                """),
                .init(role: "user", text: "Il me reste combien pour aujourd’hui ?"),
                .init(role: "assistant", text: """
                Il te reste 550 kcal et 40 g de protéines : un souper riche en protéines ferait la job.

                \(fence)ui
                {"type":"progress","title":"Aujourd’hui","items":[{"label":"Calories","value":1850,"goal":2400,"unit":"kcal"},{"label":"Protéines","value":120,"goal":160,"unit":"g"},{"label":"Glucides","value":190,"goal":260,"unit":"g"}]}
                \(fence)
                """),
                .init(role: "user", text: "C’est quoi ma journée demain ?"),
                .init(role: "assistant", text: """
                Quart de jour, puis le barbier et un souper. Tu as une pause libre en fin de journée.

                \(fence)ui
                {"type":"agenda","title":"Jeudi 29 octobre","items":[
                {"title":"Quart de jour","start":"2026-10-29T06:45","end":"2026-10-29T15:00","calendar":"Travail","location":"Poste de quartier"},
                {"title":"Barbier du Village","start":"2026-10-29T17:00","end":"2026-10-29T17:45","calendar":"Personnel","location":"Rue Saint-Pierre"},
                {"title":"Souper chez Julie","start":"2026-10-29T18:30","end":"2026-10-29T21:00","calendar":"Famille"}]}
                \(fence)
                """),
                .init(role: "user", text: "Ma séance d’hier ?"),
                .init(role: "assistant", text: """
                Belle séance : record au développé couché.

                \(fence)ui
                {"type":"workout","title":"Push · pectoraux","subtitle":"Mardi · 52 min","stats":[{"label":"Volume","value":"8 450 kg"},{"label":"Séries","value":"18"},{"label":"Durée","value":"52 min"}],
                "exercises":[{"name":"Développé couché","sets":"4 × 8","weight":"82,5 kg","done":true,"note":"Record"},{"name":"Développé incliné haltères","sets":"3 × 10","weight":"30 kg","done":true},{"name":"Dips lestés","sets":"3 × 8","weight":"+10 kg","done":true},{"name":"Écarté à la poulie","sets":"3 × 12","weight":"15 kg","done":false}]}
                \(fence)
                """),
                .init(role: "user", text: "Et ma course de ce matin ?"),
                .init(role: "assistant", text: """
                8,2 km à 5:02 du kilomètre, ton meilleur temps sur ce parcours.

                \(fence)ui
                {"type":"route","title":"Course du matin","stats":[{"label":"Distance","value":"8,2 km"},{"label":"Allure","value":"5:02 /km"},{"label":"Durée","value":"41:20"}],"points":[\(Self.demoLoop)]}
                \(fence)

                \(fence)ui
                {"type":"chart","title":"Kilomètres par semaine","style":"bar","unit":"km","delta":"+14 %","points":[{"label":"S38","value":18},{"label":"S39","value":22},{"label":"S40","value":15},{"label":"S41","value":24},{"label":"S42","value":21},{"label":"S43","value":26}]}
                \(fence)
                """),
                .init(role: "user", text: "Ajoute le barbier jeudi à 17 h"),
                .init(role: "assistant", text: """
                C’est noté dans ton agenda Personnel, sans conflit avec ton quart.

                \(fence)ui
                {"type":"event","title":"Barbier du Village","start":"2026-10-29T17:00","end":"2026-10-29T17:45","location":"Rue Saint-Pierre, Saint-Constant","calendar":"Personnel"}
                \(fence)
                """),
                .init(role: "user", text: "Et l’annonce d’Apple ?"),
                .init(role: "assistant", text: """
                Tout est ici : https://www.apple.com/newsroom/

                \(fence)ui
                {"type":"choices","options":["Résume-la","Autre chose"]}
                \(fence)
                """),
                .init(role: "user", text: "Merci"),
                // The last reply holds a card and a link preview: it must stay reachable (VoiceOver, UI tests).
                .init(role: "assistant", text: """
                Avec plaisir. Le résumé complet est ici : https://www.apple.com/newsroom/

                \(fence)ui
                {"type":"choices","options":["Bonne soirée","Un dernier truc"]}
                \(fence)
                """)
            ]
        }
        #endif
        #if DEBUG
        // A long history of rows with very different heights (headings, lists, code), like a real conversation.
        if ProcessInfo.processInfo.arguments.contains("--demo-long-history") {
            var many: [ChatMessage] = []
            for index in 0..<120 {
                many.append(.init(role: "user", text: String(repeating: "Question \(index) ", count: 1 + index % 5)))
                let body = (0..<(1 + index % 6)).map { part in
                    "Paragraphe \(part) de la réponse \(index). " + String(repeating: "Un peu de texte pour varier la hauteur. ", count: 1 + (part + index) % 4)
                }.joined(separator: "\n\n")
                let list = index % 3 == 0 ? "\n\n- point un\n- point deux\n- point trois" : ""
                let code = index % 4 == 0 ? "\n\n```\nlet valeur = \(index)\nprint(valeur)\n```" : ""
                many.append(.init(role: "assistant", text: "## Réponse \(index)\n\n" + body + list + code))
            }
            transcript.messages = many
        }
        #endif
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

    private func demoReply(_ text: String) async {
        #if DEBUG
        // Emulates the network round trip before a real message shows up (session creation, persistence).
        if ProcessInfo.processInfo.arguments.contains("--demo-slow-send") { try? await Task.sleep(for: .milliseconds(220)) }
        #endif
        transcript.messages.append(.init(role: "user", text: text))
        transcript.running = true
        #if DEBUG
        // Keeps the reply running long enough to look at the header's working state.
        if ProcessInfo.processInfo.arguments.contains("--demo-long-reply") { try? await Task.sleep(for: .seconds(12)) }
        #endif
        for word in "Ceci est un aperçu d’Hermès iOS. Connectez votre agent Hermes pour retrouver vos conversations, vos profils et vos outils.".split(separator: " ") {
            try? await Task.sleep(for: .milliseconds(60))
            transcript.apply(["type": "message.delta", "payload": ["text": .string(String(word) + " ")]])
        }
        if let i = transcript.messages.indices.last { transcript.messages[i].streaming = false }
        transcript.running = false
    }
}
