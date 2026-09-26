import SwiftUI

struct AgentSettingsView: View {
    let app: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AgentAvatar(name: app.profile, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.agent?.title ?? app.profile).font(.title3.weight(.medium))
                            Text(app.activeConnection?.name ?? "Aperçu interactif").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                } footer: { Text("Ces réglages appartiennent à cet agent et sont enregistrés sur son serveur Hermes.") }
                Section("Son fonctionnement") {
                    NavigationLink { ConfigurationView(app: app, permissions: true) } label: {
                        settingsRow("Permissions", detail: "Quand demander votre accord", symbol: "hand.raised")
                    }.accessibilityLabel("Permissions")
                    NavigationLink { CapabilityView(app: app, mcp: false) } label: {
                        settingsRow("Outils disponibles", detail: "Ce que l’agent peut utiliser", symbol: "wrench.and.screwdriver")
                    }
                    NavigationLink { CapabilityView(app: app, mcp: true) } label: {
                        settingsRow("Connexions MCP", detail: "Ses services et intégrations", symbol: "puzzlepiece.extension")
                    }
                    NavigationLink { MemoryView(app: app) } label: {
                        settingsRow("Mémoire", detail: "Ce qu’il retient de vos échanges", symbol: "brain")
                    }
                    NavigationLink { ConfigurationView(app: app) } label: {
                        settingsRow("Préférences de l’agent", detail: "Tous les réglages Hermes", symbol: "slider.horizontal.3")
                    }
                }
            }.modernList().navigationTitle("Mon agent").navigationBarTitleDisplayMode(.inline)
        }
    }

    private func settingsRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(AppTheme.accent).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
    }
}

struct ConfigurationView: View {
    @State private var tools: NativeToolSession
    @State private var config: JSONValue = [:]
    @State private var fields: JSONValue = [:]
    @State private var search = ""
    let permissions: Bool
    private let profileTitle: String
    private let connectionName: String
    init(app: AppModel, permissions: Bool = false) {
        _tools = State(initialValue: NativeToolSession(app)); self.permissions = permissions
        profileTitle = app.agent?.title ?? app.profile
        connectionName = app.activeConnection?.name ?? "Aperçu interactif"
    }
    private let everydayPermissions = ["approvals.mode", "approvals.timeout", "approvals.cron_mode", "approvals.destructive_slash_confirm", "approvals.mcp_reload_confirm"]
    private var keys: [String] {
        fields.object.keys.sorted().filter { key in
            let field = fields[key]
            let relevant = !permissions || key.hasPrefix("approvals.") || key.hasPrefix("command_allowlist")
            return relevant && (search.isEmpty || "\(key) \(friendly(key)) \(field["description"].string)".localizedCaseInsensitiveContains(search))
        }
    }
    private func isAdvanced(_ key: String) -> Bool {
        if permissions { return !everydayPermissions.contains(key) }
        return ["array", "list", "object", "dict"].contains(fields[key]["type"].string)
    }
    private var simpleKeys: [String] {
        permissions ? everydayPermissions.filter { keys.contains($0) } : keys.filter { !isAdvanced($0) }
    }
    private var advancedKeys: [String] { keys.filter(isAdvanced) }

    var body: some View {
        List {
            if search.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        AgentAvatar(name: tools.profile, size: 38)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profileTitle).font(.headline)
                            Text(connectionName).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                } footer: {
                    Text(permissions
                         ? "Politique enregistrée pour cet agent. Les exceptions de session et les protections du serveur restent gérées par Hermes."
                         : "Les changements sont enregistrés dans ce profil Hermes.")
                }
            }
            ToolFeedback(tools: tools)
            if tools.busy && fields.object.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Chargement des réglages…").foregroundStyle(.secondary) }
            } else if !search.isEmpty {
                if keys.isEmpty { ContentUnavailableView.search(text: search) }
                else { configurationRows(keys) }
            } else {
                if !simpleKeys.isEmpty {
                    Section(permissions ? "Votre accord" : "Réglages") { configurationRows(simpleKeys) }
                }
                if !advancedKeys.isEmpty {
                    Section {
                        NavigationLink {
                            List {
                                Section { Text("Les mêmes réglages Hermes, pour ajuster les règles et les cas particuliers de \(profileTitle).").font(.subheadline).foregroundStyle(.secondary) }
                                ToolFeedback(tools: tools)
                                configurationRows(advancedKeys)
                            }.modernList().navigationTitle("Réglages avancés").navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Réglages avancés", systemImage: "slider.horizontal.3").font(.subheadline.weight(.medium))
                                Text(permissions ? "Règles permanentes et autres automatisations" : "Listes et paramètres structurés")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("configuration-advanced")
                    }
                }
            }
        }.modernList().navigationTitle(permissions ? "Permissions" : "Préférences")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Rechercher un réglage")
            .task { await load() }.refreshable { await load() }
    }

    private func configurationRows(_ entries: [String]) -> some View {
        ForEach(entries, id: \.self) { key in
            NavigationLink {
                ConfigurationEditor(tools: tools, key: key, field: fields[key], original: config.at(key), profileTitle: profileTitle) { value in
                    config = merge(config, JSONValue.patch(key, value: value))
                }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(friendly(key)).font(.subheadline.weight(.medium))
                    Text(configurationSummary(key: key, value: config.at(key), field: fields[key]))
                        .font(.caption).foregroundStyle(key == "approvals.mode" ? AppTheme.accent : .secondary).lineLimit(2)
                    if key == "approvals.mode", let effect = approvalEffect(config.at(key).string) {
                        Text(effect).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.vertical, 5)
            }.accessibilityIdentifier("configuration-" + key)
        }
    }
    private func load() async {
        await tools.perform {
            if tools.app.demo {
                config = ["approvals": ["mode": "smart", "timeout": 300, "cron_mode": "deny", "deny": []], "command_allowlist": []]
                fields = [
                    "approvals.mode": ["type": "select", "options": ["manual", "smart", "off"], "description": "Politique d’autorisation"],
                    "approvals.timeout": ["type": "number"], "approvals.cron_mode": ["type": "string"],
                    "approvals.deny": ["type": "list"], "command_allowlist": ["type": "list"]
                ]; return
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
    ["approvals.mode": "Quand demander mon accord", "approvals.timeout": "Délai de réponse", "approvals.cron_mode": "Actions sensibles des routines", "approvals.single_query_mode": "Actions sans conversation", "approvals.unattended_mode": "Actions automatisées", "approvals.deny": "Règles interdites", "command_allowlist": "Règles toujours autorisées", "approvals.smart_policy": "Consignes de l’évaluation intelligente", "approvals.denial_breaker_threshold": "Limite des refus consécutifs", "approvals.destructive_slash_confirm": "Confirmer les commandes destructives", "approvals.mcp_reload_confirm": "Confirmer le rechargement MCP", "reasoning_effort": "Effort de raisonnement", "timezone": "Fuseau horaire"][key] ?? key.replacingOccurrences(of: "_", with: " ")
}

private func configurationOption(_ value: String, key: String) -> String {
    guard key.hasPrefix("approvals.") else { return value }
    return ["smart": "Évaluation intelligente", "manual": "Me demander", "off": "Sans demande d’accord", "deny": "Refuser", "approve": "Autoriser"][value] ?? value
}

// These describe the native approval modes, not a client-side permission system.
private func approvalEffect(_ value: String) -> String? {
    switch value {
    case "manual": "Hermes vous demande avant les actions qui nécessitent une autorisation."
    case "smart": "Hermes évalue les actions sensibles et vous demande quand un accord est nécessaire."
    case "off": "Hermes exécute les actions sans demande d’accord. Les règles d’interdiction du serveur restent applicables."
    default: nil
    }
}

private func configurationSummary(key: String, value: JSONValue, field: JSONValue) -> String {
    let effective = value.isNull ? field["default"] : value
    if effective.isNull { return "Valeur par défaut du serveur" }
    switch effective {
    case .array(let values):
        if values.isEmpty { return key == "approvals.deny" || key == "command_allowlist" ? "Aucune règle" : "Aucun élément" }
        return "\(values.count) élément\(values.count == 1 ? "" : "s")"
    case .object(let values): return "\(values.count) paramètre\(values.count == 1 ? "" : "s")"
    case .string(let text): return text.isEmpty ? "Non défini" : configurationOption(text, key: key)
    case .number where key == "approvals.timeout": return "\(effective.displayText) secondes"
    default: return effective.displayText
    }
}

private struct ConfigurationEditor: View {
    let tools: NativeToolSession
    let key: String
    let field: JSONValue
    let original: JSONValue
    let profileTitle: String
    var saved: (JSONValue) -> Void
    @State private var text = ""
    @State private var enabled = false
    @State private var confirm = false
    @Environment(\.dismiss) private var dismiss
    private var options: [String] { field["options"].array.map(\.displayText) }
    private var isBoolean: Bool { ["boolean", "bool"].contains(field["type"].string) }
    private var isStructured: Bool { ["array", "list", "object", "dict"].contains(field["type"].string) }
    var body: some View {
        Form {
            Section { Label(profileTitle, systemImage: "person.crop.circle").font(.subheadline).foregroundStyle(.secondary) }
            Section {
                if isBoolean {
                    Toggle(friendly(key), isOn: $enabled)
                } else if key == "approvals.mode", !options.isEmpty {
                    ForEach(options, id: \.self) { option in
                        Button { text = option } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(configurationOption(option, key: key)).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                    if let effect = approvalEffect(option) { Text(effect).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: text == option ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(text == option ? AppTheme.accent : .secondary).font(.title3)
                            }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(text == option ? .isSelected : [])
                            .accessibilityIdentifier("approval-mode-" + option)
                    }
                    if !text.isEmpty && !options.contains(text) { Text("Valeur actuelle : \(text)").font(.caption).foregroundStyle(.secondary) }
                } else if !options.isEmpty {
                    Picker("Valeur", selection: $text) {
                        if !options.contains(text) { Text(text.isEmpty ? "Non défini" : text).tag(text) }
                        ForEach(options, id: \.self) { Text(configurationOption($0, key: key)).tag($0) }
                    }
                } else if ["integer", "int", "number", "float"].contains(field["type"].string) {
                    TextField(key == "approvals.timeout" ? "Secondes" : "Valeur", text: $text).keyboardType(.numbersAndPunctuation)
                } else {
                    TextEditor(text: $text).font(isStructured ? .body.monospaced() : .body).frame(minHeight: 140)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel(isStructured ? "Valeur JSON" : "Valeur")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if key == "approvals.timeout" { Text("Après ce délai sans réponse, Hermes refuse l’action en attente.") }
                    if ["approvals.cron_mode", "approvals.single_query_mode", "approvals.unattended_mode"].contains(key) {
                        Text("Pour les commandes sensibles exécutées sans personne pour répondre : « deny » les refuse, « approve » les autorise automatiquement.")
                    }
                    if key == "approvals.deny" { Text("Les commandes correspondant à ces règles sont refusées, même en mode sans demande d’accord.") }
                    if key == "command_allowlist" { Text("Ces règles autorisent les commandes correspondantes sans nouvelle demande. Les interdictions restent prioritaires.") }
                    if isStructured { Text("Ce réglage utilise le format JSON de Hermes.") }
                    if !field["description"].string.isEmpty { Text(field["description"].string) }
                }
            }
            ToolFeedback(tools: tools)
            Button("Enregistrer") {
                if key.hasPrefix("approvals.") || key == "command_allowlist" { confirm = true }
                else { Task { await save() } }
            }.disabled(tools.busy || tools.app.demo)
        }.modernList().navigationTitle(friendly(key)).navigationBarTitleDisplayMode(.inline)
            .task { text = original.isNull ? field["default"].displayText : original.displayText; enabled = original.isNull ? field["default"].bool : original.bool }
            .confirmationDialog("Appliquer ce réglage à \(profileTitle) ?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Appliquer") { Task { await save() } }
            } message: { Text("Ce choix sera enregistré sur Hermes et pourra modifier les demandes d’autorisation des prochaines actions.") }
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
            }.modernList().navigationTitle("Ajouter une connexion").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Fermer").accessibilityIdentifier("close-mcp-form")
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("Ajouter") { Task { await tools.perform {
                        guard let address = URL(string: url), ["https", "http"].contains(address.scheme ?? ""), address.host != nil else { throw RPCFailure("Entrez une URL HTTP ou HTTPS valide.") }
                        _ = try await tools.request("/api/mcp/servers", method: "POST", body: ["name": .string(name), "url": .string(url)])
                        saved(); dismiss()
                    } } }.disabled(name.isEmpty || url.isEmpty || tools.busy) }
                }
        }
    }
}
