import SwiftUI

/// One catalogue drives discovery and routing; adding a tool never adds another tab.
enum AppDestination: String, Identifiable, CaseIterable {
    case spaces, history, agents, groups, routines, kanban, workspace, skills, models, voice, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spaces: "Espaces"
        case .history: "Conversations"
        case .agents: "Agents"
        case .groups: "Groupes"
        case .routines: "Routines"
        case .kanban: "Kanban"
        case .workspace: "Workspace"
        case .skills: "Skills"
        case .models: "Modèles"
        case .voice: "Voix"
        case .settings: "Réglages"
        }
    }
    var detail: String {
        switch self {
        case .spaces: "Tout votre Hermes"
        case .history: "Retrouver le fil"
        case .agents: "Profils et Bot Mode"
        case .groups: "Faire équipe"
        case .routines: "Planifier · cron jobs"
        case .kanban: "Suivre les tâches"
        case .workspace: "Projets et dossiers"
        case .skills: "Ses compétences"
        case .models: "Choisir son modèle"
        case .voice: "Dicter et écouter"
        case .settings: "Connexions et préférences"
        }
    }
    var symbol: String {
        switch self {
        case .spaces: "square.grid.2x2"
        case .history: "bubble.left.and.bubble.right"
        case .agents: "person.crop.circle"
        case .groups: "person.2"
        case .routines: "clock.arrow.2.circlepath"
        case .kanban: "rectangle.split.3x1"
        case .workspace: "folder"
        case .skills: "sparkles"
        case .models: "cpu"
        case .voice: "waveform"
        case .settings: "slider.horizontal.3"
        }
    }
    var group: String {
        switch self {
        case .history, .agents, .groups, .voice: "Échanger"
        case .routines, .kanban, .workspace: "Organiser"
        default: "Personnaliser"
        }
    }
}

struct SpacesView: View {
    let model: AppModel
    @State private var page: AppDestination?
    @State private var search = ""
    @State private var detent: PresentationDetent
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: AppModel, initial: AppDestination? = nil) {
        self.model = model
        _page = State(initialValue: initial)
        _detent = State(initialValue: initial == nil ? .height(540) : .large)
    }

    var body: some View {
        Group {
            if let page { destination(page) }
            else { launcher }
        }
        .background(AppTheme.background)
        .environment(\.toolNavigation, ToolNavigation(showSpaces: { page = nil }, showChat: { dismiss() }))
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(540), .large], selection: $detent)
        .onChange(of: page) { _, value in searching = false; detent = value == nil ? .height(540) : .large }
        .onChange(of: searching) { _, value in if value { detent = .large } }
    }

    private var entries: [AppDestination] {
        AppDestination.allCases.filter { $0 != .spaces && (search.isEmpty || "\($0.title) \($0.detail)".localizedCaseInsensitiveContains(search)) }
    }

    private var launcher: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("Espaces").font(.system(size: 25, weight: .regular, design: .serif)).tracking(-0.4)
                Spacer()
                Button { model.newChat(); dismiss() } label: {
                    Label("Nouveau chat", systemImage: "square.and.pencil").font(.caption.weight(.medium))
                        .padding(.horizontal, 12).frame(height: 38).background(AppTheme.surface, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("launcher-new-chat")
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if search.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.profiles) { agent in
                                    Button {
                                        dismiss(); Task { await model.openBot(agent) }
                                    } label: {
                                        HStack(spacing: 8) {
                                            AgentAvatar(name: agent.name, size: 26)
                                            Text(agent.title).font(.caption.weight(.medium))
                                            if agent.name == model.profile { Circle().fill(AppTheme.accent).frame(width: 4, height: 4) }
                                        }.padding(.leading, 6).padding(.trailing, 12).frame(height: 40)
                                            .background(agent.name == model.profile ? AppTheme.surface : Color.clear, in: Capsule())
                                            .overlay(Capsule().strokeBorder(AppTheme.line))
                                    }.buttonStyle(.plain).disabled(model.opening)
                                        .accessibilityIdentifier("launcher-agent-\(agent.name)")
                                }
                            }.padding(.horizontal, 24)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(["Échanger", "Organiser", "Personnaliser"], id: \.self) { group in
                            let rows = entries.filter { $0.group == group }
                            if !rows.isEmpty {
                                if group != "Échanger" { Rectangle().fill(AppTheme.line).frame(height: 1).padding(.vertical, 8) }
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 2) {
                                    ForEach(rows) { entry in
                                        Button { page = entry } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: entry.symbol).font(.system(size: 18, weight: .regular))
                                                    .foregroundStyle(.secondary).frame(width: 24)
                                                Text(entry.title).font(.system(.subheadline, design: .rounded).weight(.medium))
                                                    .lineLimit(1).minimumScaleFactor(0.85)
                                                Spacer(minLength: 0)
                                            }.frame(minHeight: 48).contentShape(Rectangle())
                                        }.buttonStyle(.plain).accessibilityIdentifier("space-\(entry.rawValue)")
                                    }
                                }
                            }
                        }
                        if entries.isEmpty { ContentUnavailableView.search(text: search) }
                    }.padding(.horizontal, 26)
                }.padding(.bottom, 12)
            }.scrollDismissesKeyboard(.interactively)
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Rechercher", text: $search).font(.subheadline).focused($searching)
                        .accessibilityIdentifier("spaces-search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("Effacer la recherche")
                    }
                }.padding(.horizontal, 15).frame(height: 46)
                    .background(AppTheme.surface, in: Capsule())
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold))
                        .frame(width: 46, height: 46).background(AppTheme.surface, in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Revenir au chat").accessibilityIdentifier("return-to-chat")
            }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
        }
    }

    @ViewBuilder private func destination(_ page: AppDestination) -> some View {
        switch page {
        case .spaces: launcher
        case .history: SessionsView(model: model)
        case .agents: AgentsView(model: model, openChat: { dismiss() })
        case .routines: RoutinesView(model: model)
        case .settings: SettingsView(model: model).safeAreaInset(edge: .bottom, spacing: 0) { ToolDock() }
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
                }.accessibilityLabel("Espaces").accessibilityIdentifier("back-to-spaces")
            }
            HStack { Spacer(minLength: 0); actions; Spacer(minLength: 0) }
                .font(.subheadline.weight(.medium))
            if let navigation {
                Button(action: navigation.showChat) {
                    Label("Chat", systemImage: "arrow.down.right").font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).frame(height: 44).background(AppTheme.surface, in: Capsule())
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
