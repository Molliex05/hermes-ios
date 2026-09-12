import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var adding = false
    @State private var reconnecting: SavedConnection?
    @State private var removing: SavedConnection?
    @State private var guide = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 17) {
                        AgentMark(size: 48)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Hermès iOS").font(.system(size: 28, weight: .semibold, design: .rounded))
                            Text("Moins de bruit. Plus de conversation.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 14)
                }.listRowBackground(Color.clear)
                Section("Vos connexions") {
                    ForEach(model.connections) { connection in
                        VStack(alignment: .leading, spacing: 9) {
                            Button { Task { await model.activate(connection) } } label: {
                                HStack {
                                    Image(systemName: "server.rack").foregroundStyle(AppTheme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(connection.name).foregroundStyle(.primary)
                                        Text(connection.endpoint.baseURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.activeConnection?.id == connection.id { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                            HStack {
                                Button("Se reconnecter") { reconnecting = connection }.font(.caption)
                                Spacer()
                                Button("Retirer", role: .destructive) { removing = connection }.font(.caption)
                            }.buttonStyle(.borderless)
                        }.padding(.vertical, 5)
                    }
                    Button { adding = true } label: { Label("Connecter un Hermes", systemImage: "plus") }
                }
                Section("Simple, par nature") {
                    Label("Interface native SwiftUI", systemImage: "iphone")
                    Label("Connexion directe à votre serveur", systemImage: "point.3.connected.trianglepath.dotted")
                    Label("Aucun compte Hermès iOS, aucune télémétrie", systemImage: "hand.raised")
                }.font(.subheadline)
                Section {
                    Button { guide = true } label: { Label("Guide Tailscale & Hermes", systemImage: "book") }
                    Link(destination: URL(string: "https://github.com/Molliex05/hermes-ios")!) { Label("Code source", systemImage: "chevron.left.forwardslash.chevron.right") }
                    Link(destination: URL(string: "https://hermes-agent.nousresearch.com/docs/")!) { Label("Documentation Hermes", systemImage: "arrow.up.right.square") }
                    HStack { Text("Version"); Spacer(); Text("0.1.0").foregroundStyle(.secondary) }
                } footer: {
                    Text("Hermès iOS est un client communautaire indépendant pour Hermes Agent de Nous Research. Les conversations sont mises en cache sur cet appareil. Retirer une connexion efface son cache local, sans toucher au serveur.")
                }
                if model.demo {
                    Section { Button("Quitter l’aperçu") { model.demo = false; model.selected = nil; model.profiles = []; model.transcript = Transcript() } }
                }
            }.scrollContentBackground(.hidden).background(AppTheme.background).navigationTitle("À votre façon")
                .sheet(isPresented: $adding) { OnboardingView(model: model, adding: true) }
                .sheet(item: $reconnecting) { OnboardingView(model: model, adding: true, existing: $0) }
                .sheet(isPresented: $guide) { ConnectionGuide() }
                .confirmationDialog("Retirer cette connexion et son cache de cet iPhone ?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                    Button("Retirer de cet iPhone", role: .destructive) {
                        if let connection = removing { Task { await model.removeConnection(connection) } }
                        removing = nil
                    }
                }
        }
    }
}
