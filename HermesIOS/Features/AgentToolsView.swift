import SwiftUI

struct ToolFeedback: View {
    let tools: NativeToolSession
    /// Placeholders only while nothing (not even a cached copy) is displayed.
    var placeholders = true
    var card = false
    var body: some View {
        if placeholders && tools.loading && tools.data.isNull {
            SkeletonRows(count: 4, avatar: !card, card: card)
        }
        if let error = tools.error {
            Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(AppTheme.accent)
        }
    }
}

struct SkillsView: View {
    @State private var tools: NativeToolSession
    @State private var search = ""
    @State private var adding = false
    init(app: AppModel, profile: String? = nil) { _tools = State(initialValue: NativeToolSession(app, profile: profile)) }
    private var skills: [JSONValue] {
        tools.data.array.filter { search.isEmpty || "\($0["name"].string) \($0["description"].string)".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List { AppSearchSection(text: $search, prompt: "Rechercher un skill"); Group {
            AppIntro("Les compétences de \(tools.profile). Activez celles dont votre agent a besoin.")
            ToolFeedback(tools: tools)
            ForEach(skills, id: \.["name"].string) { skill in
                NavigationLink {
                    SkillDetailView(tools: tools, skill: skill)
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "sparkles").foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(skill["name"].string).font(.headline)
                            Text(skill["description"].string).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Circle().fill(skill["enabled"] == false ? Color.secondary.opacity(0.3) : AppTheme.accent).frame(width: 7, height: 7)
                            .accessibilityLabel(skill["enabled"] == false ? "Désactivé" : "Activé")
                    }.padding(.vertical, 9)
                }
            }
            if !tools.data.isNull && skills.isEmpty { ContentUnavailableView("Aucun skill", systemImage: "sparkles", description: Text("Vos compétences installées apparaîtront ici.")) }
        }
}
            .modernList()
            .navigationTitle("Compétences").navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .primaryAction) { Button("Ajouter", systemImage: "plus") { adding = true }.disabled(tools.app.demo) } }
            .sheet(isPresented: $adding) { SkillEditorView(tools: tools, refreshed: load) }
            .refreshable { await load() }.task { await load() }
    }
    private func load() async { await tools.load("/api/skills") }
}

private struct SkillDetailView: View {
    let tools: NativeToolSession
    let skill: JSONValue
    @State private var content = ""
    @State private var enabled = true
    @State private var reading = true
    @State private var editing = false
    @State private var operation: String?
    @State private var output: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List { Group {
            Section {
                Text(skill["description"].string).foregroundStyle(.secondary)
                Toggle("Disponible pour l’agent", isOn: Binding(get: { enabled }, set: { value in
                    Task { await tools.perform {
                        let result = try await tools.request("/api/skills/toggle", method: "PUT", body: ["name": skill["name"], "enabled": .bool(value)])
                        guard result["ok"].bool else { throw RPCFailure("Le skill n’a pas été modifié.") }
                        enabled = result["enabled"].bool
                        await tools.load("/api/skills")
                    } }
                })).disabled(tools.busy || tools.app.demo)
            }
            ToolFeedback(tools: tools)
            Section("Gérer") {
                Button("Modifier les instructions") { editing = true }.disabled(reading || tools.app.demo)
                if skill["provenance"].string == "hub" {
                    Button("Mettre à jour depuis sa source") { operation = "update" }.disabled(tools.app.demo)
                    Button("Désinstaller", role: .destructive) { operation = "uninstall" }.disabled(tools.app.demo)
                } else { Text("Pour retirer cette compétence de l’agent, désactivez-la ci-dessus.").font(.caption).foregroundStyle(.secondary) }
            }.disabled(tools.busy)
            if let output { Text(output).font(.caption).textSelection(.enabled) }
            Section("Instructions") {
                if reading { ProgressView() }
                else { Text(content.isEmpty ? "Aucune instruction disponible." : content).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled) }
            }
        }
}.modernList()
            .navigationTitle(skill["name"].string).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $editing) { SkillEditorView(tools: tools, skill: skill) {
                content = (try? await tools.request("/api/skills/content", query: [URLQueryItem(name: "name", value: skill["name"].string)]))?["content"].string ?? content
                await tools.load("/api/skills")
            } }
            .appConfirm(operation == "uninstall" ? "Désinstaller ce skill ?" : "Mettre à jour ce skill ?", isPresented: Binding(get: { operation != nil }, set: { if !$0 { operation = nil } })) {
                Button(operation == "uninstall" ? "Désinstaller" : "Mettre à jour", role: operation == "uninstall" ? .destructive : nil) {
                    guard let action = operation else { return }; operation = nil
                    Task { await tools.perform {
                        var args: [JSONValue] = ["--profile", .string(tools.profile), "skills", .string(action), skill["name"]]
                        if action == "uninstall" { args.append("--yes") }
                        let result = try await tools.request("cli.exec", body: ["argv": .array(args), "timeout": 180], rpc: true)
                        guard !result["blocked"].bool, result["code"].int == 0 else { throw RPCFailure(result["hint"].string + " " + result["output"].string) }
                        output = result["output"].string; await tools.load("/api/skills")
                        if action == "uninstall" {
                            guard !tools.data.array.contains(where: { $0["name"] == skill["name"] }) else { throw RPCFailure("Hermes n’a pas retiré ce skill. " + result["output"].string) }
                            dismiss()
                        }
                    } }
                }
            }
            .task {
                enabled = skill["enabled"] != false
                defer { reading = false }
                if tools.app.demo { content = "# \(skill["name"].string)\n\n\(skill["description"].string)"; return }
                await tools.perform {
                    let result = try await tools.request("/api/skills/content", query: [URLQueryItem(name: "name", value: skill["name"].string)])
                    content = result["content"].string
                }
            }
    }
}

struct WorkspaceView: View {
    @State private var tools: NativeToolSession
    @State private var search = ""
    @State private var creating = false
    init(app: AppModel) { _tools = State(initialValue: NativeToolSession(app)) }
    var body: some View {
        List { AppSearchSection(text: $search, prompt: "Retrouver un projet"); Group {
            AppIntro("Les projets et dossiers de \(tools.profile), sur votre serveur Hermes.")
            ToolFeedback(tools: tools)
            ForEach(tools.data["projects"].array.filter { !$0["archived"].bool && $0["archived"].int == 0 && (search.isEmpty || $0["name"].string.localizedCaseInsensitiveContains(search)) }, id: \.["id"].string) { project in
                NavigationLink {
                    List { Group {
                        if !project["description"].string.isEmpty { Text(project["description"].string) }
                        Section("Fichiers") { NavigationLink("Parcourir le dossier") { RemoteFilesView(tools: tools, path: project["primary_path"].string) } }
                        Section("Dossier principal") { Text(project["primary_path"].string).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled) }
                        Section("Dossiers du projet") {
                            ForEach(project["folders"].array, id: \.["path"].string) { folder in
                                VStack(alignment: .leading, spacing: 6) {
                                    if !folder["label"].string.isEmpty { Label(folder["label"].string, systemImage: "folder") }
                                    Text(folder["path"].string).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                        Section("Gérer") {
                            NavigationLink("Modifier le projet") { ProjectEditor(tools: tools, project: project, saved: load) }
                            Button("Utiliser dans la conversation") { Task { await tools.perform { try await tools.app.useWorkspace(project["primary_path"].string); _ = try await tools.request("projects.set_active", body: ["id": project["id"]], rpc: true) } } }.disabled(tools.app.transcript.running)
                        }
                        if !project["board_slug"].string.isEmpty { Section("Tableau associé") { Text(project["board_slug"].string) } }
                    }
}.navigationTitle(project["name"].string).navigationBarTitleDisplayMode(.inline)
                        .modernList()
                } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "folder").font(.title2).foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(project["name"].string).font(.headline)
                            Text(project["primary_path"].string).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.padding(.vertical, 10)
                }
            }
            if !tools.data.isNull && tools.data["projects"].array.isEmpty { ContentUnavailableView("Votre prochain projet", systemImage: "folder", description: Text("Les workspaces créés dans Hermes apparaîtront ici.")) }
        }
}
            .modernList()
            .navigationTitle("Espace de travail").navigationBarTitleDisplayMode(.inline)
            .toolbar { AppToolbarItem(placement: .primaryAction) { Button("Créer", systemImage: "plus") { creating = true }.disabled(tools.app.demo) } }
            .sheet(isPresented: $creating) { ProjectEditor(tools: tools, saved: load) }
            .task { await load() }.refreshable { await load() }
    }
    private func load() async { await tools.load("projects.list", rpc: true) }
}
