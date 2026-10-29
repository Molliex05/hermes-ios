import SwiftUI

/// The pages of one agent's settings, shared by its settings root and the menu search.
enum AgentSettingsPage: String, CaseIterable, Identifiable, Hashable {
    case model, voice, permissions, personality, skills, tools, credentials, providers, messaging, plugins
    var id: String { rawValue }
    var title: String {
        switch self {
        case .model: "Modèle"
        case .voice: "Voix"
        case .permissions: "Permissions"
        case .personality: "Mémoire et personnalité"
        case .skills: "Compétences"
        case .tools: "Outils et MCP"
        case .credentials: "Clés et identifiants"
        case .providers: "Fournisseurs"
        case .messaging: "Messagerie"
        case .plugins: "Extensions"
        }
    }
    var detail: String {
        switch self {
        case .model: "Principal, secours, auxiliaires"
        case .voice: "Conversation, transcription, synthèse"
        case .permissions: "Quand demander votre accord"
        case .personality: "SOUL.md, rôle, ce qu’il retient"
        case .skills: "Ses compétences installées"
        case .tools: "Ce qu’il peut utiliser, services MCP"
        case .credentials: "Clés API, sans jamais les afficher"
        case .providers: "Comptes, points de terminaison, modèles"
        case .messaging: "Telegram, Discord, Slack…"
        case .plugins: "Plugins installés et leurs réglages"
        }
    }
    var symbol: String {
        switch self {
        case .model: "cpu"
        case .voice: "waveform"
        case .permissions: "hand.raised"
        case .personality: "brain"
        case .skills: "sparkles"
        case .tools: "wrench.and.screwdriver"
        case .credentials: "key"
        case .providers: "server.rack"
        case .messaging: "bubble.left.and.text.bubble.right"
        case .plugins: "shippingbox"
        }
    }
    /// Extra words for search, including the desktop's English names.
    var keywords: String {
        switch self {
        case .model: "model llm fallback auxiliaire moa"
        case .voice: "voice tts stt micro"
        case .permissions: "approvals approbations accord sécurité"
        case .personality: "memory soul description rôle identité"
        case .skills: "skills"
        case .tools: "tools toolsets mcp serveurs"
        case .credentials: "keys api env secrets"
        case .providers: "providers oauth endpoint"
        case .messaging: "gateway canaux bot"
        case .plugins: "plugins"
        }
    }
    static let essential: [Self] = [.model, .voice, .permissions, .personality, .skills, .tools]
    static let connections: [Self] = [.credentials, .providers, .messaging, .plugins]
}

/// Settings of one Hermes agent, pushed in the menu: « Essentiel », « Connexions », « Avancé ».
/// Without `profile`, it opens on the agent of the current conversation.
struct AgentSettingsView: View {
    let app: AppModel
    @State private var profile: String
    init(app: AppModel, profile: String? = nil) {
        self.app = app
        _profile = State(initialValue: profile ?? app.agent?.name ?? app.profile)
    }
    var body: some View {
        AgentSettingsRoot(app: app, profile: $profile).id(profile)
    }
}

private struct AgentSettingsRoot: View {
    let app: AppModel
    @Binding var profile: String
    @State private var store: AgentConfigStore
    @State private var search = ""
    @Environment(\.returnToChat) private var returnToChat
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, profile: Binding<String>) {
        self.app = app; _profile = profile
        _store = State(initialValue: AgentConfigStore(app: app, profile: profile.wrappedValue))
    }

    private var agent: AgentProfile? { app.profiles.first { $0.name == profile } }
    private var visibleProfiles: [AgentProfile] { app.profiles.filter { $0.hidden != true || $0.name == profile } }
    /// Model and voice are « Essentiel »; memory is part of « Mémoire et personnalité ».
    private var advancedSections: [SettingsSection] { SettingsCatalog.sections.filter { !["model", "voice", "memory"].contains($0.id) } }

    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: "Rechercher un réglage")
            if search.isEmpty {
                Section {
                    HStack(spacing: 14) {
                        AgentAvatar(name: profile, size: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.title).font(.system(.title3, design: .serif))
                            Text(profile == "default" ? "Agent principal · \(store.serverName)" : "@\(profile) · \(store.serverName)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if visibleProfiles.count > 1 {
                            AppMenu {
                                ForEach(visibleProfiles) { agent in
                                    AppMenuButton(agent.title, selected: agent.name == profile) { profile = agent.name }
                                }
                            } label: {
                                Image(systemName: "arrow.left.arrow.right.circle").font(.title2).foregroundStyle(AppTheme.accent)
                                    .frame(width: 44, height: 44)
                            }.accessibilityLabel("Changer d’agent").accessibilityIdentifier("settings-switch-agent")
                        }
                    }.padding(.vertical, 6)
                    if profile != app.profile, let agent {
                        Button { open(agent) } label: { Label("Discuter avec \(agent.title)", systemImage: "bubble.left.and.bubble.right") }
                            .disabled(app.opening || app.sending || app.voiceActive || (!app.demo && app.state != .connected))
                    }
                    if agent != nil {
                        NavigationLink { AgentIdentityView(app: app, name: profile, removed: { dismiss() }) } label: {
                            Label("Nom, épinglage et visibilité", systemImage: "person.text.rectangle")
                        }.accessibilityIdentifier("settings-identity")
                    }
                } footer: { Text("Ces réglages appartiennent à cet agent et sont enregistrés sur son serveur Hermes.").font(.footnote) }
                AgentLookSection(profile: profile)
            }
            SettingsFeedback(store: store, placeholders: !search.isEmpty)
            if !search.isEmpty {
                if store.loaded { SettingsSearchResults(store: store, query: search) }
            } else {
                Section("Essentiel") {
                    ForEach(AgentSettingsPage.essential) { pageLink($0) }
                }
                Section("Connexions") {
                    ForEach(AgentSettingsPage.connections) { pageLink($0) }
                }
                Section("Avancé") {
                    ForEach(advancedSections) { section in
                        NavigationLink { SettingsSectionView(store: store, section: section) } label: {
                            SettingsLinkLabel(title: section.title, detail: section.summary, symbol: section.symbol)
                        }.accessibilityIdentifier("settings-section-" + section.id)
                    }
                    NavigationLink { OtherSettingsView(store: store) } label: {
                        SettingsLinkLabel(title: "Autres réglages", detail: "Tout ce que Hermes expose d’autre", symbol: "ellipsis.circle")
                    }.accessibilityIdentifier("settings-other")
                }
            }
        }.modernList().navigationTitle(store.title).navigationBarTitleDisplayMode(.inline)
            .task { await store.load(); await store.loadModelOptions() }
            .refreshable { await store.load(); await store.loadModelOptions() }
    }

    private func pageLink(_ page: AgentSettingsPage) -> some View {
        NavigationLink { AgentSettingsPageView(store: store, page: page) } label: {
            SettingsLinkLabel(title: page.title, detail: page == .model ? currentModel : page.detail, symbol: page.symbol)
        }.accessibilityLabel(page.title).accessibilityIdentifier("settings-page-" + page.rawValue)
    }

    private var currentModel: String {
        let model = store.modelOptions["model"].string.isEmpty ? store.value("model").string : store.modelOptions["model"].string
        return model.isEmpty ? AgentSettingsPage.model.detail : model
    }

    private func open(_ agent: AgentProfile) {
        if let returnToChat { returnToChat() }
        Task { await app.openBot(agent) }
    }
}

/// One page of an agent's settings, given the store its root (or the host below) loaded.
struct AgentSettingsPageView: View {
    let store: AgentConfigStore
    let page: AgentSettingsPage
    var body: some View {
        switch page {
        case .model: catalogSection("model")
        case .voice: catalogSection("voice")
        case .permissions: ApprovalsSettingsView(store: store)
        case .personality: AgentPersonalityView(store: store)
        case .skills: SkillsView(app: store.app, profile: store.profile)
        case .tools: CapabilityView(app: store.app, profile: store.profile)
        case .credentials: CredentialsSettingsView(app: store.app, profile: store.profile)
        case .providers: ProvidersSettingsView(app: store.app, profile: store.profile)
        case .messaging: MessagingSettingsView(app: store.app, profile: store.profile)
        case .plugins: PluginsSettingsView(app: store.app, profile: store.profile)
        }
    }
    @ViewBuilder private func catalogSection(_ id: String) -> some View {
        if let section = SettingsCatalog.sections.first(where: { $0.id == id }) { SettingsSectionView(store: store, section: section) }
    }
}

/// A settings page opened straight from the menu search, with its own store.
struct AgentSettingsPageHost: View {
    let page: AgentSettingsPage
    @State private var store: AgentConfigStore
    init(app: AppModel, profile: String, page: AgentSettingsPage) {
        self.page = page
        _store = State(initialValue: AgentConfigStore(app: app, profile: profile))
    }
    var body: some View {
        AgentSettingsPageView(store: store, page: page)
            .task { if !store.loaded { await store.load(); await store.loadModelOptions() } }
    }
}

/// « Mémoire et personnalité » — role and SOUL.md (`profiles.configure`), memory files and memory settings.
struct AgentPersonalityView: View {
    let store: AgentConfigStore
    @State private var detail = ""
    @State private var soul = ""
    @State private var loaded = false
    @State private var busy = false
    @State private var saved = false
    @State private var error: String?
    private var app: AppModel { store.app }
    private var name: String { store.profile }

    var body: some View {
        List {
            Section {
                TextField("Son rôle, en quelques mots", text: $detail, axis: .vertical).lineLimit(2...4).disabled(!loaded)
            } header: { Text("Description") } footer: { Text("Sert aussi à Hermes pour répartir le travail entre vos agents.").font(.footnote) }
            Section {
                TextEditor(text: $soul).frame(minHeight: 160).disabled(!loaded)
            } header: { Text("Personnalité · SOUL.md") } footer: { Text("Sa façon de penser, son ton et ses instructions permanentes.").font(.footnote) }
            if let error { Section { Text(error).foregroundStyle(AppTheme.accent) } }
            if saved { Section { Label("Enregistré", systemImage: "checkmark.circle").foregroundStyle(.green) } }
            Section("Mémoire") {
                NavigationLink { AgentMemoryFilesView(app: app, profile: name) } label: {
                    SettingsLinkLabel(title: "Fichiers de mémoire", detail: "Ce qu’il retient et ce qu’il sait de vous", symbol: "doc.text")
                }
                ForEach(SettingsCatalog.sections.first { $0.id == "memory" }?.pages ?? []) { page in
                    NavigationLink { SettingsDestination(store: store, pageID: page.id) } label: {
                        SettingsLinkLabel(title: page.title, detail: page.summary, symbol: page.symbol)
                    }.accessibilityIdentifier("settings-page-" + page.id)
                }
            }
        }.modernList().navigationTitle("Mémoire et personnalité").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "En cours…" : "Enregistrer") { Task { await save() } }.disabled(busy || !loaded || app.demo)
                }
            }
            .task { await load() }
    }

    private func load() async {
        guard !loaded else { return }
        detail = app.profiles.first { $0.name == name }?.detail ?? ""
        if app.demo { soul = "Tu es un assistant attentif et précis."; loaded = true; return }
        do { soul = try await app.describeBot(name)["soul"].string; loaded = true }
        catch { self.error = error.localizedDescription }
    }

    private func save() async {
        busy = true; error = nil; saved = false
        defer { busy = false }
        do { try await app.editBot(name: name, description: detail, soul: soul); saved = true }
        catch { self.error = error.localizedDescription }
    }
}

/// « Outils et MCP » — toolsets (`/api/tools/toolsets`) and MCP servers (`/api/mcp/servers`) of one agent.
struct CapabilityView: View {
    @State private var toolsets: NativeToolSession
    @State private var servers: NativeToolSession
    @State private var mcp = false
    @State private var search = ""
    @State private var adding = false
    @State private var deleting: JSONValue?
    init(app: AppModel, profile: String? = nil) {
        _toolsets = State(initialValue: NativeToolSession(app, profile: profile))
        _servers = State(initialValue: NativeToolSession(app, profile: profile))
    }
    private var tools: NativeToolSession { mcp ? servers : toolsets }
    private var path: String { mcp ? "/api/mcp/servers" : "/api/tools/toolsets" }
    private var rows: [JSONValue] { (mcp ? servers.data["servers"].array : toolsets.data.array).filter { search.isEmpty || "\($0["name"].string) \($0["description"].string)".localizedCaseInsensitiveContains(search) } }
    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: "Rechercher")
            Section {
                AppSegmented(title: "Afficher", selection: $mcp, options: [(value: false, label: "Outils"), (value: true, label: "Connexions MCP")], identifier: "capabilities-filter")
                Text("Les changements s’appliquent aux prochaines sessions de cet agent.").font(.caption).foregroundStyle(.secondary)
            }
            ToolFeedback(tools: tools)
            ForEach(rows, id: \.["name"].string) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: Binding(get: { row["enabled"] != false }, set: { value in
                        let tools = tools, path = path, mcp = mcp
                        Task { await tools.perform {
                            let encoded = row["name"].string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? ""
                            _ = try await tools.request(path + "/" + encoded + (mcp ? "/enabled" : ""), method: "PUT", body: ["enabled": .bool(value)])
                            await tools.load(path)
                        } }
                    })) { Text(row["label"].string.isEmpty ? row["name"].string : row["label"].string) }
                    if !row["description"].string.isEmpty { Text(row["description"].string).font(.caption).foregroundStyle(.secondary) }
                    if mcp { Button("Retirer", role: .destructive) { deleting = row }.font(.caption) }
                }.padding(.vertical, 5).disabled(tools.busy || tools.app.demo)
            }
        }.modernList().navigationTitle("Outils et MCP").navigationBarTitleDisplayMode(.inline)
            .task(id: mcp) { await tools.load(path) }.refreshable { await tools.load(path) }
            .toolbar { if mcp { AppToolbarItem(placement: .primaryAction) { Button("Ajouter", systemImage: "plus") { adding = true }.disabled(tools.app.demo) } } }
            .sheet(isPresented: $adding) { MCPForm(tools: servers) { Task { await servers.load("/api/mcp/servers") } } }
            .appConfirm("Retirer cette connexion MCP ?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Retirer", role: .destructive) {
                    guard let row = deleting else { return }; deleting = nil
                    Task { await servers.perform {
                        _ = try await servers.request("/api/mcp/servers/" + (row["name"].string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? ""), method: "DELETE")
                        await servers.load("/api/mcp/servers")
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
                    AppToolbarItem(placement: .cancellationAction) {
                        AppCloseButton { dismiss() }
                            .accessibilityLabel("Fermer").accessibilityIdentifier("close-mcp-form")
                    }
                    AppToolbarItem(placement: .confirmationAction) { Button("Ajouter") { Task { await tools.perform {
                        guard let address = URL(string: url), ["https", "http"].contains(address.scheme ?? ""), address.host != nil else { throw RPCFailure("Entrez une URL HTTP ou HTTPS valide.") }
                        _ = try await tools.request("/api/mcp/servers", method: "POST", body: ["name": .string(name), "url": .string(url)])
                        saved(); dismiss()
                    } } }.disabled(name.isEmpty || url.isEmpty || tools.busy) }
                }
        }.presentationBackground(AppTheme.background)
    }
}
