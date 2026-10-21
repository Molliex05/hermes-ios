import SwiftUI

/// « Extensions » — desktop plugin-settings.tsx / store/agent-plugins.ts. Everything goes
/// through the `plugins.manage` RPC (tui_gateway/methods_tools.py, profile-scoped); the curated
/// catalog comes from `GET /api/dashboard/plugins/catalog` (hermes_cli/web_routers/dashboard_ui.py).
struct PluginsSettingsView: View {
    let app: AppModel
    @State private var scope: String
    @State private var tools: NativeToolSession
    @State private var plugins: [JSONValue] = []
    @State private var loaded = false
    @State private var showBuiltIn = false
    @State private var search = ""
    @State private var notice: String?

    init(app: AppModel, profile: String? = nil) {
        self.app = app
        let name = profile ?? app.profile
        _scope = State(initialValue: name)
        _tools = State(initialValue: NativeToolSession(app, profile: name))
    }

    private var profileTitle: String { app.profiles.first { $0.name == scope }?.title ?? scope }
    /// Same curation as the desktop `isDesktopRelevantPlugin`.
    private static func relevant(_ row: JSONValue) -> Bool {
        let key = row["key"].string
        if row["source"].string == "bundled" { return ["disk-cleanup", "security-guidance"].contains(key.isEmpty ? row["name"].string : key) }
        return key.isEmpty || !["dashboard_auth/", "model-providers/", "platforms/"].contains { key.hasPrefix($0) }
    }
    private var rows: [JSONValue] {
        plugins.filter { (showBuiltIn || Self.relevant($0)) && (search.isEmpty || "\($0["name"].string) \($0["description"].string)".localizedCaseInsensitiveContains(search)) }
            .sorted { $0["name"].string.lowercased() < $1["name"].string.lowercased() }
    }

    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: "Rechercher une extension")
            if app.demo { AccountsDemoNotice() }
            AccountsScopeSection(app: app, profile: $scope,
                note: "Les extensions s’installent et s’activent pour « \(profileTitle) » sur son serveur Hermes. Leurs clés secrètes vont dans le .env de ce profil.")
            ToolFeedback(tools: tools)
            if let notice { Section { Label(notice, systemImage: "info.circle").font(.subheadline) } }
            Section {
                if !loaded && tools.loading { SkeletonRows(count: 4) }
                else if rows.isEmpty {
                    Text(search.isEmpty ? "Aucune extension installée pour le moment." : "Aucune extension ne correspond.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    NavigationLink { AccountsPluginDetail(tools: tools, plugins: $plugins, key: row["key"].string, name: row["name"].string, profileTitle: profileTitle) } label: { pluginLabel(row) }
                }
            } header: { Text("Installées") }
            Section {
                NavigationLink { AccountsPluginCatalog(tools: tools, installed: plugins) { Task { await load() } } } label: {
                    Label("Catalogue d’extensions", systemImage: "square.grid.2x2")
                }
                Toggle("Afficher les extensions intégrées", isOn: $showBuiltIn)
            } footer: { Text("Les extensions intégrées (fournisseurs, plateformes…) sont activées par défaut et se règlent depuis leur propre écran.") }
        }.modernList().navigationTitle("Extensions").navigationBarTitleDisplayMode(.inline)
            .task(id: scope) {
                if tools.profile != scope { tools = NativeToolSession(app, profile: scope); plugins = []; loaded = false; notice = nil }
                await load()
            }
            .refreshable { await load() }
    }

    private func pluginLabel(_ row: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row["name"].string).font(.subheadline.weight(.medium))
                if !row["version"].string.isEmpty { Text(row["version"].string).font(.caption2).foregroundStyle(.tertiary) }
                if row["update_available"].bool { Text("Mise à jour").font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.accent) }
            }
            if !row["description"].string.isEmpty { Text(row["description"].string).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            AccountsStatusLabel(set: row["status"].string == "enabled", text: Self.status(row["status"].string))
        }.padding(.vertical, 3)
    }

    static func status(_ value: String) -> String {
        ["enabled": "Activée", "disabled": "Désactivée", "not enabled": "Non activée"][value] ?? value
    }

    private func load() async {
        if app.demo {
            plugins = [["name": "disk-cleanup", "key": "disk-cleanup", "version": "1.0", "description": "Nettoie les fichiers temporaires de l’agent.", "source": "bundled", "status": "enabled"],
                       ["name": "kanban", "key": "kanban", "version": "0.4", "description": "Tableaux de projets partagés avec vos agents.", "source": "user", "status": "enabled"]]
            loaded = true; return
        }
        do {
            plugins = try await tools.request("plugins.manage", body: ["action": "list"], rpc: true)["plugins"].array
            loaded = true
        } catch is CancellationError {
        } catch { tools.error = error.localizedDescription }
    }
}

/// Toggle, settings form (plugin-settings-form.tsx), update and removal of one plugin.
private struct AccountsPluginDetail: View {
    let tools: NativeToolSession
    @Binding var plugins: [JSONValue]
    let key: String
    let name: String
    let profileTitle: String
    @State private var values: [String: JSONValue] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var removing = false
    @State private var consent: JSONValue?
    @State private var notice: String?
    @Environment(\.dismiss) private var dismiss
    private var row: JSONValue { plugins.first { $0["key"].string == key && $0["name"].string == name } ?? [:] }
    private var schema: [JSONValue] { row["settings_schema"].array }
    private var removable: Bool { !["bundled", "entrypoint"].contains(row["source"].string) }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.headline)
                    if !row["description"].string.isEmpty { Text(row["description"].string).font(.caption).foregroundStyle(.secondary) }
                    Text([row["version"].string, row["source"].string, row["catalog_tier"].string].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.tertiary)
                }.padding(.vertical, 4)
                Toggle("Activée", isOn: Binding(get: { row["status"].string == "enabled" }, set: { value in Task { await toggle(value) } }))
                    .disabled(key.isEmpty || tools.busy || tools.app.demo)
            } footer: {
                if key.isEmpty { Text("Ce serveur Hermes est trop ancien pour activer cette extension depuis l’app.") }
            }
            if let notice { Section { Label(notice, systemImage: "info.circle").font(.subheadline) } }
            ToolFeedback(tools: tools)
            if !row["servers"].array.isEmpty {
                Section("Serveurs") {
                    ForEach(row["servers"].array, id: \.["name"].string) { server in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(server["name"].string).font(.subheadline)
                            Text(server["sentence"].string).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !schema.isEmpty {
                Section {
                    ForEach(schema, id: \.["key"].string) { field in settingField(field) }
                } header: { Text("Réglages") } footer: { Text("Les champs secrets sont écrits dans le .env de « \(profileTitle) » et ne sont jamais renvoyés à l’app.") }
                Section {
                    Button("Enregistrer") { Task { await saveSettings() } }.disabled(tools.busy || tools.app.demo || (values.isEmpty && secrets.values.allSatisfy(\.isEmpty)))
                }
            }
            if row["update_available"].bool || removable {
                Section {
                    if row["update_available"].bool {
                        Button { Task { await update(accept: false) } } label: {
                            Label("Mettre à jour" + (row["catalog_version"].string.isEmpty ? "" : " vers \(row["catalog_version"].string)"), systemImage: "arrow.down.circle")
                        }.disabled(tools.busy || !row["pinned_sha"].string.isEmpty)
                    }
                    if removable { Button("Désinstaller", role: .destructive) { removing = true }.disabled(tools.busy || tools.app.demo) }
                }
            }
        }.modernList().navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .onDisappear { secrets = [:] }
            .appConfirm("Désinstaller \(name) ?", isPresented: $removing) {
                Button("Désinstaller", role: .destructive) {
                    Task {
                        var ok = false
                        await tools.perform { _ = try await tools.request("plugins.manage", body: ["action": "remove", "name": .string(name)], rpc: true); ok = true }
                        if ok { plugins.removeAll { $0["name"].string == name }; dismiss() }
                    }
                }
            } message: { Text("Les fichiers de l’extension sont supprimés du serveur.") }
            .appConfirm("Cette mise à jour élargit les capacités de l’extension.", isPresented: Binding(get: { consent != nil }, set: { if !$0 { consent = nil } })) {
                Button("Accepter et mettre à jour") { consent = nil; Task { await update(accept: true) } }
            } message: { Text("Vérifiez ce qu’elle pourra faire avant d’accepter : \(consent?["delta"].displayText ?? "")") }
    }

    @ViewBuilder private func settingField(_ field: JSONValue) -> some View {
        let id = field["key"].string
        let label = field["label"].string.isEmpty ? id : field["label"].string
        let current = values[id] ?? (field["value"].isNull ? field["default"] : field["value"])
        VStack(alignment: .leading, spacing: 6) {
            switch field["type"].string {
            case "boolean":
                Toggle(label, isOn: Binding(get: { current.bool }, set: { values[id] = .bool($0) }))
            case "enum":
                AppPicker(title: label, selection: Binding(get: { current.displayText }, set: { values[id] = .string($0) }),
                          options: (field["choices"].array.map(\.displayText).contains(current.displayText) ? [] : [(value: current.displayText, label: current.displayText.isEmpty ? "Non défini" : current.displayText)])
                              + field["choices"].array.map(\.displayText).map { (value: $0, label: $0) })
            case "secret":
                Text(label).font(.subheadline.weight(.medium))
                SecureField(field["has_value"].bool ? "Configurée · laisser vide pour conserver" : "Coller la valeur",
                            text: Binding(get: { secrets[field["env"].string] ?? "" }, set: { secrets[field["env"].string] = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            case "number":
                Text(label).font(.subheadline.weight(.medium))
                TextField("Nombre", text: Binding(get: { current.displayText }, set: { if let number = Double($0) { values[id] = .number(number) } else if $0.isEmpty { values[id] = .null } }))
                    .keyboardType(.decimalPad)
            case "json":
                Text(label).font(.subheadline.weight(.medium))
                TextEditor(text: Binding(get: { current.displayText }, set: { text in
                    values[id] = (try? JSONValue.decode(Data(text.utf8))) ?? .string(text)
                })).font(.callout.monospaced()).frame(minHeight: 90).textInputAutocapitalization(.never).autocorrectionDisabled()
            default:
                Text(label).font(.subheadline.weight(.medium))
                TextField(label, text: Binding(get: { current.displayText }, set: { values[id] = .string($0) }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if !field["description"].string.isEmpty { Text(field["description"].string).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }

    private func replace(_ result: JSONValue) {
        guard case .object = result["plugin"] else { return }
        plugins = plugins.map { $0["key"].string == key ? result["plugin"] : $0 }
    }

    private func toggle(_ enable: Bool) async {
        await tools.perform {
            let result = try await tools.request("plugins.manage", body: ["action": "toggle", "key": .string(key), "enable": .bool(enable)], rpc: true)
            replace(result)
            notice = result["restart_required"].bool ? "Ce changement prend effet au prochain redémarrage de Hermes." : nil
        }
    }

    /// Secrets through `PUT /api/env` first (never the config RPC), then `plugins.manage settings`.
    private func saveSettings() async {
        await tools.perform {
            for (env, value) in secrets where !env.isEmpty && !value.trimmingCharacters(in: .whitespaces).isEmpty {
                _ = try await tools.request("/api/env", method: "PUT", body: ["key": .string(env), "value": .string(value.trimmingCharacters(in: .whitespacesAndNewlines))])
            }
            secrets = [:]
            if !values.isEmpty {
                replace(try await tools.request("plugins.manage", body: ["action": "settings", "key": .string(key), "values": .object(values)], rpc: true))
                values = [:]
            }
            notice = "Réglages enregistrés."
        }
        if notice == "Réglages enregistrés.", let list = try? await tools.request("plugins.manage", body: ["action": "list"], rpc: true)["plugins"].array { plugins = list }
    }

    private func update(accept: Bool) async {
        await tools.perform {
            var body: [String: JSONValue] = ["action": "update", "name": .string(name)]
            if accept { body["accept_capabilities"] = true }
            let result = try await tools.request("plugins.manage", body: .object(body), rpc: true)
            if result["consent_required"].bool { consent = result; return }
            notice = "Extension mise à jour."
            plugins = try await tools.request("plugins.manage", body: ["action": "list"], rpc: true)["plugins"].array
        }
    }
}

/// Curated catalog + install from a Git URL (desktop plugin-install-modal.tsx).
private struct AccountsPluginCatalog: View {
    let tools: NativeToolSession
    let installed: [JSONValue]
    var changed: () -> Void
    @State private var entries: [JSONValue] = []
    @State private var installing: JSONValue?
    @State private var repository = ""
    @State private var pin = ""
    @State private var confirmGit = false
    @State private var result: String?
    @State private var done: Set<String> = []

    private func isInstalled(_ entry: JSONValue) -> Bool {
        let name = entry["name"].string
        return done.contains(name) || installed.contains { $0["catalog_name"].string == name || $0["name"].string == name }
    }
    private var validPin: Bool { pin.isEmpty || (pin.count == 40 && pin.allSatisfy(\.isHexDigit)) }

    var body: some View {
        List {
            Section { Text("Installez uniquement des sources de confiance. Les entrées du catalogue Hermes sont installées depuis leur commit vérifié.").font(.caption).foregroundStyle(.secondary) }
            ToolFeedback(tools: tools)
            if let result { Section { Label(result, systemImage: "info.circle").font(.subheadline) } }
            Section("Catalogue Hermes") {
                if entries.isEmpty && !tools.busy { Text(tools.app.demo ? "Connectez votre Hermes pour parcourir le catalogue." : "Catalogue vide ou indisponible.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(entries, id: \.["name"].string) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry["title"].string.isEmpty ? entry["name"].string : entry["title"].string).font(.subheadline.weight(.medium))
                            if !entry["description"].string.isEmpty { Text(entry["description"].string).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                            Text([entry["tier"].string, entry["maintainer"].string, entry["version"].string].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.tertiary)
                            let env = entry["capabilities"]["requires_env"].array.map(\.string)
                            if !env.isEmpty { Text("Clés requises : \(env.joined(separator: ", "))").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 6)
                        if isInstalled(entry) { Text("Installée").font(.caption).foregroundStyle(.secondary) }
                        else { Button("Installer") { installing = entry }.font(.caption.weight(.semibold)).buttonStyle(.borderless).disabled(tools.busy) }
                    }.padding(.vertical, 3)
                }
            }
            Section {
                TextField("https://github.com/proprietaire/depot", text: $repository).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Épingler à un commit (facultatif)", text: $pin).textInputAutocapitalization(.never).autocorrectionDisabled().font(.callout.monospaced())
                Button("Installer") { confirmGit = true }.disabled(repository.trimmingCharacters(in: .whitespaces).isEmpty || !validPin || tools.busy || tools.app.demo)
            } header: { Text("Installer depuis Git") } footer: {
                Text(validPin ? "Laissez le commit vide pour utiliser le dernier. Préférez https:// ; vérifiez le dépôt avant d’installer." : "Le SHA doit contenir exactement 40 caractères.")
            }
        }.modernList().navigationTitle("Catalogue").navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .appConfirm("Installer \(installing?["name"].string ?? "") ?", isPresented: Binding(get: { installing != nil }, set: { if !$0 { installing = nil } })) {
                Button("Installer et activer") {
                    guard let entry = installing else { return }; installing = nil
                    Task { await install(["action": "install", "catalog_name": .string(entry["name"].string), "enable": true], label: entry["name"].string) }
                }
            } message: { Text("Entrée du catalogue Hermes, installée depuis son commit vérifié \(installing?["sha"].string.prefix(7) ?? "").") }
            .appConfirm("Installer depuis ce dépôt ?", isPresented: $confirmGit) {
                Button("Installer et activer") {
                    var body: [String: JSONValue] = ["action": "install", "identifier": .string(repository.trimmingCharacters(in: .whitespaces)), "enable": true]
                    if !pin.isEmpty { body["ref"] = .string(pin.lowercased()) }
                    Task { await install(body, label: repository) }
                }
            } message: { Text("Le code de ce dépôt s’exécutera sur votre serveur Hermes. N’installez que des sources de confiance.") }
    }

    private func load() async {
        guard !tools.app.demo else { return }
        await tools.perform { entries = try await tools.request("/api/dashboard/plugins/catalog")["entries"].array }
    }

    private func install(_ body: [String: JSONValue], label: String) async {
        result = nil
        await tools.perform {
            let response = try await tools.request("plugins.manage", body: .object(body), rpc: true)
            let name = response["plugin_name"].string.isEmpty ? label : response["plugin_name"].string
            done.insert(body["catalog_name"]?.string ?? name)
            let missing = response["missing_env"].array.map(\.string)
            result = missing.isEmpty ? "\(name) est installée." : "\(name) est installée, mais a besoin d’une clé pour fonctionner : \(missing.joined(separator: ", ")). Ajoutez-la dans Clés et identifiants."
            repository = ""; pin = ""
            changed()
        }
    }
}
