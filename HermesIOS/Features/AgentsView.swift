import SwiftUI

struct AgentsView: View {
    @Bindable var model: AppModel
    var openChat: () -> Void
    @State private var search = ""
    @State private var creating = false
    @State private var editing: AgentProfile?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vos agents.").font(.system(size: 32, design: .serif)).tracking(-0.8)
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
                                                if model.profile == agent.name { Circle().fill(AppTheme.accent).frame(width: 5, height: 5) }
                                            }
                                            Text(agent.detail.isEmpty ? "@\(agent.name)" : agent.detail)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(.leading, 14).padding(.vertical, 17).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.opening).accessibilityIdentifier("agent-\(agent.name)")
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
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Terminé") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }
}

struct SessionsView: View {
    let model: AppModel
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List { Group {
                if model.sessions.isEmpty {
                    ContentUnavailableView("Le début de quelque chose", systemImage: "bubble.left.and.bubble.right", description: Text("Vos conversations avec ce profil apparaîtront ici."))
                }
                ForEach(model.sessions.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { session in
                    Button {
                        Task { await model.openConversation(session); dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(session.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                            HStack { Text(session.profile); Spacer(); Text(session.updated, style: .relative) }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 9)
                    }
                }
            }.listRowBackground(Color.clear)
}.searchable(text: $search, prompt: "Rechercher une conversation")
                .modernList()
                .navigationTitle("Conversations").navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ToolDock {
                        Button { model.newChat(); dismiss() } label: {
                            Label("Nouveau", systemImage: "square.and.pencil").frame(minHeight: 44)
                        }.accessibilityLabel("Nouvelle conversation")
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Terminé") { dismiss() } } }
                .task { try? await model.refreshSessions() }
        }
    }
}

struct BotEditor: View {
    let model: AppModel
    var bot: AgentProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var detail = ""
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
                if bot == nil {
                    Section("Point de départ") {
                        Picker("Configuration", selection: $clone) {
                            Text("Nouveau profil").tag("")
                            ForEach(model.profiles) { Text("Copier \($0.title)").tag($0.name) }
                        }
                    }
                }
                Section { TextEditor(text: $soul).frame(minHeight: 150) } header: { Text("Personnalité · SOUL.md") } footer: { Text("Sa façon de penser, son ton et ses instructions permanentes.") }
                if let error { Section { Text(error).foregroundStyle(AppTheme.accent) } }
            }.modernList()
                .navigationTitle(bot == nil ? "Un nouvel agent" : "Modifier \(bot!.title)").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "En cours…" : "Enregistrer") { save() }.disabled(busy || name.isEmpty || (bot != nil && !loaded) || model.demo)
                    }
                }
                .task {
                    if let bot {
                        name = bot.name; detail = bot.detail
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
                else { try await model.editBot(name: name, description: detail, soul: soul) }
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
