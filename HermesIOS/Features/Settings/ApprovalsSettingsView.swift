import SwiftUI

/// The friendly permissions page: everyday choices first, rules and automation behind "Réglages avancés".
struct ApprovalsSettingsView: View {
    let store: AgentConfigStore
    private static let everyday = ["approvals.timeout", "approvals.cron_mode", "approvals.destructive_slash_confirm", "approvals.mcp_reload_confirm"]
    private var advanced: [String] {
        store.keys(on: "safety.approvals").filter { $0 != "approvals.mode" && !Self.everyday.contains($0) }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    AgentAvatar(name: store.profile, size: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.title).font(.headline)
                        Text(store.serverName).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 5).accessibilityElement(children: .combine)
            } footer: {
                Text("Politique enregistrée pour cet agent. Les exceptions de session et les protections du serveur restent gérées par Hermes.")
            }
            SettingsFeedback(store: store)
            if store.loaded {
                Section("Votre accord") {
                    if store.fields["approvals.mode"] != nil {
                        NavigationLink { ApprovalModeView(store: store) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(SettingsCatalog.label("approvals.mode")).font(.subheadline.weight(.medium))
                                Text(store.summary("approvals.mode", store.value("approvals.mode"))).font(.caption).foregroundStyle(AppTheme.accent)
                                if let effect = approvalEffect(store.value("approvals.mode").string) {
                                    Text(effect).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                FieldStatus(store: store, key: "approvals.mode")
                            }.padding(.vertical, 5)
                        }.accessibilityIdentifier("configuration-approvals.mode")
                    }
                    ConfigFieldRows(store: store, keys: Self.everyday)
                }
                if !advanced.isEmpty {
                    Section {
                        NavigationLink {
                            List {
                                Section { Text("Les mêmes réglages Hermes, pour ajuster les règles et les cas particuliers de \(store.title).").font(.subheadline).foregroundStyle(.secondary) }
                                SettingsFeedback(store: store)
                                Section { ConfigFieldRows(store: store, keys: advanced) }
                            }.modernList().navigationTitle("Réglages avancés").navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Réglages avancés", systemImage: "slider.horizontal.3").font(.subheadline.weight(.medium))
                                Text("Règles permanentes et autres automatisations").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("configuration-advanced")
                    }
                }
            }
        }.modernList().navigationTitle("Permissions").navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.load() }
    }
}

// These describe the native approval modes, not a client-side permission system.
func approvalEffect(_ value: String) -> String? {
    switch value {
    case "manual": "Hermes vous demande avant les actions qui nécessitent une autorisation."
    case "smart": "Hermes évalue les actions sensibles et vous demande quand un accord est nécessaire."
    case "off": "Hermes exécute les actions sans demande d’accord. Les règles d’interdiction du serveur restent applicables."
    default: nil
    }
}

private struct ApprovalModeView: View {
    let store: AgentConfigStore
    @State private var selection = ""
    @State private var confirm = false
    @Environment(\.dismiss) private var dismiss
    private var options: [String] {
        let declared = store.schema("approvals.mode")["options"].array.map(\.displayText)
        return declared.isEmpty ? ["manual", "smart", "off"] : declared
    }
    var body: some View {
        Form {
            Section { Label(store.title, systemImage: "person.crop.circle").font(.subheadline).foregroundStyle(.secondary) }
            Section {
                ForEach(options, id: \.self) { option in
                    Button { selection = option } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(SettingsCatalog.optionLabel(option, key: "approvals.mode")).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                if let effect = approvalEffect(option) { Text(effect).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: selection == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection == option ? AppTheme.accent : .secondary).font(.title3)
                        }.padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(selection == option ? .isSelected : [])
                        .accessibilityIdentifier("approval-mode-" + option)
                }
                if !selection.isEmpty && !options.contains(selection) { Text("Valeur actuelle : \(selection)").font(.caption).foregroundStyle(.secondary) }
            }
            SettingsFeedback(store: store)
            Button("Enregistrer") { confirm = true }
                .disabled(store.saving.contains("approvals.mode") || selection == store.value("approvals.mode").string)
        }.modernList()
            .navigationTitle(SettingsCatalog.label("approvals.mode")).navigationBarTitleDisplayMode(.inline)
            .task { selection = store.value("approvals.mode").string }
            .appConfirm(store.confirmationTitle, isPresented: $confirm) {
                Button("Appliquer") { Task { if await store.save("approvals.mode", .string(selection)) { dismiss() } } }
            } message: { Text(store.confirmationMessage("approvals.mode")) }
    }
}
