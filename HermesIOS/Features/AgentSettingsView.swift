import SwiftUI

struct AgentSettingsView: View {
    let app: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(app.agent?.title ?? app.profile, systemImage: "person.crop.circle").font(.title3.weight(.medium))
                    Text("Les réglages sont enregistrés dans ce profil Hermes.").font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink { ConfigurationView(app: app, permissions: true) } label: { Label("Permissions", systemImage: "hand.raised") }
                    NavigationLink { CapabilityView(app: app, mcp: false) } label: { Label("Outils disponibles", systemImage: "wrench.and.screwdriver") }
                    NavigationLink { CapabilityView(app: app, mcp: true) } label: { Label("Connexions MCP", systemImage: "puzzlepiece.extension") }
                    NavigationLink { MemoryView(app: app) } label: { Label("Mémoire", systemImage: "brain") }
                    NavigationLink { ConfigurationView(app: app) } label: { Label("Préférences de l’agent", systemImage: "slider.horizontal.3") }
                }
            }.modernList().navigationTitle("Mon agent").navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ConfigurationView: View {
    @State private var tools: NativeToolSession
    @State private var config: JSONValue = [:]
    @State private var fields: JSONValue = [:]
    @State private var search = ""
    let permissions: Bool
    init(app: AppModel, permissions: Bool = false) { _tools = State(initialValue: NativeToolSession(app)); self.permissions = permissions }
    private var keys: [String] {
        fields.object.keys.sorted().filter { key in
            let field = fields[key]
            let relevant = !permissions || key.hasPrefix("approvals.") || key.hasPrefix("command_allowlist")
            return relevant && (search.isEmpty || "\(key) \(field["description"].string)".localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        List {
            if permissions {
                Section { Text("Hermes décide quand votre accord est nécessaire. Une autorisation permanente s’applique aux prochains échanges de cet agent.").font(.subheadline).foregroundStyle(.secondary) }
            }
            ToolFeedback(tools: tools)
            ForEach(keys, id: \.self) { key in
                NavigationLink {
                    ConfigurationEditor(tools: tools, key: key, field: fields[key], original: config.at(key)) { value in
                        config = merge(config, JSONValue.patch(key, value: value))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(friendly(key)).font(.subheadline.weight(.medium))
                        Text(config.at(key).displayText.isEmpty ? "Valeur par défaut" : config.at(key).displayText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 4)
                }
            }
        }.modernList().navigationTitle(permissions ? "Permissions" : "Préférences")
            .searchable(text: $search, prompt: "Rechercher un réglage")
            .task { await load() }.refreshable { await load() }
    }
    private func load() async {
        await tools.perform {
            if tools.app.demo {
                config = ["approvals": ["mode": "smart"]]
                fields = ["approvals.mode": ["type": "select", "options": ["manual", "smart", "off"], "description": "Politique d’autorisation"]]; return
            }
            config = try await tools.request("/api/config")
            fields = try await tools.request("/api/config/schema")["fields"]
        }
    }
    private func merge(_ source: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard case .object(let changes) = patch else { return patch }
        var result = source.object
        for (key, value) in changes { result[key] = merge(result[key] ?? .null, value) }
        return .object(result)
    }
}

private func friendly(_ key: String) -> String {
    ["approvals.mode": "Quand demander mon accord", "approvals.timeout": "Délai de réponse", "approvals.cron_mode": "Actions sensibles des routines", "approvals.single_query_mode": "Actions sans conversation", "approvals.unattended_mode": "Actions automatisées", "approvals.deny": "Règles interdites", "command_allowlist": "Règles toujours autorisées", "approvals.destructive_slash_confirm": "Confirmer les commandes destructives", "approvals.mcp_reload_confirm": "Confirmer le rechargement MCP", "reasoning_effort": "Effort de raisonnement", "timezone": "Fuseau horaire"][key] ?? key.replacingOccurrences(of: "_", with: " ")
}

private struct ConfigurationEditor: View {
    let tools: NativeToolSession
    let key: String
    let field: JSONValue
    let original: JSONValue
    var saved: (JSONValue) -> Void
    @State private var text = ""
    @State private var enabled = false
    @State private var confirm = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section {
                if field["type"].string == "boolean" || field["type"].string == "bool" {
                    Toggle(friendly(key), isOn: $enabled)
                } else if !field["options"].array.isEmpty {
                    Picker("Valeur", selection: $text) {
                        ForEach(field["options"].array.map(\.displayText), id: \.self) { Text(optionLabel($0)).tag($0) }
                    }
                } else { TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 140).textInputAutocapitalization(.never).autocorrectionDisabled() }
            } footer: { Text(field["description"].string) }
            ToolFeedback(tools: tools)
            Button("Enregistrer") {
                if key.hasPrefix("approvals.") || key == "command_allowlist" { confirm = true }
                else { Task { await save() } }
            }.disabled(tools.busy || tools.app.demo)
        }.modernList().navigationTitle(friendly(key)).navigationBarTitleDisplayMode(.inline)
            .task { text = original.isNull ? field["default"].displayText : original.displayText; enabled = original.isNull ? field["default"].bool : original.bool }
            .confirmationDialog("Appliquer cette politique à cet agent ?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Appliquer") { Task { await save() } }
            } message: { Text("Ce choix sera enregistré sur Hermes et pourra modifier les demandes d’autorisation des prochaines actions.") }
    }
    private func optionLabel(_ value: String) -> String {
        ["smart": "Intelligent", "manual": "Me demander", "off": "Ne pas demander", "deny": "Refuser", "approve": "Autoriser"][value] ?? value
    }
    private func save() async {
        await tools.perform {
            let value: JSONValue
            switch field["type"].string {
            case "boolean", "bool": value = .bool(enabled)
            case "integer", "int", "number", "float":
                guard let number = Double(text), number.isFinite else { throw RPCFailure("Entrez un nombre valide.") }; value = .number(number)
            case "array", "list", "object", "dict":
                guard let parsed = try? JSONValue.decode(Data(text.utf8)) else { throw RPCFailure("Ce réglage avancé attend une liste ou un objet JSON valide.") }
                let expectsArray = ["array", "list"].contains(field["type"].string)
                if expectsArray { guard case .array = parsed else { throw RPCFailure("Entrez une liste JSON, entre crochets.") } }
                else { guard case .object = parsed else { throw RPCFailure("Entrez un objet JSON, entre accolades.") } }
                value = parsed
            default: value = .string(text)
            }
            _ = try await tools.request("/api/config", method: "PUT", body: ["config": JSONValue.patch(key, value: value)])
            saved(value); dismiss()
        }
    }
}

struct CapabilityView: View {
    @State private var tools: NativeToolSession
    @State private var search = ""
    @State private var adding = false
    @State private var deleting: JSONValue?
    let mcp: Bool
    init(app: AppModel, mcp: Bool) { _tools = State(initialValue: NativeToolSession(app)); self.mcp = mcp }
    private var path: String { mcp ? "/api/mcp/servers" : "/api/tools/toolsets" }
    private var rows: [JSONValue] { (mcp ? tools.data["servers"].array : tools.data.array).filter { search.isEmpty || "\($0["name"].string) \($0["description"].string)".localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            Section { Text("Les changements s’appliquent aux prochaines sessions de cet agent.").font(.caption).foregroundStyle(.secondary) }
            ToolFeedback(tools: tools)
            ForEach(rows, id: \.["name"].string) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(get: { row["enabled"] != false }, set: { value in Task { await tools.perform {
                        let encoded = row["name"].string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? ""
                        _ = try await tools.request(path + "/" + encoded + (mcp ? "/enabled" : ""), method: "PUT", body: ["enabled": .bool(value)])
                        await tools.load(path)
                    } } })) { Text(row["label"].string.isEmpty ? row["name"].string : row["label"].string) }
                    if !row["description"].string.isEmpty { Text(row["description"].string).font(.caption).foregroundStyle(.secondary) }
                    if mcp { Button("Retirer", role: .destructive) { deleting = row }.font(.caption) }
                }.padding(.vertical, 5).disabled(tools.busy || tools.app.demo)
            }
        }.modernList().navigationTitle(mcp ? "Connexions MCP" : "Outils")
            .searchable(text: $search).task { await tools.load(path) }.refreshable { await tools.load(path) }
            .toolbar { if mcp { Button("Ajouter", systemImage: "plus") { adding = true }.disabled(tools.app.demo) } }
            .sheet(isPresented: $adding) { MCPForm(tools: tools) { Task { await tools.load(path) } } }
            .confirmationDialog("Retirer cette connexion MCP ?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Retirer", role: .destructive) {
                    guard let row = deleting else { return }; deleting = nil
                    Task { await tools.perform {
                        _ = try await tools.request(path + "/" + (row["name"].string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? ""), method: "DELETE")
                        await tools.load(path)
                    } }
                }
            }
    }
}

private struct MCPForm: View {
    let tools: NativeToolSession
    var saved: () -> Void
    @State private var name = ""
    @State private var url = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("Nom", text: $name).textInputAutocapitalization(.never)
                TextField("URL du serveur MCP", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                ToolFeedback(tools: tools)
                Text("Ajoutez un serveur MCP HTTP accessible depuis votre agent.").font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("Ajouter une connexion")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Ajouter") { Task { await tools.perform {
                        guard let address = URL(string: url), ["https", "http"].contains(address.scheme ?? ""), address.host != nil else { throw RPCFailure("Entrez une URL HTTP ou HTTPS valide.") }
                        _ = try await tools.request("/api/mcp/servers", method: "POST", body: ["name": .string(name), "url": .string(url)])
                        saved(); dismiss()
                    } } }.disabled(name.isEmpty || url.isEmpty || tools.busy) }
                }
        }
    }
}
