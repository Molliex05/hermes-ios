import SwiftUI

struct AgentsView: View {
    @Bindable var model: AppModel
    var openChat: () -> Void
    @State private var search = ""
    @State private var creating = false
    @State private var editing: AgentProfile?
    @State private var routines = false
    @State private var groups = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    HStack {
                        Text("VOTRE PETIT MONDE").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                        Spacer()
                        RoundButton(symbol: "plus", label: "Créer un agent") { creating = true }
                    }
                    VStack(alignment: .leading, spacing: 11) {
                        Text("À chacun\nson talent.").font(.system(size: 40, weight: .regular, design: .serif)).tracking(-1.3)
                        Text("Vos profils Hermes. Une conversation\nqui continue avec chacun.").font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                    }
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Retrouver un agent", text: $search) }
                        .padding(14).background(IrisTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                    VStack(spacing: 12) {
                        ForEach(model.profiles.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }) { agent in
                            Button {
                                openChat()
                                Task { await model.openBot(agent) }
                            } label: {
                                VStack(alignment: .leading, spacing: 19) {
                                    HStack(alignment: .top, spacing: 15) {
                                        AgentAvatar(name: agent.name, size: 54)
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(agent.title).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
                                            Text(agent.detail.isEmpty ? "Prêt à réfléchir avec vous." : agent.detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right").font(.subheadline).foregroundStyle(.tertiary)
                                    }
                                    HStack {
                                        Text("@\(agent.name)").font(.caption).foregroundStyle(IrisTheme.color(agent.name))
                                            .padding(.horizontal, 10).padding(.vertical, 5).background(IrisTheme.color(agent.name).opacity(0.08), in: Capsule())
                                        Spacer()
                                        Text(agent.preview.isEmpty ? "\(agent.skillCount) compétences" : agent.preview).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                }.irisCard()
                            }.buttonStyle(.plain).disabled(model.opening)
                                .contextMenu {
                                    Button("Modifier le profil", systemImage: "slider.horizontal.3") { editing = agent }
                                }
                        }
                    }
                    Button { routines = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock.arrow.2.circlepath").font(.title2).foregroundStyle(IrisTheme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Les petites habitudes").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                Text("Routines de \(model.agent?.title ?? "Hermes")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(20).background(IrisTheme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain)
                    Button { groups = true } label: {
                        Label("Réfléchir à plusieurs", systemImage: "person.2.bubble").font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(18)
                            .background(IrisTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    }.disabled(model.demo)
                    Label("Les mêmes agents que sur votre ordinateur.", systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.bottom, 16)
                }.padding(24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }.background(IrisTheme.background).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $creating) { BotEditor(model: model) }
                .sheet(item: $editing) { BotEditor(model: model, bot: $0) }
                .sheet(isPresented: $routines) { RoutinesView(model: model) }
                .sheet(isPresented: $groups) {
                    if let connection = model.activeConnection { GroupsView(app: model, connectionID: connection.id) }
                }
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
                        if model.profile == agent.name { Image(systemName: "checkmark").foregroundStyle(IrisTheme.accent) }
                    }.padding(.vertical, 7)
                }
            }.scrollContentBackground(.hidden).background(IrisTheme.background)
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
            List {
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
            }.searchable(text: $search, prompt: "Rechercher une conversation")
                .scrollContentBackground(.hidden).background(IrisTheme.background)
                .navigationTitle("Le fil des idées").navigationBarTitleDisplayMode(.inline)
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
                if let error { Section { Text(error).foregroundStyle(IrisTheme.accent) } }
            }.scrollContentBackground(.hidden).background(IrisTheme.background)
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
