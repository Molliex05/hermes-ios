import SwiftUI
import Observation

private struct GroupCache: Codable, Sendable {
    var rooms: [JSONValue] = []
    var events: [String: [JSONValue]] = [:]
    var cursors: [String: Int] = [:]
    var drafts: [String: String] = [:]
    var pending: [String: JSONValue] = [:]
}

@MainActor @Observable
private final class GroupModel {
    let connectionID: UUID
    let app: AppModel
    var data = GroupCache()
    var supported = false
    var error: String?
    var busy = false
    var states: [String: JSONValue] = [:]
    @ObservationIgnored private let cache = LocalCache()
    init(app: AppModel, connectionID: UUID) { self.app = app; self.connectionID = connectionID }
    func boot() async {
        data = await cache.read(GroupCache.self, key: connectionID.uuidString + "-groups") ?? GroupCache()
        do {
            let capabilities = try await call("groups.capabilities")
            supported = capabilities["driver"].bool && capabilities["methods"].array.contains("groups.send")
            guard supported else { error = "Ce serveur n’expose pas encore les groupes natifs. Mettez Hermes à jour et relancez hermes serve."; return }
            try await refreshRooms()
            await refreshStates()
        } catch { self.error = error.localizedDescription }
    }
    /// What the list shows: which rooms are waiting for an answer.
    func refreshStates() async {
        for room in data.rooms.map({ $0["room_id"].string }) { states[room] = try? await call("groups.state", ["room_id": .string(room)]) }
    }
    func waiting(_ room: String) -> Bool {
        !(states[room]?["driver_status"]["pending_actions"].array ?? []).isEmpty
            || (data.events[room]?.last { $0["kind"].string == "message.member" }?["payload"]["text"].string.contains("@user") ?? false)
                && data.events[room]?.last?["kind"].string == "message.member"
    }
    func working(_ room: String) -> Bool { states[room]?["driver_status"]["working"].bool ?? false }
    func preview(_ room: String) -> String? {
        guard let event = data.events[room]?.last(where: { ["message.user", "message.member"].contains($0["kind"].string) }) else { return nil }
        return ChatCard.plainText(event["payload"]["text"].string)
    }
    func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        try await app.groupRequest(method, params: params, connectionID: connectionID)
    }
    func refreshRooms() async throws {
        var rows: [JSONValue] = []
        var offset = 0
        repeat {
            let result = try await call("groups.list", ["limit": 100, "offset": .number(Double(offset))])
            rows += result["rooms"].array
            if result["next_offset"].isNull { break }
            offset = result["next_offset"].int
        } while offset < 1000
        data.rooms = rows
        await save()
    }
    func create(name: String, members: [AgentProfile], id: String) async throws {
        _ = try await call("groups.create", ["room_id": .string(id), "name": .string(name), "members": .array(members.map {
            ["member_id": .string($0.name), "profile": .string($0.name), "handle": .string(GroupMention.handle(title: $0.title, fallback: $0.name)), "display_name": .string($0.title)]
        })])
        try await refreshRooms()
    }
    func refresh(_ room: String) async {
        do {
            states[room] = try await call("groups.state", ["room_id": .string(room)])
            var pages = 0
            var changed = false
            repeat {
                let result = try await call("groups.log", ["room_id": .string(room), "since_seq": .number(Double(data.cursors[room] ?? 0)), "limit": 100])
                var known = Set((data.events[room] ?? []).map { $0["event_id"].string })
                let incoming = result["events"].array.filter { known.insert($0["event_id"].string).inserted }
                data.events[room, default: []].append(contentsOf: incoming)
                if !incoming.isEmpty || data.cursors[room] != result["cursor"].int { changed = true }
                data.cursors[room] = result["cursor"].int
                pages += 1
                if !result["has_more"].bool { break }
            } while pages < 20
            // The room is polled every couple of seconds: write the cache only when something arrived.
            if changed { await save() }
        } catch { self.error = error.localizedDescription }
    }
    func send(_ room: String, text: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // Unlike prompt.submit, the official groups API has durable idempotent event IDs.
        let pending = data.pending[room] ?? ["room_id": .string(room), "event_id": .string(UUID().uuidString), "payload": ["text": .string(text), "thread_id": .string(UUID().uuidString)]]
        data.pending[room] = pending
        await save()
        do {
            _ = try await call("groups.send", pending)
            data.pending.removeValue(forKey: room)
            if data.drafts[room] == text { data.drafts[room] = "" }
            await refresh(room)
        } catch { self.error = "Envoi en attente. Réessayer utilise le même identifiant et ne crée pas de doublon. \(error.localizedDescription)" }
        await save()
    }
    func stop(_ room: String) async {
        do { _ = try await call("groups.stop", ["room_id": .string(room), "cancel_id": .string(UUID().uuidString)]) }
        catch { self.error = error.localizedDescription }
    }
    func action(_ method: String, room: String, params: JSONValue = [:]) async -> Bool {
        guard !busy else { return false }; busy = true; error = nil
        defer { busy = false }
        do {
            var body = params.object; body["room_id"] = .string(room)
            _ = try await call(method, .object(body))
            if method == "groups.disband" {
                data.events.removeValue(forKey: room); data.cursors.removeValue(forKey: room)
                data.drafts.removeValue(forKey: room); data.pending.removeValue(forKey: room); states.removeValue(forKey: room)
            } else { await refresh(room) }
            try await refreshRooms(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func save() async {
        guard app.connections.contains(where: { $0.id == connectionID }) else { return }
        do { try await cache.save(data, key: connectionID.uuidString + "-groups") }
        catch { self.error = "Le cache du groupe n’a pas pu être enregistré." }
    }
}

struct GroupsView: View {
    let app: AppModel
    let connectionID: UUID
    @State private var model: GroupModel?
    @State private var creating = false
    @State private var booting = true
    /// The group a notification asked for.
    @State private var requested: JSONValue?
    var body: some View {
        List {
            AppIntro("Plusieurs regards, une seule conversation. Hermes orchestre les agents sur votre serveur.")
            if booting && (model?.data.rooms.isEmpty ?? true) { SkeletonRows(count: 3) }
            if let model {
                ForEach(model.data.rooms, id: \.["room_id"].string) { room in
                    NavigationLink { GroupChatView(model: model, room: room) } label: {
                        HStack(spacing: 14) {
                            HStack(spacing: -10) {
                                ForEach(room["members"].array.prefix(3), id: \.["member_id"].string) { AgentAvatar(name: $0["profile"].string, size: 30) }
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(room["name"].string).lineLimit(1)
                                Text(model.preview(room["room_id"].string) ?? "\(room["members"].array.count) agents").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if model.waiting(room["room_id"].string) {
                                Text("Attend ta réponse").font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.accent)
                                    .padding(.horizontal, 8).padding(.vertical, 4).background(AppTheme.accent.opacity(0.12), in: Capsule())
                            }
                        }.padding(.vertical, 9)
                    }
                }
                if model.data.rooms.isEmpty && !booting {
                    ContentUnavailableView("Croiser les idées", systemImage: "person.2", description: Text("Invitez de deux à six agents de ce serveur dans un groupe."))
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(AppTheme.accent) }
            }
        }.modernList().navigationTitle("Groupes").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .primaryAction) { Button("Nouveau groupe", systemImage: "plus") { creating = true }.disabled(model?.supported != true) }
            }
            .task { if model == nil { let m = GroupModel(app: app, connectionID: connectionID); model = m; await m.boot() }; booting = false; openRequested() }
            .onChange(of: app.roomRequest) { _, _ in openRequested() }
            .navigationDestination(isPresented: Binding(get: { requested != nil }, set: { if !$0 { requested = nil } })) {
                if let model, let requested { GroupChatView(model: model, room: requested) }
            }
            .sheet(isPresented: $creating) { if let model { GroupEditor(model: model) } }
    }
}

private extension GroupsView {
    func openRequested() {
        guard !booting, let room = app.roomRequest else { return }
        app.roomRequest = nil
        requested = model?.data.rooms.first { $0["room_id"].string == room }
    }
}

private struct GroupEditor: View {
    let model: GroupModel
    @State private var name = ""
    @State private var members = Set<String>()
    @State private var busy = false
    @State private var error: String?
    @State private var roomID = UUID().uuidString
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom du groupe", text: $name)
                Section("De 2 à 6 agents") {
                    ForEach(model.app.visibleBots) { agent in
                        Toggle(agent.title, isOn: Binding(get: { members.contains(agent.name) }, set: { enabled in
                            if enabled { members.insert(agent.name) } else { members.remove(agent.name) }
                        }))
                    }
                }
                if let error { Text(error).foregroundStyle(AppTheme.accent) }
            }.modernList().navigationTitle("Nouveau groupe").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    AppToolbarItem(placement: .confirmationAction) {
                        Button("Créer") {
                            busy = true
                            Task {
                                do { try await model.create(name: name, members: model.app.visibleBots.filter { members.contains($0.name) }, id: roomID); dismiss() }
                                catch { self.error = error.localizedDescription }
                                busy = false
                            }
                        }.disabled(busy || name.isEmpty || !(2...6).contains(members.count))
                    }
                }
        }.presentationBackground(AppTheme.background)
    }
}

private struct GroupChatView: View {
    @Bindable var model: GroupModel
    let room: JSONValue
    @Environment(\.scenePhase) private var phase
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var title = ""
    @State private var disbanding = false
    @State private var retry: JSONValue?
    private var currentRoom: JSONValue { model.states[id]?["room"] ?? room }
    private var id: String { room["room_id"].string }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 25) {
                Text(room["members"].array.map { $0["display_name"].string.isEmpty ? $0["profile"].string : $0["display_name"].string }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                ForEach(model.data.events[id] ?? [], id: \.["event_id"].string) { event in
                    if ["message.user", "message.member"].contains(event["kind"].string) {
                        let member = room["members"].array.first { $0["member_id"] == event["actor"]["id"] }
                        MessageView(message: .init(id: event["event_id"].string, role: event["kind"].string == "message.user" ? "user" : "assistant", text: event["payload"]["text"].string), agent: member?["display_name"].string ?? event["actor"]["id"].string)
                            .environment(\.agentLook, AgentLooks.shared.look(for: [member?["profile"].string, event["actor"]["id"].string].compactMap { $0 }.first { !$0.isEmpty } ?? ""))
                    } else if event["kind"].string == "room.status" {
                        Text(event["payload"]["status"].string).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array((model.states[id]?["driver_status"]["pending_actions"].array ?? []).enumerated()), id: \.offset) { _, action in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(action["member_id"].string.isEmpty ? "Une action attend votre réponse" : action["member_id"].string).font(.subheadline.weight(.medium))
                        if action["kind"].string == "approval" {
                            Text(action["approval"]["description"].string.isEmpty ? action["approval"]["command"].string : action["approval"]["description"].string).font(.subheadline).textSelection(.enabled)
                            HStack {
                                Button("Refuser") { approve(action, choice: "deny") }.buttonStyle(AppBorderedButtonStyle())
                                Spacer()
                                Button("Pour cette session") { approve(action, choice: "session") }.buttonStyle(AppBorderedButtonStyle())
                                Button("Une fois") { approve(action, choice: "once") }.buttonStyle(AppProminentButtonStyle())
                            }
                        } else if action["kind"].string == "retry" {
                            Button("Réessayer cette tâche") { retry = action }
                        } else { Text("Cette demande nécessite une autre interface Hermes.").font(.caption).foregroundStyle(.secondary) }
                    }.hermesCard().disabled(model.busy)
                }
                if model.working(id) {
                    Label("Les agents répondent…", systemImage: "ellipsis.bubble").font(.caption.weight(.medium)).foregroundStyle(AppTheme.accent)
                        .accessibilityIdentifier("group-working")
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(AppTheme.accent) }
            }.padding(.horizontal, 16).padding(.vertical, 20)
        }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.interactively).background(AppTheme.background).appNavigationBar()
            .navigationTitle(currentRoom["name"].string).navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .primaryAction) {
                AppMenu {
                    AppMenuButton("Arrêter les agents", systemImage: "stop.circle") { Task { await model.stop(id) } }
                    AppMenuButton("Renommer", systemImage: "pencil") { title = currentRoom["name"].string; renaming = true }
                    AppMenuButton("Dissoudre le groupe", systemImage: "trash", role: .destructive) { disbanding = true }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.disabled(model.busy)
            } }
            .appAlert("Renommer le groupe", isPresented: $renaming) {
                TextField("Nom", text: $title)
                Button("Enregistrer") { Task { _ = await model.action("groups.rename", room: id, params: ["name": .string(title), "event_id": .string(UUID().uuidString)]) } }
                Button("Annuler", role: .cancel) { }
            }
            .appConfirm("Dissoudre ce groupe définitivement ?", isPresented: $disbanding) {
                Button("Dissoudre", role: .destructive) { Task { if await model.action("groups.disband", room: id, params: ["cancel_id": .string(UUID().uuidString)]) { dismiss() } } }
            } message: { Text("Hermes arrêtera les agents et fermera ce groupe pour tous ses membres.") }
            .appConfirm("Réessayer cette tâche ?", isPresented: Binding(get: { retry != nil }, set: { if !$0 { retry = nil } })) {
                Button("Réessayer") { guard let action = retry else { return }; retry = nil; Task { _ = await model.action("groups.retry", room: id, params: ["task_id": action["task_id"], "member_id": action["member_id"], "execution_generation": action["execution_generation"]]) } }
            } message: { Text("Le résultat de l’exécution précédente est incertain. Une nouvelle tentative peut répéter ses actions.") }
            .safeAreaInset(edge: .bottom) { composer }
            .environment(\.chatReply, ChatReplyAction { text in
                guard !model.busy else { return false }
                Task { await model.send(id, text: text) }
                return true
            })
            .task(id: phase) {
                guard phase == .active else { await model.save(); return }
                // Native hosted rooms expose cursor-based logs, not per-token WS notifications.
                // Pull deltas only while this room is visible; cached rows never disappear.
                while !Task.isCancelled {
                    await model.refresh(id)
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .onAppear { model.app.openRoomID = id }
            .onDisappear { model.app.openRoomID = nil; Task { await model.save() } }
    }
    private var draft: String { model.data.drafts[id] ?? "" }
    private var members: [JSONValue] { currentRoom["members"].array }
    /// Who the « @ » being typed can name: the room's agents, then everyone.
    private var mentions: [(handle: String, title: String, profile: String?)] {
        guard let query = GroupMention.query(in: draft)?.lowercased() else { return [] }
        let agents = members.map { (handle: $0["handle"].string, title: $0["display_name"].string, profile: Optional($0["profile"].string)) }
        return (agents + [(handle: "all", title: "Tout le monde", profile: nil)]).filter { query.isEmpty || $0.handle.lowercased().hasPrefix(query) }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !mentions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mentions, id: \.handle) { mention in
                            Button {
                                Haptics.select(); model.data.drafts[id] = GroupMention.completed(draft, handle: mention.handle)
                            } label: {
                                HStack(spacing: 7) {
                                    if let profile = mention.profile { AgentAvatar(name: profile, size: 24) } else { Image(systemName: "person.2.fill").font(.caption) }
                                    Text(mention.title).font(.caption)
                                }.padding(8).background(AppTheme.surface, in: Capsule())
                            }.buttonStyle(.plain).accessibilityIdentifier("group-mention-\(mention.handle)")
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("Écris au groupe, ou @ pour appeler un agent", text: Binding(get: { draft }, set: { model.data.drafts[id] = $0 }), axis: .vertical)
                    .lineLimit(1...5).padding(.leading, 14).padding(.vertical, 12)
                sendButton
            }
            .padding(2).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(AppTheme.line))
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(AppTheme.background)
    }
    private var sendButton: some View {
        let working = model.working(id), canSend = !draft.isEmpty || model.data.pending[id] != nil
        return Button {
            if working, !canSend { Task { await model.stop(id) } }
            else { Haptics.send(); Task { await model.send(id, text: draft) } }
        } label: {
            Image(systemName: working && !canSend ? "stop.fill" : model.data.pending[id] == nil ? "arrow.up" : "arrow.clockwise")
                .font(.system(size: working && !canSend ? 13 : 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(canSend || working ? AppTheme.accent : Color.secondary.opacity(0.28), in: Circle())
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.busy || (!canSend && !working))
            .accessibilityLabel(working && !canSend ? "Arrêter les agents" : "Envoyer")
            .accessibilityIdentifier("group-send")
    }
    private func approve(_ action: JSONValue, choice: String) {
        let requestID = action["approval"]["request_id"].isNull ? action["request_id"] : action["approval"]["request_id"]
        Task { _ = await model.action("groups.approve", room: id, params: ["member_id": action["member_id"], "task_id": action["task_id"], "execution_generation": action["execution_generation"], "request_id": requestID, "choice": .string(choice)]) }
    }

}
