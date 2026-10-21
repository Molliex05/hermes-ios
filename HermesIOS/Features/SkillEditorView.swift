import SwiftUI

struct SkillEditorView: View {
    let tools: NativeToolSession
    var skill: JSONValue?
    var refreshed: () async -> Void
    @State private var name = ""
    @State private var content = ""
    @State private var original = ""
    @State private var source = ""
    @State private var mode = "write"
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if skill == nil { AppSegmented(title: "Ajouter", selection: $mode, options: [(value: "write", label: "Écrire"), (value: "install", label: "Installer")]) }
                if mode == "install" {
                    TextField("Source ou identifiant du skill", text: $source).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Hermes utilise son gestionnaire de skills et ses vérifications habituelles.").font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Nom", text: $name).disabled(skill != nil).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextEditor(text: $content).font(.body.monospaced()).frame(minHeight: 260)
                }
                ToolFeedback(tools: tools)
            }.modernList().navigationTitle(skill == nil ? "Ajouter un skill" : "Modifier le skill")
                .toolbar {
                    AppToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    AppToolbarItem(placement: .confirmationAction) {
                        Button(mode == "install" ? "Installer" : "Enregistrer") { Task { await save() } }
                            .disabled(tools.busy || !loaded || (mode == "install" ? source.isEmpty : name.isEmpty || content.isEmpty))
                    }
                }.task {
                    name = skill?["name"].string ?? ""
                    if skill != nil {
                        await tools.perform { content = try await tools.request("/api/skills/content", query: [URLQueryItem(name: "name", value: name)])["content"].string; original = content; loaded = true }
                    } else { content = "---\nname: mon-skill\ndescription: Ce que cette compétence permet de faire.\n---\n\n# Instructions\n"; loaded = true }
                }
        }.presentationBackground(AppTheme.background).interactiveDismissDisabled(tools.busy)
    }
    private func save() async {
        await tools.perform {
            if mode == "install" {
                let previous = Set(try await tools.request("/api/skills").array.map { $0["name"].string })
                let result = try await tools.request("skills.manage", body: ["action": "install", "query": .string(source)], rpc: true)
                let installed = try await tools.request("/api/skills").array.map { $0["name"].string }
                guard result["installed"].bool, installed.contains(where: { !previous.contains($0) }) else { throw RPCFailure("Aucun nouveau skill trouvé après l’installation. Vérifiez la source ou si ce skill est déjà installé.") }
            } else {
                if skill != nil {
                    let latest = try await tools.request("/api/skills/content", query: [URLQueryItem(name: "name", value: name)])
                    guard latest["content"].string == original else { throw RPCFailure("Ce skill a été modifié ailleurs. Rouvrez sa version actuelle avant d’enregistrer.") }
                }
                _ = try await tools.request(skill == nil ? "/api/skills" : "/api/skills/content", method: skill == nil ? "POST" : "PUT", body: ["name": .string(name), "content": .string(content)])
            }
            await refreshed(); dismiss()
        }
    }
}
