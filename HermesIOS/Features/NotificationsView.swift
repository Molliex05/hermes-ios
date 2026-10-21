import SwiftUI

struct NotificationsView: View {
    let connections: [SavedConnection]
    @State private var push = PushNotifications.shared
    var body: some View {
        List {
            Section {
                Label("Retrouvez le bon fil", systemImage: "bell.badge")
                    .font(.headline).padding(.vertical, 6)
                Text("Recevez les réponses et les messages de vos routines, même lorsque l’app est fermée. Touchez une notification pour ouvrir sa conversation.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                ForEach(connections) { connection in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(connection.name, isOn: Binding(get: { push.enabled.contains(connection.id) }, set: { value in
                            Task { await push.setEnabled(value, for: connection) }
                        })).disabled(push.busy.contains(connection.id))
                        if let status = push.statuses[connection.id] {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            } header: { Text("Vos serveurs") } footer: {
                Text("L’aperçu est chiffré de bout en bout : Apple ne voit qu’un avis générique, et seul cet iPhone le déchiffre. Il exige une adresse HTTPS ou Tailscale ; sinon l’avis reste générique. Leur envoi nécessite l’extension Hermès iOS Push sur chaque serveur.")
            }
            Section {
                Button("Réessayer la connexion") { Task { await push.configure(connections) } }
                Button("Réglages des notifications iPhone") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }.modernList().navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
            .task { await push.configure(connections) }
    }
}
