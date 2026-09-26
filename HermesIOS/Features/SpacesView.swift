import SwiftUI

/// One catalogue drives discovery and routing; adding a tool never adds another tab.
enum AppDestination: String, Identifiable, CaseIterable {
    case spaces, profiles, history, agents, groups, routines, kanban, workspace, skills, models, voice, settings, capabilities
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spaces: "Outils"
        case .profiles: "Changer d’agent"
        case .history: "Conversations"
        case .agents: "Agents"
        case .groups: "Groupes"
        case .routines: "Routines"
        case .kanban: "Kanban"
        case .workspace: "Workspace"
        case .skills: "Skills"
        case .models: "Modèles"
        case .voice: "Voix"
        case .capabilities: "Permissions et outils"
        case .settings: "Réglages"
        }
    }
    var detail: String {
        switch self {
        case .spaces: "Tout votre Hermes"
        case .profiles: "Changer d’agent"
        case .history: "Retrouver le fil"
        case .agents: "Gérer les profils · Bot Mode"
        case .groups: "Faire équipe"
        case .routines: "Automatiser · cron jobs"
        case .kanban: "Suivre les tâches"
        case .workspace: "Projets et dossiers"
        case .skills: "Ses compétences"
        case .models: "Choisir son modèle"
        case .voice: "Parler avec votre agent"
        case .capabilities: "Ce que votre agent peut faire"
        case .settings: "Connexions et préférences"
        }
    }
    var symbol: String {
        switch self {
        case .spaces: "slider.horizontal.3"
        case .profiles: "person.crop.circle"
        case .history: "bubble.left.and.bubble.right"
        case .agents: "person.crop.circle"
        case .groups: "person.2"
        case .routines: "clock.arrow.2.circlepath"
        case .kanban: "rectangle.split.3x1"
        case .workspace: "folder"
        case .skills: "sparkles"
        case .models: "cpu"
        case .voice: "waveform"
        case .capabilities: "hand.raised"
        case .settings: "gearshape"
        }
    }
}

private enum ToolCategory: String, CaseIterable {
    case work, agent, all
    var title: String {
        switch self {
        case .work: "Travail"
        case .agent: "Agent"
        case .all: "Tout"
        }
    }
    var destinations: [AppDestination] {
        switch self {
        case .work: [.kanban, .routines, .workspace]
        case .agent: [.capabilities, .skills, .models, .voice, .groups]
        case .all: [.capabilities, .kanban, .routines, .workspace, .skills, .models, .voice, .groups, .agents, .history, .settings]
        }
    }
}

struct SpacesView: View {
    let model: AppModel
    @State private var page: AppDestination?
    @State private var search = ""
    @State private var category: ToolCategory = .work
    @State private var detent: PresentationDetent
    @State private var editingFavorites = false
    @AppStorage("hermes.favoriteTools") private var savedFavorites = "routines,workspace,skills"
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: AppModel, initial: AppDestination? = nil) {
        self.model = model
        _page = State(initialValue: initial)
        _detent = State(initialValue: initial == .profiles ? .height(460) : initial == nil ? .height(560) : .large)
    }

    var body: some View {
        Group {
            if let page { destination(page) }
            else { launcher }
        }
        .background(AppTheme.background)
        .environment(\.toolNavigation, ToolNavigation(showSpaces: { page = nil }, showChat: { dismiss() }))
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [compactDetent, .large], selection: $detent)
        .onChange(of: page) { _, value in searching = false; detent = value == nil || value == .profiles ? compactDetent : .large }
        .onChange(of: searching) { _, value in if value { detent = .large } }
        .onChange(of: typeSize) { _, _ in detent = page == nil || page == .profiles ? compactDetent : .large }
        .onAppear { if typeSize.isAccessibilitySize { detent = .large } }
        .sheet(isPresented: $editingFavorites) { FavoriteToolsEditor(savedFavorites: $savedFavorites) }
    }

    private var compactDetent: PresentationDetent { typeSize.isAccessibilitySize ? .large : .height(page == .profiles ? 460 : 560) }

    private var entries: [AppDestination] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (query.isEmpty ? category.destinations : ToolCategory.all.destinations)
            .filter { query.isEmpty || "\($0.title) \($0.detail)".localizedStandardContains(query) }
    }

    private var favorites: [AppDestination] { FavoriteTools.decode(savedFavorites) }

    private var launcher: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Outils").font(.system(.title2, design: .serif)).tracking(-0.4)
                    Text("Pour \(model.agent?.title ?? "Hermes")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { page = .settings } label: {
                    Image(systemName: "gearshape").font(.system(size: 18))
                        .frame(width: 44, height: 44).background(AppTheme.surface, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Réglages").accessibilityIdentifier("quick-settings")
            }.padding(.horizontal, 24).padding(.top, 25).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 0) {
                    if search.isEmpty { favoriteShortcuts }
                    catalogFilter
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in toolRow(entry) }
                        if entries.isEmpty { ContentUnavailableView.search(text: search) }
                    }.padding(.horizontal, 26).padding(.bottom, 8)
                }
            }.scrollDismissesKeyboard(.interactively)
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Chercher un outil", text: $search).font(.subheadline).focused($searching)
                        .accessibilityIdentifier("spaces-search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                            .accessibilityLabel("Effacer la recherche")
                    }
                }.padding(.horizontal, 15).frame(minHeight: 46).background(AppTheme.surface, in: Capsule())
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .frame(width: 46, height: 46).background(AppTheme.surface, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Revenir au chat").accessibilityIdentifier("return-to-chat")
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        }
    }

    private var catalogFilter: some View {
        HStack(spacing: 4) {
            ForEach(ToolCategory.allCases, id: \.self) { item in
                Button { search = ""; searching = false; category = item } label: {
                    Text(item.title).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).frame(minHeight: 44)
                        .foregroundStyle(category == item ? Color.primary : .secondary)
                        .background(category == item ? AppTheme.surface : Color.clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("tools-filter-" + item.rawValue)
                    .accessibilityAddTraits(category == item ? .isSelected : [])
            }
        }.padding(3).background(AppTheme.line.opacity(0.5), in: Capsule()).padding(.horizontal, 22).padding(.bottom, 10)
    }

    private func toolRow(_ entry: AppDestination) -> some View {
        Button { page = entry } label: {
            HStack(spacing: 14) {
                Image(systemName: entry.symbol).font(.system(size: 19, weight: .regular))
                    .foregroundStyle(AppTheme.accent).frame(width: 40, height: 40)
                    .background(AppTheme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("space-\(entry.rawValue)")
    }

    private var favoriteShortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Accès rapides").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button(favorites.isEmpty ? "Ajouter" : "Modifier") { searching = false; editingFavorites = true }
                    .font(.caption.weight(.medium)).foregroundStyle(AppTheme.accent).frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Modifier les accès rapides").accessibilityIdentifier("edit-tool-favorites")
            }
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                ForEach(favorites) { entry in
                    Button { page = entry } label: {
                        VStack(spacing: 9) {
                            Image(systemName: entry.symbol).font(.system(size: 20)).foregroundStyle(AppTheme.accent)
                            Text(entry.title).font(.caption.weight(.medium)).foregroundStyle(.primary)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, minHeight: 75).padding(.horizontal, 5).padding(.vertical, 8)
                            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 17))
                    }.buttonStyle(.plain).accessibilityIdentifier("favorite-tool-\(entry.rawValue)")
                }
            }
        }.padding(.horizontal, 24).padding(.bottom, 12)
    }

    @ViewBuilder private func destination(_ page: AppDestination) -> some View {
        switch page {
        case .spaces: launcher
        case .profiles: QuickProfilePicker(model: model, manage: { self.page = .agents }, close: { dismiss() })
        case .history: SessionsView(model: model)
        case .agents: AgentsView(model: model, openChat: { dismiss() })
        case .routines: RoutinesView(model: model)
        case .settings: SettingsView(model: model).safeAreaInset(edge: .bottom, spacing: 0) { ToolDock() }
        case .capabilities: AgentSettingsView(app: model).safeAreaInset(edge: .bottom, spacing: 0) { ToolDock() }
        case .skills: SkillsView(app: model).safeAreaInset(edge: .bottom, spacing: 0) { ToolDock() }
        case .models: ModelsView(app: model).safeAreaInset(edge: .bottom, spacing: 0) { ToolDock() }
        case .workspace: WorkspaceView(app: model).safeAreaInset(edge: .bottom, spacing: 0) { ToolDock() }
        case .kanban: KanbanView(app: model)
        case .voice: VoiceView(app: model, returnToChat: { dismiss() })
        case .groups:
            Group {
                if let connection = model.activeConnection { GroupsView(app: model, connectionID: connection.id) }
                else { ContentUnavailableView("Faire équipe", systemImage: "person.2", description: Text("Connectez votre Hermes pour retrouver vos groupes.")) }
            }.safeAreaInset(edge: .bottom, spacing: 0) { ToolDock() }
        }
    }
}

private enum FavoriteTools {
    static let available = ToolCategory.all.destinations
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
        NavigationStack {
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
                footer: { Text("Choisissez jusqu’à trois outils. Ils restent à la même place, dans l’ordre choisi.") }
            }.modernList()
                .navigationTitle("Accès rapides").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Fermer les accès rapides").accessibilityIdentifier("close-tool-favorites")
                    }
                }
        }.presentationDetents([.large])
    }
}

@MainActor final class ToolNavigation {
    let showSpaces: () -> Void
    let showChat: () -> Void
    init(showSpaces: @escaping () -> Void, showChat: @escaping () -> Void) {
        self.showSpaces = showSpaces; self.showChat = showChat
    }
}

private struct ToolNavigationKey: EnvironmentKey {
    static let defaultValue: ToolNavigation? = nil
}
extension EnvironmentValues {
    var toolNavigation: ToolNavigation? {
        get { self[ToolNavigationKey.self] }
        set { self[ToolNavigationKey.self] = newValue }
    }
}

/// Navigation and each screen's primary action share one compact row.
struct ToolDock<Actions: View>: View {
    @Environment(\.toolNavigation) private var navigation
    private let actions: Actions
    init(@ViewBuilder actions: () -> Actions) { self.actions = actions() }
    var body: some View {
        HStack(spacing: 12) {
            if let navigation {
                Button(action: navigation.showSpaces) {
                    Image(systemName: "circle.grid.2x2").font(.system(size: 19))
                        .frame(width: 44, height: 44).background(AppTheme.surface, in: Circle())
                }.accessibilityLabel("Outils").accessibilityIdentifier("back-to-spaces")
            }
            HStack { Spacer(minLength: 0); actions; Spacer(minLength: 0) }
                .font(.subheadline.weight(.medium))
            if let navigation {
                Button(action: navigation.showChat) {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44).background(AppTheme.surface, in: Circle())
                }.accessibilityLabel("Revenir au chat").accessibilityIdentifier("return-to-chat")
            }
        }.buttonStyle(.plain).foregroundStyle(.primary)
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
            .background(AppTheme.background)
    }
}
extension ToolDock where Actions == EmptyView {
    init() { self.init { EmptyView() } }
}
