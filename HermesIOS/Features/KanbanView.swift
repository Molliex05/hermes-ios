import SwiftUI

struct KanbanView: View {
    @State private var boards: NativeToolSession
    @State private var board: NativeToolSession
    @State private var slug = ""
    @State private var filter = "all"
    @State private var creating = false
    @State private var detail: JSONValue?
    @State private var creationID = UUID().uuidString
    @State private var title = ""
    @State private var bodyText = ""
    @Environment(\.scenePhase) private var scenePhase
    init(app: AppModel) {
        _boards = State(initialValue: NativeToolSession(app)); _board = State(initialValue: NativeToolSession(app))
    }
    private var query: [URLQueryItem] { [URLQueryItem(name: "board", value: slug)] }
    private var columns: [JSONValue] { board.data["columns"].array }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center) {
                        Menu {
                            ForEach(boards.data["boards"].array, id: \.["slug"].string) { row in
                                Button(row["name"].string.isEmpty ? row["slug"].string : row["name"].string) { slug = row["slug"].string }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(boards.data["boards"].array.first(where: { $0["slug"].string == slug })?["name"].string ?? "Tableaux")
                                    .font(.system(size: 26, design: .serif)).tracking(-0.5)
                                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }.buttonStyle(.plain).disabled(boards.data.isNull).accessibilityLabel("Choisir un tableau")
                        Spacer()
                        Text("\(columns.reduce(0) { $0 + $1["tasks"].array.count }) tâches")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 8)
                    ToolFeedback(tools: boards)
                    ToolFeedback(tools: board)
                    ForEach(columns.filter { (filter == "all" || $0["name"].string == filter) && !$0["tasks"].array.isEmpty }, id: \.["name"].string) { column in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Circle().fill(column["name"].string == "done" ? AppTheme.colors[1] : column["name"].string == "running" ? AppTheme.accent : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                                Text(statusName(column["name"].string).uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.3)
                                Text("\(column["tasks"].array.count)").font(.caption2).foregroundStyle(.tertiary)
                                Spacer()
                            }.foregroundStyle(.secondary).padding(.horizontal, 3)
                            ForEach(column["tasks"].array, id: \.["id"].string) { task in
                                Button { detail = task } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        Text(task["title"].string).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                        if !task["body"].string.isEmpty { Text(task["body"].string).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                        if !task["assignee"].string.isEmpty {
                                            HStack(spacing: 6) {
                                                AgentAvatar(name: task["assignee"].string, size: 18)
                                                Text(task["assignee"].string).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(AppTheme.line.opacity(0.6)))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if !board.data.isNull && columns.filter({ filter == "all" || $0["name"].string == filter }).allSatisfy({ $0["tasks"].array.isEmpty }) {
                        ContentUnavailableView("Une idée à organiser ?", systemImage: "rectangle.split.3x1", description: Text("Ajoutez une tâche pour la retrouver dans votre tableau Hermes."))
                    }
                }.padding(.horizontal, 22).padding(.bottom, 24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.background(AppTheme.background)
                .navigationTitle("Kanban").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ToolDock {
                        Menu {
                            Button("Tout voir") { filter = "all" }
                            ForEach(columns, id: \.["name"].string) { column in
                                Button(statusName(column["name"].string)) { filter = column["name"].string }
                            }
                        } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 44, height: 44) }
                            .accessibilityLabel("Filtrer les tâches")
                        Button { creating = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                            .disabled(slug.isEmpty || board.data.isNull || board.app.demo).accessibilityLabel("Nouvelle tâche")
                    }
                }
                .refreshable { await refresh() }
                .task {
                    await boards.load("/api/plugins/kanban/boards")
                    if slug.isEmpty { slug = boards.data["current"].string.isEmpty ? boards.data["boards"].array.first?["slug"].string ?? "" : boards.data["current"].string }
                }
                .task(id: "\(slug)-\(scenePhase == .active)") {
                    guard !slug.isEmpty, scenePhase == .active else { return }
                    // Same visible-only fallback cadence as the native desktop board.
                    while !Task.isCancelled {
                        await refresh()
                        do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    }
                }
                .onChange(of: slug) { _, _ in filter = "all" }
                .sheet(isPresented: $creating) { createForm }
                .sheet(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
                    if let detail { KanbanDetailView(tools: board, task: detail, board: slug) }
                }
        }
    }
    private func refresh() async { if !slug.isEmpty { await board.load("/api/plugins/kanban/board", query: query) } }
    private var createForm: some View {
        NavigationStack {
            Form {
                TextField("Titre de la tâche", text: $title).disabled(board.busy)
                    .onChange(of: title) { _, _ in if !board.busy { creationID = UUID().uuidString } }
                TextField("Quelques détails…", text: $bodyText, axis: .vertical).lineLimit(4...10).disabled(board.busy)
                    .onChange(of: bodyText) { _, _ in if !board.busy { creationID = UUID().uuidString } }
                Text("Ajoutée dans À préciser. L’orchestration de cette idée reste gérée par Hermes.").font(.caption).foregroundStyle(.secondary)
                ToolFeedback(tools: board)
            }.navigationTitle("Nouvelle tâche").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    Button { Task { await board.perform {
                        let result = try await board.request("/api/plugins/kanban/tasks", method: "POST", body: ["title": .string(title), "body": .string(bodyText), "triage": true, "idempotency_key": .string(creationID)], query: query)
                        guard !result["task"]["id"].string.isEmpty else { throw RPCFailure("Hermes n’a pas confirmé la création. Vérifiez le tableau avant de réessayer.") }
                        creating = false; title = ""; bodyText = ""; creationID = UUID().uuidString; await refresh()
                    } } } label: { Text(board.busy ? "Ajout…" : "Ajouter au tableau").frame(maxWidth: .infinity, minHeight: 48) }
                        .buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || board.busy).padding(20)
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Annuler") { creating = false } } }
        }.interactiveDismissDisabled(board.busy)
    }
}

private struct KanbanDetailView: View {
    let tools: NativeToolSession
    let task: JSONValue
    let board: String
    @State private var full: JSONValue = .null
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(task["title"].string).font(.title2.weight(.semibold))
                    Label(statusName(task["status"].string), systemImage: "circle.dotted").foregroundStyle(AppTheme.accent)
                    Text(full["task"]["body"].isNull ? task["body"].string : full["task"]["body"].string).textSelection(.enabled)
                }
                ToolFeedback(tools: tools)
                if !full["task"]["result"].string.isEmpty { Section("Résultat") { Text(full["task"]["result"].string).textSelection(.enabled) } }
                if !full["comments"].array.isEmpty {
                    Section("Commentaires") {
                        ForEach(Array(full["comments"].array.enumerated()), id: \.offset) { _, comment in
                            VStack(alignment: .leading, spacing: 6) { Text(comment["author"].string).font(.caption.weight(.semibold)); Text(comment["body"].string) }
                        }
                    }
                }
            }.navigationTitle("La tâche").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) { Button("Revenir au tableau") { dismiss() }.buttonStyle(.borderedProminent).controlSize(.large).padding(16) }
                .task {
                    guard !tools.app.demo else { return }
                    await tools.perform {
                        full = try await tools.request("/api/plugins/kanban/tasks/\(task["id"].string)", query: [URLQueryItem(name: "board", value: board)])
                    }
                }
        }
    }
}

private func statusName(_ status: String) -> String {
    ["triage": "À préciser", "todo": "À faire", "ready": "Prêt", "running": "En cours", "blocked": "Bloqué", "review": "À valider", "done": "Terminé", "failed": "En échec", "archived": "Archivé"][status] ?? status.capitalized
}
