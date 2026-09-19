import SwiftUI

struct MemoryView: View {
    @State private var tools: NativeToolSession
    @State private var home = ""
    init(app: AppModel) { _tools = State(initialValue: NativeToolSession(app)) }
    var body: some View {
        List {
            Text("Ce que votre agent retient au fil des échanges.").foregroundStyle(.secondary)
            ToolFeedback(tools: tools)
            if !home.isEmpty {
                NavigationLink("Mémoire de l’agent") { RemoteTextEditor(tools: tools, path: home + "/memories/MEMORY.md", title: "Mémoire") }
                NavigationLink("Ce qu’il sait de vous") { RemoteTextEditor(tools: tools, path: home + "/memories/USER.md", title: "À propos de vous") }
            }
        }.modernList().navigationTitle("Mémoire").task {
            await tools.perform {
                let profiles = try await tools.request("/api/profiles")["profiles"].array
                guard let found = profiles.first(where: { $0["name"].string == tools.profile }), !found["path"].string.isEmpty else { throw RPCFailure("Hermes n’a pas indiqué le dossier de ce profil.") }
                home = found["path"].string
            }
        }
    }
}

struct RemoteFilesView: View {
    let tools: NativeToolSession
    let path: String
    @State private var entries: [JSONValue] = []
    var body: some View {
        List {
            ToolFeedback(tools: tools)
            ForEach(entries, id: \.["path"].string) { entry in
                NavigationLink {
                    if entry["isDirectory"].bool { RemoteFilesView(tools: tools, path: entry["path"].string) }
                    else { RemoteTextEditor(tools: tools, path: entry["path"].string, title: entry["name"].string) }
                } label: { Label(entry["name"].string, systemImage: entry["isDirectory"].bool ? "folder" : "doc.text") }
            }
        }.modernList().navigationTitle(URL(fileURLWithPath: path).lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .task { await tools.perform { entries = try await tools.request("/api/fs/list", query: [URLQueryItem(name: "path", value: path)])["entries"].array } }
    }
}

struct RemoteTextEditor: View {
    let tools: NativeToolSession
    let path: String
    let title: String
    @State private var text = ""
    @State private var original: String?
    @State private var readOnly = false
    @State private var saved = false
    var body: some View {
        VStack(spacing: 12) {
            ToolFeedback(tools: tools)
            if readOnly { ContentUnavailableView("Aperçu limité", systemImage: "doc", description: Text("Ce fichier est binaire ou trop grand pour être modifié ici.")) }
            else { TextEditor(text: $text).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).disabled(original == nil) }
            if saved { Label("Enregistré sur Hermes", systemImage: "checkmark.circle").font(.caption).foregroundStyle(AppTheme.accent) }
        }.padding(18).background(AppTheme.background).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Enregistrer") { Task { await save() } }.disabled(readOnly || original == nil || text == original || tools.busy) }
            .task { await tools.perform {
                let result = try await tools.request("/api/fs/read-text", query: [URLQueryItem(name: "path", value: path)])
                readOnly = result["binary"].bool || result["truncated"].bool
                text = result["text"].string; original = text
            } }
            .onChange(of: text) { _, _ in saved = false }
    }
    private func save() async {
        await tools.perform {
            let current = try await tools.request("/api/fs/read-text", query: [URLQueryItem(name: "path", value: path)])
            guard current["text"].string == original, !current["truncated"].bool, !current["binary"].bool else { throw RPCFailure("Ce fichier a changé sur Hermes. Revenez à la liste et rouvrez-le avant de modifier sa nouvelle version.") }
            _ = try await tools.request("/api/fs/write-text", method: "POST", body: ["path": .string(path), "content": .string(text)])
            original = text; saved = true
        }
    }
}

struct ProjectEditor: View {
    let tools: NativeToolSession
    var project: JSONValue?
    var saved: () async -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var path = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom du projet", text: $name)
                TextField("Description", text: $description, axis: .vertical)
                if project == nil { TextField("Dossier sur le serveur", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled() }
                ToolFeedback(tools: tools)
            }.navigationTitle(project == nil ? "Nouveau projet" : "Modifier le projet")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Enregistrer") { Task { await tools.perform {
                        var body: [String: JSONValue] = ["name": .string(name), "description": .string(description)]
                        if let project { body["id"] = project["id"] }
                        else { body["primary_path"] = .string(path); body["folders"] = [["path": .string(path)]] }
                        _ = try await tools.request(project == nil ? "projects.create" : "projects.update", body: .object(body), rpc: true)
                        await saved(); dismiss()
                    } } }.disabled(name.isEmpty || (project == nil && path.isEmpty) || tools.busy) }
                }.task { name = project?["name"].string ?? ""; description = project?["description"].string ?? "" }
        }
    }
}
