import SwiftUI

/// Rows of several fields, skipping keys the server does not expose.
struct ConfigFieldRows: View {
    let store: AgentConfigStore
    let keys: [String]
    var body: some View {
        ForEach(keys.filter { store.fields[$0] != nil }, id: \.self) { key in
            ConfigFieldRow(store: store, key: key)
        }
    }
}

/// A generic settings page: every field the catalog assigns to it.
struct ConfigPageView: View {
    let store: AgentConfigStore
    let pageID: String
    var excluded: Set<String> = []

    private var page: SettingsPage? { SettingsCatalog.page(id: pageID) }
    private var keys: [String] { store.keys(on: pageID).filter { !excluded.contains($0) } }

    var body: some View {
        List {
            if let summary = page?.summary { Section { Text(summary).font(.subheadline).foregroundStyle(.secondary) } }
            SettingsFeedback(store: store)
            if store.loaded && keys.isEmpty {
                ContentUnavailableView("Aucun réglage", systemImage: "slider.horizontal.3",
                                       description: Text("Ce serveur Hermes n’expose aucun réglage pour cette page."))
            }
            Section { ConfigFieldRows(store: store, keys: keys) }
        }.modernList().navigationTitle(page?.title ?? "Réglages").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.load() }
    }
}

/// Pages of one section, as the desktop sub-navigation.
struct SettingsSectionView: View {
    let store: AgentConfigStore
    let section: SettingsSection
    var body: some View {
        List {
            Section { Text("Réglages de \(store.title) enregistrés sur son serveur Hermes.").font(.subheadline).foregroundStyle(.secondary) }
            SettingsFeedback(store: store, placeholders: false)
            Section {
                ForEach(section.pages) { page in
                    NavigationLink { SettingsDestination(store: store, pageID: page.id) } label: {
                        SettingsLinkLabel(title: page.title, detail: detail(page), symbol: page.symbol)
                    }.accessibilityIdentifier("settings-page-" + page.id)
                }
                if section.id == "memory" {
                    NavigationLink { AgentMemoryFilesView(app: store.app, profile: store.profile) } label: {
                        SettingsLinkLabel(title: "Fichiers de mémoire", detail: "Ce qu’il retient et ce qu’il sait de vous", symbol: "doc.text")
                    }
                }
            }
        }.modernList().navigationTitle(section.title).navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ page: SettingsPage) -> String {
        let modified = store.keys(on: page.id).filter(store.isModified).count
        return modified == 0 ? page.summary : "\(page.summary) · \(modified) modifié\(modified == 1 ? "" : "s")"
    }
}

/// Routes a page to its dedicated view (model, approvals, voice) or the generic one.
struct SettingsDestination: View {
    let store: AgentConfigStore
    let pageID: String
    var body: some View {
        switch pageID {
        case "model.main": MainModelSettingsView(store: store)
        case "model.fallbacks": FallbackModelsView(store: store)
        case "model.auxiliary": AuxiliaryModelsView(store: store)
        case "model.moa": MoASettingsView(store: store)
        case "safety.approvals": ApprovalsSettingsView(store: store)
        case "voice.conversation": VoiceConversationSettingsView(store: store)
        case "voice.transcription": TranscriptionSettingsView(store: store)
        case "voice.speech": SpeechSettingsView(store: store)
        default: ConfigPageView(store: store, pageID: pageID)
        }
    }
}

/// Every field no page claims, so nothing Hermes exposes is out of reach.
struct OtherSettingsView: View {
    let store: AgentConfigStore
    var body: some View {
        List {
            Section { Text("Les autres réglages de Hermes, regroupés par domaine.").font(.subheadline).foregroundStyle(.secondary) }
            SettingsFeedback(store: store)
            Section {
                ForEach(SettingsCatalog.otherGroups(store.keys), id: \.id) { group in
                    NavigationLink {
                        List {
                            SettingsFeedback(store: store)
                            Section { ConfigFieldRows(store: store, keys: group.keys) }
                        }.modernList().navigationTitle(group.title).navigationBarTitleDisplayMode(.inline)
                    } label: {
                        SettingsLinkLabel(title: group.title, detail: "\(group.keys.count) réglage\(group.keys.count == 1 ? "" : "s")", symbol: "slider.horizontal.3")
                    }
                }
            }
        }.modernList().navigationTitle("Autres réglages").navigationBarTitleDisplayMode(.inline)
    }
}

/// Global search across every field: name, key and description.
struct SettingsSearchResults: View {
    let store: AgentConfigStore
    let query: String
    /// Fields edited by a dedicated control open their page instead.
    private static let pageOnly: [String: String] = ["model": "model.main", "fallback_providers": "model.fallbacks"]

    private var matches: [String] {
        store.keys.filter { SettingsCatalog.matches(query, key: $0, description: store.description($0)) }
    }

    var body: some View {
        let results = matches
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            Section("\(results.count) réglage\(results.count == 1 ? "" : "s")") {
                ForEach(results.prefix(120), id: \.self) { key in
                    if let pageID = Self.pageID(key) {
                        NavigationLink { SettingsDestination(store: store, pageID: pageID) } label: {
                            FieldLabel(title: SettingsCatalog.label(key), description: store.summary(key, store.value(key)), caption: SettingsCatalog.location(of: key))
                        }
                    } else {
                        ConfigFieldRow(store: store, key: key, caption: SettingsCatalog.location(of: key))
                    }
                }
                if results.count > 120 { Text("Précisez la recherche pour voir les autres réglages.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private static func pageID(_ key: String) -> String? {
        if let page = pageOnly[key] { return page }
        if key.hasPrefix("moa.presets.") || key == "moa.default_preset" || key == "moa.active_preset" { return "model.moa" }
        let parts = key.split(separator: ".")
        if parts.count == 3, parts[0] == "auxiliary", ["provider", "model"].contains(parts[2]) { return "model.auxiliary" }
        return nil
    }
}

struct SettingsLinkLabel: View {
    let title: String
    let detail: String
    let symbol: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(AppTheme.accent).frame(width: 26).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 5).accessibilityElement(children: .combine)
    }
}

/// MEMORY.md and USER.md of one agent, pinned to that profile.
struct AgentMemoryFilesView: View {
    @State private var tools: NativeToolSession
    @State private var home = ""
    init(app: AppModel, profile: String) { _tools = State(initialValue: NativeToolSession(app, profile: profile)) }
    var body: some View {
        List {
            Text("Ce que votre agent retient au fil des échanges.").foregroundStyle(.secondary)
            ToolFeedback(tools: tools)
            if tools.app.demo {
                Text("Connectez votre Hermes pour lire et modifier ces fichiers.").font(.subheadline).foregroundStyle(.secondary)
            }
            if !home.isEmpty {
                NavigationLink("Mémoire de l’agent") { RemoteTextEditor(tools: tools, path: home + "/memories/MEMORY.md", title: "Mémoire") }
                NavigationLink("Ce qu’il sait de vous") { RemoteTextEditor(tools: tools, path: home + "/memories/USER.md", title: "À propos de vous") }
            }
        }.modernList().navigationTitle("Fichiers de mémoire").navigationBarTitleDisplayMode(.inline).task {
            guard !tools.app.demo else { return }
            await tools.perform {
                let profiles = try await tools.request("/api/profiles")["profiles"].array
                guard let found = profiles.first(where: { $0["name"].string == tools.profile }), !found["path"].string.isEmpty else { throw RPCFailure("Hermes n’a pas indiqué le dossier de ce profil.") }
                home = found["path"].string
            }
        }
    }
}
