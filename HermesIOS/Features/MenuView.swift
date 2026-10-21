import SwiftUI

/// Everything reachable from the menu, its favorites and its search. Agent settings pages live in `AgentSettingsPage`.
enum AppDestination: String, Identifiable, CaseIterable, Hashable {
    case history, routines, kanban, workspace, groups, skills, agents, connections, notifications, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .history: "Conversations"
        case .routines: "Routines"
        case .kanban: "Kanban"
        case .workspace: "Espace de travail"
        case .groups: "Groupes"
        case .skills: "Compétences"
        case .agents: "Gérer et créer"
        case .connections: "Connexions"
        case .notifications: "Notifications"
        case .about: "À propos"
        }
    }
    var detail: String {
        switch self {
        case .history: "Retrouver le fil"
        case .routines: "Automatiser · cron jobs"
        case .kanban: "Suivre les tâches"
        case .workspace: "Projets et dossiers · workspace"
        case .groups: "Vos agents, ensemble"
        case .skills: "Skills de l’agent actif"
        case .agents: "Profils, identité, nouvel agent"
        case .connections: "Vos serveurs Hermes"
        case .notifications: "Réponses et routines"
        case .about: "Version, guide, code source"
        }
    }
    var symbol: String {
        switch self {
        case .history: "bubble.left.and.bubble.right"
        case .routines: "clock.arrow.2.circlepath"
        case .kanban: "rectangle.split.3x1"
        case .workspace: "folder"
        case .groups: "person.2"
        case .skills: "sparkles"
        case .agents: "person.crop.circle.badge.plus"
        case .connections: "server.rack"
        case .notifications: "bell.badge"
        case .about: "info.circle"
        }
    }
    static let work: [AppDestination] = [.history, .routines, .kanban, .workspace, .groups]
    static let settings: [AppDestination] = [.connections, .notifications, .about]
}

enum MenuRoute: Hashable {
    case destination(AppDestination)
    case agent(String)
    case agentPage(String, AgentSettingsPage)
    case favorites
}

/// The single menu over the chat: one navigation stack, native lists and pushes.
struct MenuView: View {
    let model: AppModel
    @State private var path: [MenuRoute] = []
    @State private var search = ""
    @State private var store: AgentConfigStore?
    @State private var switching: SavedConnection?
    @AppStorage("hermes.favoriteTools") private var savedFavorites = "routines,workspace,history"
    @AppStorage("hermes.showHiddenAgents") private var showHidden = false
    @Environment(\.returnToChat) private var returnToChat
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var favorites: [AppDestination] { FavoriteTools.decode(savedFavorites) }
    private var agents: [AgentProfile] {
        showHidden ? model.profiles.sorted { ($0.pinned == true ? 0 : 1) < ($1.pinned == true ? 0 : 1) } : model.visibleBots
    }
    private var hasHiddenAgents: Bool { model.profiles.contains { $0.hidden == true && $0.name != model.profile } }
    private var otherServers: [SavedConnection] { model.connections.filter { $0.id != model.activeConnection?.id } }
    private var canSwitch: Bool { !model.opening && !model.sending && !model.voiceActive && (model.demo || model.state == .connected) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                AppSearchSection(text: $search, prompt: "Outils, agents, réglages")
                if query.isEmpty { home } else { results }
            }.modernList()
                .navigationTitle("Menu").navigationBarTitleDisplayMode(.large)
                .toolbar {
                    AppToolbarItem(placement: .topBarTrailing) {
                        AppCloseButton(label: "Revenir au chat") { close() }
                            .accessibilityIdentifier("return-to-chat")
                    }
                }
                .navigationDestination(for: MenuRoute.self) { destination($0) }
                .task(id: query.isEmpty) {
                    // Settings fields are searched in the current agent's configuration, loaded once on first search.
                    guard !query.isEmpty, store == nil else { return }
                    let loaded = AgentConfigStore(app: model, profile: model.profile)
                    store = loaded
                    await loaded.load()
                }
                .appConfirm("Basculer vers \(switching?.name ?? "") ?", isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } })) {
                    Button("Basculer") {
                        guard let connection = switching else { return }; switching = nil
                        Task { await model.activate(connection) }
                    }
                } message: { Text("Hermès iOS se connecte à ce serveur et affiche ses agents. La conversation en cours reste sur l’autre serveur.") }
        }.presentationBackground(AppTheme.background)
    }

    // MARK: Home

    @ViewBuilder private var home: some View {
        Section {
            NavigationLink(value: MenuRoute.agent(model.profile)) { currentAgent }
                .accessibilityIdentifier("menu-current-agent")
        }.listSectionSeparator(.hidden, edges: .top)
        Section {
            if favorites.isEmpty {
                Text("Épinglez jusqu’à trois raccourcis.").font(.caption).foregroundStyle(.secondary)
            } else {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                layout {
                    ForEach(favorites) { entry in
                        Button { path.append(.destination(entry)) } label: {
                            VStack(spacing: 9) {
                                Image(systemName: entry.symbol).font(.system(size: 20)).foregroundStyle(AppTheme.accent)
                                Text(entry.title).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity, minHeight: 75).padding(.horizontal, 5).padding(.vertical, 8)
                                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                                .contentShape(RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).accessibilityIdentifier("favorite-tool-\(entry.rawValue)")
                    }
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }
        } header: {
            HStack {
                Text("Accès rapides")
                Spacer()
                Button(favorites.isEmpty ? "Ajouter" : "Modifier") { path.append(.favorites) }
                    .font(.caption.weight(.medium)).foregroundStyle(AppTheme.accent).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Modifier les accès rapides").accessibilityIdentifier("edit-tool-favorites")
            }
        }
        Section("Travail") {
            ForEach(AppDestination.work) { destinationRow($0) }
        }
        Section {
            ForEach(agents) { agentRow($0) }
            if agents.isEmpty && !model.demo && model.state != .offline { SkeletonRows(count: 3) }
            if hasHiddenAgents || showHidden {
                Toggle("Afficher les agents masqués", isOn: $showHidden).font(.subheadline)
                    .accessibilityIdentifier("menu-show-hidden")
            }
            destinationRow(.agents)
            ForEach(otherServers) { connection in
                Button { switching = connection } label: {
                    MenuLabel(title: connection.name, detail: connection.endpoint.baseURL.host ?? "Autre serveur", symbol: "arrow.left.arrow.right")
                }.buttonStyle(.plain).disabled(model.sending || model.voiceActive)
                    .accessibilityHint("Basculer vers ce serveur")
            }
        } header: { Text("Mes agents") } footer: {
            Text("Touchez un agent pour discuter avec lui, ou \(Image(systemName: "slider.horizontal.3")) pour ses réglages.").font(.footnote)
        }
        Section("App") {
            ForEach(AppDestination.settings) { destinationRow($0) }
        }
    }

    private var currentAgent: some View {
        HStack(spacing: 14) {
            AgentAvatar(name: model.profile, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.agent?.title ?? "Hermes").font(.system(.title3, design: .serif)).foregroundStyle(.primary)
                let detail = [model.agent?.model ?? "", model.activeConnection?.name ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1) }
                ConnectionIndicator(model: model)
            }
        }.padding(.vertical, 8).accessibilityElement(children: .combine)
            .accessibilityHint("Ouvre les réglages de l’agent")
    }

    private func destinationRow(_ entry: AppDestination) -> some View {
        NavigationLink(value: MenuRoute.destination(entry)) {
            MenuLabel(title: entry.title, detail: entry.detail, symbol: entry.symbol)
        }.accessibilityIdentifier("space-\(entry.rawValue)")
    }

    private func agentRow(_ agent: AgentProfile) -> some View {
        let current = agent.name == model.profile
        let unread = model.hasUnread(profile: agent.name)
        let detail = agent.name == "default" ? "Agent principal du serveur" : agent.detail.isEmpty ? "@\(agent.name)" : agent.detail
        return HStack(spacing: 4) {
            Button { open(agent) } label: {
                HStack(spacing: 13) {
                    AgentAvatar(name: agent.name, size: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(agent.title).font(.subheadline.weight(unread ? .semibold : .medium)).foregroundStyle(.primary)
                            if agent.hidden == true { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Masqué") }
                        }
                        Text(detail.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if unread { Circle().fill(AppTheme.accent).frame(width: 7, height: 7).accessibilityHidden(true) }
                    if current { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent).accessibilityHidden(true) }
                }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canSwitch && !current)
                .accessibilityIdentifier("menu-agent-\(agent.name)")
                .accessibilityValue(unread ? "Conversation non lue" : current ? "Agent sélectionné" : "")
            Button { path.append(.agent(agent.name)) } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 16)).foregroundStyle(.secondary).frame(width: 44, height: 44)
            }.buttonStyle(.borderless).accessibilityLabel("Réglages de \(agent.title)")
                .accessibilityIdentifier("menu-agent-settings-\(agent.name)")
        }.swipeActions(edge: .trailing) {
            Button("Réglages", systemImage: "slider.horizontal.3") { path.append(.agent(agent.name)) }.tint(AppTheme.accent)
        }
    }

    // MARK: Search

    @ViewBuilder private var results: some View {
        let destinations = AppDestination.allCases.filter { matches("\($0.title) \($0.detail)") }
        let pages = AgentSettingsPage.allCases.filter { matches("\($0.title) \($0.detail) \($0.keywords)") }
        let found = model.profiles.filter { (showHidden || $0.hidden != true || $0.name == model.profile) && matches("\($0.title) \($0.name) \($0.detail)") }
        let fields = store.map { store in store.keys.filter { SettingsCatalog.matches(query, key: $0, description: store.description($0)) } } ?? []
        if destinations.isEmpty && pages.isEmpty && found.isEmpty && fields.isEmpty {
            if store?.loading == true { SkeletonRows(count: 3, avatar: false) }
            else { ContentUnavailableView.search(text: query) }
        }
        if !destinations.isEmpty || !pages.isEmpty {
            Section("Aller à") {
                ForEach(destinations) { destinationRow($0) }
                ForEach(pages) { page in
                    NavigationLink(value: MenuRoute.agentPage(model.profile, page)) {
                        MenuLabel(title: page.title, detail: "Réglages de \(model.agent?.title ?? "Hermes")", symbol: page.symbol)
                    }.accessibilityIdentifier("space-agent-\(page.rawValue)")
                }
            }
        }
        if !found.isEmpty { Section("Agents") { ForEach(found) { agentRow($0) } } }
        if let store, !fields.isEmpty { SettingsSearchResults(store: store, query: query) }
    }

    private func matches(_ text: String) -> Bool {
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
    }

    // MARK: Routing

    @ViewBuilder private func destination(_ route: MenuRoute) -> some View {
        switch route {
        case .destination(let entry):
            switch entry {
            case .history: SessionsView(model: model)
            case .routines: RoutinesView(model: model)
            case .kanban: KanbanView(app: model)
            case .workspace: WorkspaceView(app: model)
            case .groups:
                if let connection = model.activeConnection { GroupsView(app: model, connectionID: connection.id) }
                else {
                    ContentUnavailableView("Faire équipe", systemImage: "person.2", description: Text("Connectez votre Hermes pour retrouver vos groupes."))
                        .background(AppTheme.background).navigationTitle("Groupes").navigationBarTitleDisplayMode(.inline)
                }
            case .skills: SkillsView(app: model, profile: model.profile)
            case .agents: AgentsHubView(app: model)
            case .connections: ConnectionsView(model: model)
            case .notifications: NotificationsView(connections: model.connections)
            case .about: AboutView(model: model)
            }
        case .agent(let name): AgentSettingsView(app: model, profile: name)
        case .agentPage(let name, let page): AgentSettingsPageHost(app: model, profile: name, page: page)
        case .favorites: FavoriteToolsEditor(savedFavorites: $savedFavorites)
        }
    }

    private func open(_ agent: AgentProfile) {
        close()
        if agent.name != model.profile { Task { await model.openBot(agent) } }
    }

    private func close() { if let returnToChat { returnToChat() } else { dismiss() } }
}

/// The icon tile, title and detail used by every menu row.
struct MenuLabel: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(AppTheme.accent).frame(width: 38, height: 38)
                .background(AppTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 3).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

private enum FavoriteTools {
    static let available: [AppDestination] = [.history, .routines, .kanban, .workspace, .groups, .skills, .agents, .connections]
    static func decode(_ value: String) -> [AppDestination] {
        var seen = Set<AppDestination>()
        return Array(value.split(separator: ",").compactMap { AppDestination(rawValue: String($0)) }
            .filter { available.contains($0) && seen.insert($0).inserted }.prefix(3))
    }
}

private struct FavoriteToolsEditor: View {
    @Binding var savedFavorites: String
    @Environment(\.dismiss) private var dismiss
    private var favorites: [AppDestination] { FavoriteTools.decode(savedFavorites) }

    var body: some View {
        List {
            Section {
                ForEach(FavoriteTools.available) { entry in
                    let selected = favorites.contains(entry)
                    Button {
                        var next = favorites
                        if selected { next.removeAll { $0 == entry } }
                        else if next.count < 3 { next.append(entry) }
                        savedFavorites = next.map(\.rawValue).joined(separator: ",")
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: entry.symbol).frame(width: 24).foregroundStyle(AppTheme.accent)
                            Text(entry.title).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? AppTheme.accent : .secondary)
                        }.frame(minHeight: 44)
                    }.disabled(!selected && favorites.count == 3)
                        .accessibilityValue(selected ? "Ajouté" : "")
                        .accessibilityIdentifier("favorite-option-\(entry.rawValue)")
                }
            } header: { Text("\(favorites.count) sur 3") }
            footer: { Text("Choisissez jusqu’à trois raccourcis. Ils restent en haut du menu, dans l’ordre choisi.").font(.footnote) }
        }.modernList()
            .navigationTitle("Accès rapides").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                AppToolbarItem(placement: .confirmationAction) {
                    Button("Terminé") { dismiss() }.accessibilityIdentifier("close-tool-favorites")
                }
            }
    }
}
