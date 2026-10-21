import SwiftUI

struct KanbanView: View {
    @State private var boards: NativeToolSession
    @State private var board: NativeToolSession
    @State private var slug = ""
    @State private var filter = "all"
    @State private var creating = false
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    AppMenu {
                        ForEach(boards.data["boards"].array, id: \.["slug"].string) { row in
                            AppMenuButton(row["name"].string.isEmpty ? row["slug"].string : row["name"].string, selected: row["slug"].string == slug) { slug = row["slug"].string }
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
                ToolFeedback(tools: boards, placeholders: false)
                if board.data.isNull && (board.loading || boards.loading) { VStack(spacing: 10) { SkeletonRows(count: 3, avatar: false, card: true) } }
                ToolFeedback(tools: board, placeholders: false)
                ForEach(columns.filter { (filter == "all" || $0["name"].string == filter) && !$0["tasks"].array.isEmpty }, id: \.["name"].string) { column in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Circle().fill(column["name"].string == "done" ? AppTheme.colors[1] : column["name"].string == "running" ? AppTheme.accent : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
                            Text(statusName(column["name"].string).uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.3)
                            Text("\(column["tasks"].array.count)").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                        }.foregroundStyle(.secondary).padding(.horizontal, 3)
                        ForEach(column["tasks"].array, id: \.["id"].string) { task in
                            NavigationLink { KanbanDetailView(tools: board, task: task, board: slug) } label: {
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
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(AppTheme.line.opacity(0.6)))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if !board.data.isNull && columns.filter({ filter == "all" || $0["name"].string == filter }).allSatisfy({ $0["tasks"].array.isEmpty }) {
                    ContentUnavailableView("Une idée à organiser ?", systemImage: "rectangle.split.3x1", description: Text("Ajoutez une tâche pour la retrouver dans votre tableau Hermes."))
                }
            }.padding(.horizontal, 22).padding(.bottom, 24).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background(AppTheme.background).appNavigationBar()
            .navigationTitle("Kanban").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .primaryAction) {
                    AppMenu {
                        AppMenuButton("Tout voir", selected: filter == "all") { filter = "all" }
                        ForEach(columns, id: \.["name"].string) { column in
                            AppMenuButton(statusName(column["name"].string), selected: filter == column["name"].string) { filter = column["name"].string }
                        }
                    } label: { Label("Filtrer les tâches", systemImage: "line.3.horizontal.decrease").labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(Rectangle()) }
                }
                AppToolbarItem(placement: .primaryAction) {
                    Button("Nouvelle tâche", systemImage: "plus") { creating = true }.labelStyle(.iconOnly)
                        .disabled(slug.isEmpty || board.data.isNull || board.app.demo)
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
            }.modernList().navigationTitle("Nouvelle tâche").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    Button { Task { await board.perform {
                        let result = try await board.request("/api/plugins/kanban/tasks", method: "POST", body: ["title": .string(title), "body": .string(bodyText), "triage": true, "idempotency_key": .string(creationID)], query: query)
                        guard !result["task"]["id"].string.isEmpty else { throw RPCFailure("Hermes n’a pas confirmé la création. Vérifiez le tableau avant de réessayer.") }
                        creating = false; title = ""; bodyText = ""; creationID = UUID().uuidString; await refresh()
                    } } } label: { Text(board.busy ? "Ajout…" : "Ajouter au tableau").frame(maxWidth: .infinity, minHeight: 48) }
                        .buttonStyle(AppProminentButtonStyle()).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || board.busy).padding(20)
                }
                .toolbar { AppToolbarItem(placement: .cancellationAction) { Button("Annuler") { creating = false } } }
        }.presentationBackground(AppTheme.background).interactiveDismissDisabled(board.busy)
    }
}

private struct KanbanDetailView: View {
    let tools: NativeToolSession
    let task: JSONValue
    let board: String
    @State private var full: JSONValue = .null
    @State private var title = ""
    @State private var bodyText = ""
    @State private var assignee = ""
    @State private var comment = ""
    @State private var assignees: [String] = []
    @State private var confirmAction: String?
    private var path: String { "/api/plugins/kanban/tasks/" + task["id"].string }
    private var query: [URLQueryItem] { [URLQueryItem(name: "board", value: board)] }
    private var current: JSONValue { full["task"].isNull ? task : full["task"] }
    var body: some View {
        Form {
            Section("La tâche") {
                TextField("Titre", text: $title)
                TextField("Description", text: $bodyText, axis: .vertical).lineLimit(4...12)
                AppPicker(title: "Agent", selection: $assignee,
                          options: [(value: "", label: "Non assignée")] + Array(Set(assignees + [assignee])).filter { !$0.isEmpty }.sorted().map { (value: $0, label: $0) })
                Label(statusName(current["status"].string), systemImage: "circle.dotted").foregroundStyle(AppTheme.accent)
                Button("Enregistrer") { Task { await tools.perform {
                    _ = try await tools.request(path, method: "PATCH", body: ["title": .string(title), "body": .string(bodyText), "assignee": .string(assignee)], query: query)
                    try await load()
                } } }.disabled(title.isEmpty || full.isNull || tools.busy || tools.app.demo)
            }
            ToolFeedback(tools: tools)
            Section("Faire avancer") {
                AppMenu {
                    ForEach(["triage", "todo", "ready", "review", "done", "archived"], id: \.self) { state in
                        AppMenuButton(statusName(state), selected: current["status"].string == state) { confirmAction = state }
                    }
                } label: {
                    HStack { Text("Déplacer la tâche"); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                        .foregroundStyle(.primary).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(tools.busy || tools.app.demo)
                if ["failed", "blocked"].contains(current["status"].string) { Button("Remettre en attente") { confirmAction = "ready" }.disabled(tools.busy) }
            }
            if !current["result"].string.isEmpty { Section("Résultat") { MarkdownText(text: current["result"].string).textSelection(.enabled) } }
            Section("Commentaires") {
                ForEach(Array(full["comments"].array.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 6) { Text(row["author"].string).font(.caption.weight(.semibold)); Text(row["body"].string) }
                }
                TextField("Ajouter un commentaire", text: $comment, axis: .vertical)
                Button("Publier") { Task { await tools.perform {
                    _ = try await tools.request(path + "/comments", method: "POST", body: ["body": .string(comment), "author": "Hermès iOS"], query: query)
                    comment = ""; try await load()
                } } }.disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || tools.busy || tools.app.demo)
            }
        }.modernList().navigationTitle("La tâche").navigationBarTitleDisplayMode(.inline)
            .task {
                title = task["title"].string; bodyText = task["body"].string; assignee = task["assignee"].string
                guard !tools.app.demo else { return }
                await tools.perform {
                    try await load()
                    assignees = try await tools.request("/api/plugins/kanban/assignees", query: query)["assignees"].array.map(\.string)
                }
            }
            .appConfirm("Déplacer vers \(statusName(confirmAction ?? "")) ?", isPresented: Binding(get: { confirmAction != nil }, set: { if !$0 { confirmAction = nil } })) {
                Button("Déplacer") {
                    guard let state = confirmAction else { return }; confirmAction = nil
                    Task { await tools.perform {
                        _ = try await tools.request(path, method: "PATCH", body: ["status": .string(state)], query: query)
                        try await load()
                    } }
                }
            } message: { Text("Hermes applique ses règles de dépendance et peut lancer un agent lorsqu’une tâche devient prête.") }
    }
    private func load() async throws {
        full = try await tools.request(path, query: query)
        title = full["task"]["title"].string; bodyText = full["task"]["body"].string; assignee = full["task"]["assignee"].string
    }
}

private func statusName(_ status: String) -> String {
    ["triage": "À préciser", "todo": "À faire", "ready": "Prêt", "running": "En cours", "blocked": "Bloqué", "review": "À valider", "done": "Terminé", "failed": "En échec", "archived": "Archivé"][status] ?? status.capitalized
}
