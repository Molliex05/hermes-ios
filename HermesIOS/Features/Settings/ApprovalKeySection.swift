import SwiftUI

/// « Courriels Noriven » — the iPhone's key for approving the sends of Noriven drafts. Created here, copied into Noriven's
/// Dashboard by Maxime (who checks the short code there), replaced if Face ID changed.
struct ApprovalKeySection: View {
    @State private var key = ApprovalKey.current
    @State private var problem: String?
    @State private var copied = false
    @State private var replacing = false

    var body: some View {
        Section {
            if let key {
                HStack {
                    Label("Code de la clé", systemImage: "key.horizontal")
                    Spacer()
                    Text(key.shortCode).font(.body.monospaced()).foregroundStyle(.secondary).accessibilityLabel(key.shortCode.map(String.init).joined(separator: " "))
                }
                Button {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": key.spki]], options: [.expirationDate: Date().addingTimeInterval(300)])
                    Haptics.done(); copied = true
                } label: { Label(copied ? "Clé publique copiée" : "Copier la clé publique", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Button("Remplacer la clé", role: .destructive) { replacing = true }
            } else {
                Button { make() } label: { Label("Créer la clé d’approbation", systemImage: "key.horizontal") }
            }
            if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
        } header: { Text("Courriels Noriven") } footer: {
            Text("Les brouillons qu’Hermès prépare dans les boîtes Noriven ne partent qu’avec une signature de cet iPhone, faite par Face ID. Copie la clé publique dans le Dashboard Noriven › Courriels › Clés d’approbation et vérifie que le code affiché est le même. La clé privée ne quitte jamais cet iPhone.").font(.footnote)
        }
        .appConfirm("Remplacer la clé ? L’ancienne cesse de fonctionner : il faudra ajouter la nouvelle au Dashboard.", isPresented: $replacing) {
            Button("Remplacer", role: .destructive) { make() }
        }
    }

    private func make() {
        do { key = try ApprovalKey.create(); problem = nil; copied = false }
        catch { problem = error.localizedDescription }
    }
}
