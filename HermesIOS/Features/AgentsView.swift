import SwiftUI

struct QuickProfilePicker: View {
    let model: AppModel
    var manage: () -> Void
    var close: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var sections: [(title: String, agents: [AgentProfile])] {
        let bots = model.visibleBots
        let pinned = bots.filter { $0.pinned == true }
        let recent = bots.filter { $0.pinned != true && model.lastVisited(profile: $0.name) != nil }
            .sorted { (model.lastVisited(profile: $0.name) ?? .distantPast) > (model.lastVisited(profile: $1.name) ?? .distantPast) }
        let others = bots.filter { $0.pinned != true && model.lastVisited(profile: $0.name) == nil }
        return [("Épinglés", pinned), ("Récents", recent), (pinned.isEmpty && recent.isEmpty ? "Vos agents" : "Autres agents", others)]
            .filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Vos agents").font(.system(.title2, design: .serif)).tracking(-0.5)
                Label(model.activeConnection?.name ?? (model.demo ? "Aperçu" : "Hermes"), systemImage: "server.rack")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.top, 25).padding(.bottom, 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 14)
                                ForEach(section.agents) { agent in profileRow(agent).id(agent.name) }
                            }
                        }
                    }.padding(.horizontal, 18)
                }.onAppear { proxy.scrollTo(model.profile, anchor: .center) }
            }
            if !model.demo && model.state != .connected {
                Text("Reconnectez Hermes pour changer d’agent.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24)
            }
            HStack {
                Button(action: manage) {
                    Label("Gérer les agents", systemImage: "person.crop.circle.badge.gearshape")
                        .font(.subheadline.weight(.medium)).frame(minHeight: 46)
                }.accessibilityIdentifier("manage-agents")
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .frame(width: 46, height: 46).background(AppTheme.surface, in: Circle())
                }.accessibilityLabel("Revenir au chat").accessibilityIdentifier("return-to-chat")
            }.buttonStyle(.plain).padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 12)
        }.background(AppTheme.background)
    }

    private func profileRow(_ agent: AgentProfile) -> some View {
        let current = agent.name == model.profile
        let unread = model.hasUnread(profile: agent.name)
        let detail = agent.preview.isEmpty ? (agent.detail.isEmpty ? "@\(agent.name)" : agent.detail) : agent.preview
        return Button {
            close()
            if !current { Task { await model.openBot(agent) } }
        } label: {
            HStack(spacing: 13) {
                AgentAvatar(name: agent.name, size: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.title).font(.subheadline.weight(unread ? .semibold : .medium)).foregroundStyle(.primary)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    Text(detail.replacingOccurrences(of: "\n", with: " "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if unread { Circle().fill(AppTheme.accent).frame(width: 7, height: 7).accessibilityHidden(true) }
                if current { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent).accessibilityHidden(true) }
            }.padding(.horizontal, 14).padding(.vertical, 12)
                .background(current ? AppTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 18))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(model.opening || model.sending || model.voiceActive || (!model.demo && model.state != .connected))
            .accessibilityIdentifier("quick-profile-\(agent.name)")
            .accessibilityValue(unread ? "Conversation non lue" : current ? "Agent sélectionné" : "")
            .accessibilityAddTraits(current ? .isSelected : [])
    }
}

struct AgentsView: View {
    @Bindable var model: AppModel
    var openChat: () -> Void
    @State private var search = ""
    @State private var creating = false
    @State private var editing: AgentProfile?
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vos agents.").font(.system(.largeTitle, design: .serif)).tracking(-0.8)
                        Text("Un talent. Un fil qui continue.").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 14)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                        TextField("Retrouver un agent", text: $search).font(.subheadline)
                    }.padding(.horizontal, 16).frame(height: 46).background(AppTheme.surface, in: Capsule())
                    VStack(spacing: 8) {
                        ForEach(model.profiles.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }) { agent in
                            HStack(spacing: 0) {
                                Button { openChat(); Task { await model.openBot(agent) } } label: {
                                    HStack(spacing: 14) {
                                        AgentAvatar(name: agent.name, size: 44)
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack(spacing: 8) {
                                                Text(agent.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                                                if model.profile == agent.name { Circle().fill(AppTheme.accent).frame(width: 5, height: 5) }
                                            }
                                            Text(agent.detail.isEmpty ? "@\(agent.name)" : agent.detail)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.leading, 14).padding(.vertical, 17).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.opening || model.sending || model.voiceActive || (!model.demo && model.state != .connected))
                                    .accessibilityIdentifier("agent-\(agent.name)")
                                Button { editing = agent } label: {
                                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                                        .frame(width: 44, height: 52)
                                }.buttonStyle(.plain).accessibilityLabel("Modifier \(agent.title)")
                            }.background(agent.name == model.profile ? AppTheme.surface : Color.clear, in: RoundedRectangle(cornerRadius: 20))
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch")
                        Text("Bot Mode · Le même agent, partout.")
                    }.font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 12)
                }.padding(.horizontal, 22).padding(.bottom, 24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.background(AppTheme.background).toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ToolDock {
                        Button { creating = true } label: { Label("Créer un agent", systemImage: "plus").frame(minHeight: 44) }
                            .disabled(model.demo)
                    }
                }
                .sheet(isPresented: $creating) { BotEditor(model: model) }
                .sheet(item: $editing) { BotEditor(model: model, bot: $0) }
        }
    }
}

struct ProfilePicker: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(model.profiles) { agent in
                Button {
                    Task { await model.changeProfile(agent.name); dismiss() }
                } label: {
                    HStack(spacing: 14) {
                        AgentAvatar(name: agent.name)
                        VStack(alignment: .leading, spacing: 4) { Text(agent.title).foregroundStyle(.primary); Text(agent.model).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if model.profile == agent.name { Image(systemName: "checkmark").foregroundStyle(AppTheme.accent) }
                    }.padding(.vertical, 7)
                }
            }.modernList()
                .navigationTitle("Vos profils").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Fermer les profils")
                    }
                }
        }.presentationDetents([.medium, .large])
    }
}

private enum ConversationFilter: String, CaseIterable {
    case conversations, unread, archived
    var title: String {
        switch self {
        case .conversations: "Toutes"
        case .unread: "Non lues"
        case .archived: "Archives"
        }
    }
}

struct SessionsView: View {
    let model: AppModel
    @State private var search = ""
    @State private var remoteRows: [Conversation]?
    @State private var total = 0
    @State private var resultScope = ""
    @State private var filter: ConversationFilter = .conversations
    @State private var renaming: Conversation?
    @State private var renamedTitle = ""
    @State private var loading = false
    @State private var loadError: String?
    @State private var openingID: String?
    @State private var refreshID = UUID()
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.toolNavigation) private var navigation
    @Environment(\.dynamicTypeSize) private var typeSize

    private var archived: Bool { filter == .archived }
    private var queryScope: String { "\(model.attachmentContext)|\(search)|\(archived)" }
    private var loadedRows: [Conversation] {
        (resultScope == queryScope ? (remoteRows ?? []) : (archived ? [] : model.sessions)).filter { $0.profile == model.profile }
    }
    private var conversations: [Conversation] {
        var rows = loadedRows
        // The native roster exposes the hidden Bot Chat omitted from ordinary history.
        if !archived, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let botChat = model.botConversations[model.profile], !rows.contains(where: { $0.id == botChat.id }) {
            rows.append(botChat)
        }
        return rows.sorted { $0.updated > $1.updated }
    }
    private var filtered: [Conversation] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = resultScope == queryScope && remoteRows != nil && !query.isEmpty ? conversations
            : conversations.filter { query.isEmpty || "\($0.title) \($0.preview)".localizedStandardContains(query) }
        return filter == .unread ? searched.filter { model.isUnread($0) } : searched
    }
    private var sections: [(title: String, rows: [Conversation])] {
        let calendar = Calendar.current
        let week = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: Date())) ?? Date()
        let grouped = Dictionary(grouping: filtered) { item -> Int in
            if calendar.isDateInToday(item.updated) { return 0 }
            if calendar.isDateInYesterday(item.updated) { return 1 }
            return item.updated >= week ? 2 : 3
        }
        return ["Aujourd’hui", "Hier", "Les 7 derniers jours", "Plus tôt"].enumerated().compactMap { index, title in
            guard let rows = grouped[index], !rows.isEmpty else { return nil }
            return (title, rows)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Retrouver le fil.").font(.system(.title2, design: .serif)).tracking(-0.6).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            Text("\(model.agent?.title ?? "Hermes") · \(conversations.count) conversation\(conversations.count == 1 ? "" : "s")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        AgentAvatar(name: model.profile, size: 42)
                    }.padding(.top, 12).padding(.bottom, 2)
                    Picker("Historique", selection: $filter) {
                        ForEach(ConversationFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("history-filter")
                    if !model.demo && model.state != .connected {
                        ConnectionIndicator(model: model)
                    }
                    if let loadError, model.state == .connected {
                        HStack(spacing: 12) {
                            Text(loadError).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Réessayer") { Task { await refresh() } }.font(.caption.weight(.medium)).disabled(loading)
                        }.padding(14).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if (loading || (!model.demo && model.state == .connecting)) && conversations.isEmpty {
                        ProgressView("Chargement des conversations…").frame(maxWidth: .infinity).padding(.vertical, 45)
                    } else if conversations.isEmpty {
                        ContentUnavailableView(archived ? "Aucune archive" : "Tout commence ici",
                            systemImage: archived ? "archivebox" : "bubble.left.and.bubble.right",
                            description: Text(archived ? "Les conversations archivées restent disponibles ici." : "Vos échanges avec cet agent apparaîtront ici. Une idée suffit pour commencer."))
                    } else if filtered.isEmpty && filter == .unread && search.isEmpty {
                        ContentUnavailableView("Vous êtes à jour", systemImage: "checkmark.bubble",
                            description: Text("Les conversations avec une nouvelle activité apparaîtront ici."))
                    } else if filtered.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ForEach(sections, id: \.title) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
                                LazyVStack(spacing: 8) {
                                    ForEach(section.rows) { session in conversationRow(session) }
                                }
                            }
                        }
                    }
                    if !model.demo, resultScope == queryScope, search.isEmpty, loadedRows.count < total {
                        Button(loading ? "Chargement…" : "Conversations plus anciennes") { Task { await loadPage(more: true) } }.disabled(loading).frame(minHeight: 44)
                    }
                }.padding(.horizontal, 22).padding(.bottom, 24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
                .background(AppTheme.background)
                .navigationTitle("Conversations").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) { controls }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
                        }.foregroundStyle(.primary).accessibilityLabel("Fermer les conversations").accessibilityIdentifier("return-to-chat")
                    }
                }
                .task(id: "\(model.activeConnection?.id.uuidString ?? "demo")|\(model.profile)|\(model.state == .connected)") {
                    refreshID = UUID(); loading = false; loadError = nil
                    if model.demo || model.state == .connected { await refresh() }
                }
                .task(id: "\(search)|\(archived)") {
                    do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation() } catch { return }
                    await loadPage(more: false)
                }
                .alert("Renommer la conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                    TextField("Titre", text: $renamedTitle)
                    Button("Enregistrer") {
                        guard let row = renaming else { return }; renaming = nil
                        Task { do { try await model.updateConversation(row, patch: ["title": .string(renamedTitle)]); await loadPage(more: false) } catch { loadError = error.localizedDescription } }
                    }
                    Button("Annuler", role: .cancel) { renaming = nil }
                }
        }
    }

    private func conversationRow(_ session: Conversation) -> some View {
        let current = model.selected?.storedID == session.id && model.selected?.profile == session.profile
        let unread = model.isUnread(session)
        let status = model.conversationStatus(session)
        let isBotChat = model.botConversations[session.profile]?.id == session.id
        return Button {
            guard openingID == nil else { return }
            searching = false
            if current && (model.demo || model.state != .connected || model.selected?.runtimeID.isEmpty == false) {
                dismiss(); return
            }
            openingID = session.id
            Task {
                await model.openConversation(session)
                openingID = nil
                if model.selected?.storedID == session.id, model.selected?.profile == session.profile,
                   model.demo || model.state != .connected || model.selected?.runtimeID.isEmpty == false { dismiss() }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: unread ? "bubble.left.fill" : current ? "bubble.left.and.bubble.right.fill" : "bubble.left")
                    .font(.system(size: 15)).foregroundStyle(current || unread ? AppTheme.accent : .secondary)
                    .frame(width: 32, height: 32)
                    .background(current ? AppTheme.accent.opacity(0.08) : AppTheme.background, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.title).font(.system(.subheadline, design: .default, weight: unread ? .semibold : .medium))
                        .foregroundStyle(.primary).lineLimit(typeSize.isAccessibilitySize ? nil : 1).truncationMode(.tail)
                    if !session.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(session.preview.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 2 : 1).truncationMode(.tail)
                    }
                    if let status {
                        Text(status).font(.caption2.weight(.medium)).foregroundStyle(AppTheme.accent)
                    }
                    if typeSize.isAccessibilitySize { conversationDate(session) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 7) {
                    if !typeSize.isAccessibilitySize { conversationDate(session).fixedSize() }
                    if openingID == session.id { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary) }
                }
            }.padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                .background(current ? AppTheme.accent.opacity(0.055) : AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(current ? AppTheme.accent.opacity(0.2) : AppTheme.line.opacity(0.6)))
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).disabled(openingID != nil || model.sending || model.voiceActive)
            .contextMenu {
                // The native canonical title is an identity; edit the bot's display name in Agents.
                if !isBotChat {
                Button("Renommer", systemImage: "pencil") { renamedTitle = session.title; renaming = session }
                Button(archived ? "Restaurer" : "Archiver", systemImage: archived ? "tray.and.arrow.up" : "archivebox") {
                    Task { do { try await model.updateConversation(session, patch: ["archived": .bool(!archived)]); await loadPage(more: false) } catch { loadError = error.localizedDescription } }
                }.disabled(current && model.transcript.running)
                }
            }
            .accessibilityIdentifier("conversation-" + session.id)
            .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func conversationDate(_ session: Conversation) -> some View {
        Text(session.updated, format: Calendar.current.isDateInToday(session.updated) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated))
            .font(.caption2).foregroundStyle(.secondary)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if let navigation {
                Button { searching = false; navigation.showSpaces() } label: {
                    Image(systemName: "circle.grid.2x2").font(.system(size: 18)).frame(width: 44, height: 48)
                }.foregroundStyle(.secondary).accessibilityLabel("Outils").accessibilityIdentifier("back-to-spaces")
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary)
                TextField("Rechercher", text: $search).font(.subheadline).focused($searching).submitLabel(.search)
                    .onSubmit { searching = false }.accessibilityLabel("Rechercher une conversation").accessibilityIdentifier("history-search")
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 28, height: 44) }
                        .accessibilityLabel("Effacer la recherche")
                }
            }.padding(.horizontal, 14).frame(minHeight: 50).background(AppTheme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(AppTheme.line))
            Button { model.newChat(); dismiss() } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .medium))
                    .frame(width: 50, height: 50).foregroundStyle(.white).background(AppTheme.accent, in: Circle())
            }.disabled(model.sending || model.voiceActive).accessibilityLabel("Nouvelle conversation")
        }.buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 12).frame(maxWidth: 720).frame(maxWidth: .infinity)
            .background(AppTheme.background)
    }

    private func refresh() async {
        guard !loading, model.demo || model.state == .connected else { return }
        let attempt = UUID(); refreshID = attempt
        let revision = model.historyRevision
        loading = true; loadError = nil
        defer { if refreshID == attempt { loading = false } }
        do { try await model.refreshSessions(); loading = false; await loadPage(more: false) }
        catch is CancellationError { }
        catch {
            guard refreshID == attempt, model.state == .connected, revision == model.historyRevision else { return }
            let reason = String(error.localizedDescription.prefix(240))
            if let rpc = error as? RPCFailure, rpc.code > 0 || rpc.code == -32601 {
                loadError = "\(reason) (Hermes \(rpc.code))"
            } else { loadError = reason }
        }
    }
    private func loadPage(more: Bool) async {
        guard !model.demo, model.state == .connected else { return }
        let attempt = UUID(); refreshID = attempt
        let scope = model.attachmentContext, query = search, isArchive = archived
        let previous = more ? (remoteRows ?? []) : []
        loading = true; loadError = nil
        defer { if refreshID == attempt { loading = false } }
        do {
            let page = try await model.historyPage(query: query, offset: previous.count, archived: isArchive)
            try Task.checkCancellation()
            guard refreshID == attempt, scope == model.attachmentContext, query == search, isArchive == archived else { return }
            let rows = query.isEmpty ? page["sessions"].array : page["results"].array.filter { $0["archived"].bool == isArchive }
            var known = Set(previous.map(\.id))
            remoteRows = previous + rows.map { Conversation($0, profile: model.profile) }.filter { known.insert($0.id).inserted }
            resultScope = queryScope
            total = query.isEmpty ? page["total"].int : rows.count
        } catch is CancellationError { }
        catch { if refreshID == attempt { loadError = error.localizedDescription } }
    }

}

struct BotEditor: View {
    let model: AppModel
    var bot: AgentProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var detail = ""
    @State private var title = ""
    @State private var pinned = false
    @State private var hidden = false
    @State private var deleting = false
    @State private var soul = ""
    @State private var clone = "default"
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nom du profil (ex. chercheur)", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(bot != nil)
                    TextField("Son rôle, en quelques mots", text: $detail, axis: .vertical).lineLimit(2...4)
                } header: { Text("Identité") } footer: { Text("Ce profil sera disponible dans toutes vos interfaces Hermes.") }
                if bot != nil {
                    Section("Dans Bot Mode") {
                        TextField("Nom affiché", text: $title)
                        Toggle("Épingler cet agent", isOn: $pinned)
                        Toggle("Masquer du sélecteur rapide", isOn: $hidden)
                    }
                }
                if bot == nil {
                    Section("Point de départ") {
                        Picker("Configuration", selection: $clone) {
                            Text("Nouveau profil").tag("")
                            ForEach(model.profiles) { Text("Copier \($0.title)").tag($0.name) }
                        }
                    }
                }
                Section { TextEditor(text: $soul).frame(minHeight: 150) } header: { Text("Personnalité · SOUL.md") } footer: { Text("Sa façon de penser, son ton et ses instructions permanentes.") }
                if let bot, bot.name != "default" {
                    Section { Button("Supprimer cet agent", role: .destructive) { deleting = true }.disabled(busy || model.demo) }
                }
                if let error { Section { Text(error).foregroundStyle(AppTheme.accent) } }
            }.modernList()
                .navigationTitle(bot == nil ? "Un nouvel agent" : "Modifier \(bot!.title)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "En cours…" : "Enregistrer") { save() }.disabled(busy || name.isEmpty || (bot != nil && !loaded) || model.demo)
                    }
                }
                .confirmationDialog("Supprimer définitivement cet agent ?", isPresented: $deleting, titleVisibility: .visible) {
                    Button("Supprimer l’agent et ses données", role: .destructive) {
                        guard let bot else { return }; busy = true
                        Task { do { try await model.deleteBot(bot.name); dismiss() } catch { self.error = error.localizedDescription }; busy = false }
                    }
                } message: { Text("Hermes supprimera ce profil, son historique, ses skills et sa configuration sur le serveur.") }
                .interactiveDismissDisabled(busy)
                .task {
                    if let bot {
                        name = bot.name; detail = bot.detail; title = bot.title; pinned = bot.pinned == true; hidden = bot.hidden == true
                        do { let data = try await model.describeBot(bot.name); soul = data["soul"].string; loaded = true }
                        catch { self.error = error.localizedDescription }
                    } else { loaded = true }
                }
        }
    }
    private func save() {
        busy = true; error = nil
        Task {
            do {
                if bot == nil { try await model.createBot(name: name, description: detail, soul: soul, clone: clone) }
                else {
                    try await model.editBot(name: name, description: detail, soul: soul)
                    try await model.editBotPresentation(name: name, title: title, pinned: pinned, hidden: hidden)
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
