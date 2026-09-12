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
    @ObservationIgnored private let cache = LocalCache()
    init(app: AppModel, connectionID: UUID) { self.app = app; self.connectionID = connectionID }
    func boot() async {
        data = await cache.read(GroupCache.self, key: connectionID.uuidString + "-groups") ?? GroupCache()
        do {
            let capabilities = try await call("groups.capabilities")
            supported = capabilities["driver"].bool && capabilities["methods"].array.contains("groups.send")
            guard supported else { error = "Ce serveur n’expose pas encore les groupes natifs. Mettez Hermes à jour et relancez hermes serve."; return }
            try await refreshRooms()
        } catch { self.error = error.localizedDescription }
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
            ["member_id": .string($0.name), "profile": .string($0.name), "handle": .string($0.name), "display_name": .string($0.title)]
        })])
        try await refreshRooms()
    }
    func refresh(_ room: String) async {
        do {
            var pages = 0
            repeat {
                let result = try await call("groups.log", ["room_id": .string(room), "since_seq": .number(Double(data.cursors[room] ?? 0)), "limit": 100])
                var known = Set((data.events[room] ?? []).map { $0["event_id"].string })
                let incoming = result["events"].array.filter { known.insert($0["event_id"].string).inserted }
                data.events[room, default: []].append(contentsOf: incoming)
                data.cursors[room] = result["cursor"].int
                pages += 1
                if !result["has_more"].bool { break }
            } while pages < 20
            await save()
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
            data.pending.removeValue(forKey: room); data.drafts[room] = ""
            await refresh(room)
        } catch { self.error = "Envoi en attente. Réessayer utilise le même identifiant et ne crée pas de doublon. \(error.localizedDescription)" }
        await save()
    }
    func stop(_ room: String) async {
        do { _ = try await call("groups.stop", ["room_id": .string(room), "cancel_id": .string(UUID().uuidString)]) }
        catch { self.error = error.localizedDescription }
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
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Plusieurs regards, une seule conversation. Hermes orchestre les agents sur votre serveur.").font(.subheadline).foregroundStyle(.secondary)
                }
                if let model {
                    ForEach(model.data.rooms, id: \.["room_id"].string) { room in
                        NavigationLink { GroupChatView(model: model, room: room) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "person.2.bubble").foregroundStyle(IrisTheme.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(room["name"].string)
                                    Text("\(room["members"].array.count) agents").font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 9)
                        }
                    }
                    if model.data.rooms.isEmpty {
                        ContentUnavailableView("Croiser les idées", systemImage: "person.2", description: Text("Invitez de deux à six agents de ce serveur dans un groupe."))
                    }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(IrisTheme.accent) }
                }
            }.scrollContentBackground(.hidden).background(IrisTheme.background).navigationTitle("Ensemble")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { creating = true } label: { Image(systemName: "plus") }.disabled(model?.supported != true) }
                }
                .task { if model == nil { let m = GroupModel(app: app, connectionID: connectionID); model = m; await m.boot() } }
                .sheet(isPresented: $creating) { if let model { GroupEditor(model: model) } }
        }
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
                    ForEach(model.app.profiles) { agent in
                        Toggle(agent.title, isOn: Binding(get: { members.contains(agent.name) }, set: { enabled in
                            if enabled { members.insert(agent.name) } else { members.remove(agent.name) }
                        }))
                    }
                }
                if let error { Text(error).foregroundStyle(IrisTheme.accent) }
            }.navigationTitle("Nouveau groupe").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Créer") {
                            busy = true
                            Task {
                                do { try await model.create(name: name, members: model.app.profiles.filter { members.contains($0.name) }, id: roomID); dismiss() }
                                catch { self.error = error.localizedDescription }
                                busy = false
                            }
                        }.disabled(busy || name.isEmpty || !(2...6).contains(members.count))
                    }
                }
        }
    }
}

private struct GroupChatView: View {
    @Bindable var model: GroupModel
    let room: JSONValue
    @Environment(\.scenePhase) private var phase
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
                    } else if event["kind"].string == "room.status" {
                        Text(event["payload"]["status"].string).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.error { Text(error).font(.caption).foregroundStyle(IrisTheme.accent) }
            }.padding(24)
        }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.interactively).background(IrisTheme.background)
            .navigationTitle(room["name"].string).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { Task { await model.stop(id) } } label: { Image(systemName: "stop.circle") }.accessibilityLabel("Arrêter les agents") } }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Une idée à partager…", text: Binding(get: { model.data.drafts[id] ?? "" }, set: { model.data.drafts[id] = $0 }), axis: .vertical).lineLimit(1...5)
                    Button(model.data.pending[id] == nil ? "Envoyer" : "Réessayer") {
                        Task { await model.send(id, text: model.data.drafts[id] ?? "") }
                    }.disabled(model.busy || ((model.data.drafts[id] ?? "").isEmpty && model.data.pending[id] == nil))
                }.padding(18).background(IrisTheme.surface)
            }
            .task(id: phase) {
                guard phase == .active else { await model.save(); return }
                // Native hosted rooms expose cursor-based logs, not per-token WS notifications.
                // Pull deltas only while this room is visible; cached rows never disappear.
                while !Task.isCancelled {
                    await model.refresh(id)
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .onDisappear { Task { await model.save() } }
    }
}
