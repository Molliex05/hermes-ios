import SwiftUI

extension AgentConfigStore {
    /// Short French summary of a value, as shown under a field name.
    func summary(_ key: String, _ value: JSONValue) -> String {
        let kind = kind(key)
        if kind == .secret { return value.string.isEmpty ? "Non défini" : "Défini" }
        switch value {
        case .null: return key == "agent.max_turns" ? "Sans limite" : "Non défini"
        case .bool(let on): return on ? "Activé" : "Désactivé"
        case .array(let values):
            let rules = key == "approvals.deny" || key == "command_allowlist"
            if values.isEmpty { return rules ? "Aucune règle" : "Aucun élément" }
            if case .stringList = kind, values.count <= 3 { return StringListEditing.strings(value).joined(separator: ", ") }
            return rules ? "\(values.count) règle\(values.count == 1 ? "" : "s")" : "\(values.count) élément\(values.count == 1 ? "" : "s")"
        case .object(let values): return values.isEmpty ? "Vide" : "\(values.count) paramètre\(values.count == 1 ? "" : "s")"
        case .number: return value.displayText.replacingOccurrences(of: ".", with: ",")
        case .string(let text):
            if case .choice = kind { return SettingsCatalog.optionLabel(text, key: key) }
            return text.isEmpty ? "Non défini" : text
        }
    }

    func resetValue(_ key: String) -> JSONValue { key == "model_context_length" ? .number(0) : defaultValue(key) ?? .null }

    var confirmationTitle: String { "Appliquer ce réglage à \(title) ?" }

    func confirmationMessage(_ key: String) -> String {
        if key.hasPrefix("approvals.") || key == "command_allowlist" {
            return "Ce choix sera enregistré sur Hermes et pourra modifier les demandes d’autorisation des prochaines actions."
        }
        if key == "toolsets" { return "Les outils retirés ne seront plus disponibles pour cet agent dans ses prochaines sessions." }
        return "Ce réglage touche à la sécurité de l’agent. Il sera enregistré sur Hermes et s’appliquera à ses prochaines actions."
    }
}

/// Confirmation before a safety-sensitive change; plain fields save directly.
struct ChangeRequest: ViewModifier {
    let store: AgentConfigStore
    let key: String
    @Binding var pending: JSONValue?
    var saved: () -> Void = {}
    func body(content: Content) -> some View {
        content.appConfirm(store.confirmationTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Appliquer") {
                guard let value = pending else { return }
                pending = nil
                Task { if await store.save(key, value) { saved() } }
            }
        } message: { Text(store.confirmationMessage(key)) }
    }
}

extension View {
    func changeRequest(_ store: AgentConfigStore, key: String, pending: Binding<JSONValue?>, saved: @escaping () -> Void = {}) -> some View {
        modifier(ChangeRequest(store: store, key: key, pending: pending, saved: saved))
    }
}

@MainActor func submitChange(_ store: AgentConfigStore, key: String, value: JSONValue, pending: Binding<JSONValue?>, saved: @escaping () -> Void = {}) {
    if SettingsCatalog.isSensitive(key) { pending.wrappedValue = value }
    else { Task { if await store.save(key, value) { saved() } } }
}

struct FieldLabel: View {
    let title: String
    var description: String?
    var caption: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            if let description { Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct FieldStatus: View {
    let store: AgentConfigStore
    let key: String
    var body: some View {
        if store.saving.contains(key) {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Enregistrement…") }.font(.caption2).foregroundStyle(.secondary)
        } else if store.isModified(key) {
            Group {
                if store.kind(key) == .secret { Text("Modifié") }
                else { Text("Modifié · par défaut : \(store.summary(key, store.resetValue(key)))") }
            }.font(.caption2).foregroundStyle(AppTheme.accent).lineLimit(2)
        }
    }
}

/// One configuration field with the native control for its type.
struct ConfigFieldRow: View {
    let store: AgentConfigStore
    let key: String
    var caption: String?
    var title: String?
    /// Live options (e.g. the ElevenLabs voices of the account) shown as suggestions.
    var options: [String]?
    var optionLabels: [String: String] = [:]
    @State private var pending: JSONValue?

    private var label: String { title ?? SettingsCatalog.label(key) }
    private var kind: ConfigFieldKind {
        if let options { return .choice(options: options, freeInput: true, searchable: options.count > 12) }
        return store.kind(key)
    }
    private var modified: Bool { store.isModified(key) }

    var body: some View {
        content
            .padding(.vertical, 4)
            .disabled(store.saving.contains(key))
            .swipeActions(edge: .trailing) {
                if modified { Button("Rétablir", systemImage: "arrow.uturn.backward") { reset() }.tint(AppTheme.accent) }
            }
            .changeRequest(store, key: key, pending: $pending)
    }

    private func change(_ value: JSONValue) { submitChange(store, key: key, value: value, pending: $pending) }
    private func reset() { change(store.resetValue(key)) }

    private var header: some View { FieldLabel(title: label, description: store.description(key), caption: caption) }

    @ViewBuilder private var content: some View {
        switch kind {
        case .toggle:
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(get: { store.value(key).bool }, set: { change(.bool($0)) })) { header }
                    .tint(AppTheme.accent).accessibilityIdentifier("configuration-" + key)
                FieldStatus(store: store, key: key)
            }
        case .choice(let base, let freeInput, let searchable):
            let current = store.value(key).displayText
            let all = SettingsCatalog.options(for: key, base: base, current: current, config: store.config)
            if freeInput || searchable || all.count > 12 {
                drillDown { ChoiceEditor(store: store, key: key, options: all, labels: optionLabels, freeInput: freeInput) }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .center, spacing: 8) { header; Spacer(minLength: 8); picker(all, current: current) }
                        VStack(alignment: .leading, spacing: 6) { header; picker(all, current: current) }
                    }
                    FieldStatus(store: store, key: key)
                }.accessibilityIdentifier("configuration-" + key)
            }
        case .number, .loose, .text(long: false):
            InlineValueField(store: store, key: key, header: header, numeric: kind == .number) { change($0) }
        case .text(long: true):
            drillDown { LongTextEditor(store: store, key: key) }
        case .stringList:
            drillDown { StringListEditor(store: store, key: key) }
        case .structured:
            drillDown { JSONFieldEditor(store: store, key: key) }
        case .secret:
            drillDown { SecretFieldEditor(store: store, key: key) }
        }
    }

    private func picker(_ all: [String], current: String) -> some View {
        AppPicker(title: label, selection: Binding(get: { current }, set: { change(.string($0)) }),
                  options: all.map { (value: $0, label: optionLabels[$0] ?? SettingsCatalog.optionLabel($0, key: key)) },
                  showsTitle: false, identifier: "setting-\(key)")
    }

    private func drillDown<Destination: View>(@ViewBuilder _ destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 4) {
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
                Text(label).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(displaySummary).font(.caption).foregroundStyle(AppTheme.accent).lineLimit(2)
                if let description = store.description(key) {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                FieldStatus(store: store, key: key)
            }
        }.accessibilityIdentifier("configuration-" + key)
    }

    private var displaySummary: String {
        let value = store.value(key)
        if let label = optionLabels[value.string] { return label }
        return store.summary(key, value)
    }
}

/// Inline text or number entry, saved when the field is submitted or loses focus.
private struct InlineValueField<Header: View>: View {
    let store: AgentConfigStore
    let key: String
    let header: Header
    let numeric: Bool
    var commit: (JSONValue) -> Void
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    private var current: String {
        let value = store.value(key)
        return value.isNull ? "" : numeric ? value.displayText.replacingOccurrences(of: ".", with: ",") : value.displayText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if numeric {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { header; Spacer(minLength: 8); field.frame(maxWidth: 120) }
                    VStack(alignment: .leading, spacing: 6) { header; field }
                }
            } else {
                header; field
            }
            if invalid { Label("Entrez un nombre valide.", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(AppTheme.accent) }
            FieldStatus(store: store, key: key)
        }
        .onAppear { draft = current }
        .onChange(of: current) { _, value in if !focused { draft = value } }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }

    private var field: some View {
        TextField(numeric ? "0" : "Non défini", text: $draft)
            .keyboardType(numeric ? .numbersAndPunctuation : .default)
            .multilineTextAlignment(numeric ? .trailing : .leading)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .submitLabel(.done).focused($focused).onSubmit(save)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(invalid ? AppTheme.accent : AppTheme.line))
            .accessibilityLabel(SettingsCatalog.label(key))
            .accessibilityIdentifier("configuration-" + key)
    }

    private func save() {
        guard draft != current else { invalid = false; return }
        if numeric {
            guard let number = SettingsCatalog.number(draft) else { invalid = true; return }
            invalid = false; commit(.number(number))
        } else if store.kind(key) == .loose {
            commit(SettingsCatalog.looseValue(draft))
        } else {
            commit(.string(draft))
        }
    }
}

// MARK: Drill-down editors

struct ChoiceEditor: View {
    let store: AgentConfigStore
    let key: String
    let options: [String]
    var labels: [String: String] = [:]
    var freeInput = false
    @State private var search = ""
    @State private var custom = ""
    @State private var pending: JSONValue?

    private var current: String { store.value(key).displayText }
    private var visible: [String] {
        search.isEmpty ? options : options.filter { SettingsCatalog.normalized("\($0) \(name($0))").contains(SettingsCatalog.normalized(search)) }
    }
    private func name(_ option: String) -> String { labels[option] ?? SettingsCatalog.optionLabel(option, key: key) }

    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: "Rechercher")
            if let description = store.description(key) {
                Section { Text(description).font(.subheadline).foregroundStyle(.secondary) }
            }
            SettingsFeedback(store: store)
            Section(freeInput ? "Suggestions" : "Choix") {
                ForEach(visible, id: \.self) { option in
                    Button { change(.string(option)) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(option)).foregroundStyle(.primary)
                                if name(option) != option && !option.isEmpty { Text(option).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if option == current { Image(systemName: "checkmark").foregroundStyle(AppTheme.accent) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(option == current ? .isSelected : [])
                }
            }
            if freeInput {
                Section {
                    TextField("Autre valeur", text: $custom).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit(useCustom)
                    Button("Utiliser cette valeur", action: useCustom).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: { Text("Personnalisé") } footer: { Text("Les identifiants personnalisés sont acceptés (voix clonées, nouveaux modèles).") }
            }
            if store.isModified(key) {
                Section { Button("Rétablir la valeur par défaut") { change(store.resetValue(key)) } }
            }
        }.modernList().navigationTitle(SettingsCatalog.label(key)).navigationBarTitleDisplayMode(.inline)
            .changeRequest(store, key: key, pending: $pending)
    }

    private func useCustom() {
        let value = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        change(.string(value)); custom = ""
    }
    private func change(_ value: JSONValue) { submitChange(store, key: key, value: value, pending: $pending) }
}

struct LongTextEditor: View {
    let store: AgentConfigStore
    let key: String
    @State private var text = ""
    @State private var pending: JSONValue?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).frame(minHeight: 180).accessibilityLabel(SettingsCatalog.label(key))
            } footer: { if let description = store.description(key) { Text(description) } }
            SettingsFeedback(store: store)
            Section {
                Button("Enregistrer") { submitChange(store, key: key, value: .string(text), pending: $pending) { dismiss() } }
                    .disabled(text == store.value(key).string)
                if store.isModified(key) {
                    Button("Rétablir la valeur par défaut") { submitChange(store, key: key, value: store.resetValue(key), pending: $pending) { dismiss() } }
                }
            }
        }.modernList()
            .navigationTitle(SettingsCatalog.label(key)).navigationBarTitleDisplayMode(.inline)
            .task { text = store.value(key).string }
            .changeRequest(store, key: key, pending: $pending) { dismiss() }
    }
}

struct StringListEditor: View {
    let store: AgentConfigStore
    let key: String
    @State private var entry = ""
    @State private var pending: JSONValue?
    @State private var confirmClear = false
    private var items: [String] { StringListEditing.strings(store.value(key)) }

    var body: some View {
        List {
            if let description = store.description(key) {
                Section { Text(description).font(.subheadline).foregroundStyle(.secondary) }
            }
            SettingsFeedback(store: store)
            Section("Ajouter") {
                HStack {
                    TextField("Nouvel élément", text: $entry).textInputAutocapitalization(.never).autocorrectionDisabled().onSubmit(add)
                    Button("Ajouter", systemImage: "plus.circle.fill", action: add).labelStyle(.iconOnly).font(.title3)
                        .foregroundStyle(AppTheme.accent).disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("Ajouter l’élément")
                }
            }
            Section(items.isEmpty ? "Aucun élément" : "\(items.count) élément\(items.count == 1 ? "" : "s")") {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item).font(.subheadline.monospaced()).textSelection(.enabled)
                }
                .onDelete { offsets in write(StringListEditing.removing(at: offsets, from: items)) }
                .onMove { source, destination in write(StringListEditing.moving(from: source, to: destination, in: items)) }
            }
            if store.isModified(key) {
                Section { Button("Rétablir la valeur par défaut") { submitChange(store, key: key, value: store.resetValue(key), pending: $pending) } }
            }
        }.modernList().navigationTitle(SettingsCatalog.label(key)).navigationBarTitleDisplayMode(.inline)
            .toolbar { if !items.isEmpty { AppToolbarItem(placement: .primaryAction) { EditButton() } } }
            .changeRequest(store, key: key, pending: $pending)
            .appConfirm("Retirer tous les ensembles d’outils ?", isPresented: $confirmClear) {
                Button("Tout retirer", role: .destructive) { Task { await store.save(key, []) } }
            } message: { Text("Sans ensemble d’outils, l’agent perd la mémoire, le terminal, la recherche web et la délégation.") }
    }

    private func add() {
        let next = StringListEditing.adding(entry, to: items)
        guard next != items else { return }
        entry = ""; write(next)
    }
    private func write(_ list: [String]) {
        if key == "toolsets", list.isEmpty, !items.isEmpty { confirmClear = true; return }
        submitChange(store, key: key, value: .array(list.map(JSONValue.string)), pending: $pending)
    }
}

struct JSONFieldEditor: View {
    let store: AgentConfigStore
    let key: String
    @State private var text = ""
    @State private var invalid: String?
    @State private var pending: JSONValue?
    @Environment(\.dismiss) private var dismiss
    private var expectsArray: Bool { store.kind(key) == .structured(isArray: true) }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).font(.body.monospaced()).frame(minHeight: 200)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Valeur JSON")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(expectsArray ? "Une liste JSON, entre crochets." : "Un objet JSON, entre accolades.")
                    if let description = store.description(key) { Text(description) }
                }
            }
            if let invalid { Label(invalid, systemImage: "exclamationmark.circle").foregroundStyle(AppTheme.accent) }
            SettingsFeedback(store: store)
            Section {
                Button("Enregistrer", action: save)
                if store.isModified(key) {
                    Button("Rétablir la valeur par défaut") { submitChange(store, key: key, value: store.resetValue(key), pending: $pending) { dismiss() } }
                }
            }
        }.modernList()
            .navigationTitle(SettingsCatalog.label(key)).navigationBarTitleDisplayMode(.inline)
            .task { text = Self.pretty(store.value(key), array: expectsArray) }
            .changeRequest(store, key: key, pending: $pending) { dismiss() }
    }

    static func pretty(_ value: JSONValue, array: Bool) -> String {
        if value.isNull { return array ? "[]" : "{}" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? value.displayText
    }

    private func save() {
        guard let parsed = try? JSONValue.decode(Data(text.utf8)) else { invalid = "Ce JSON n’est pas valide."; return }
        switch (parsed, expectsArray) {
        case (.array, true), (.object, false): invalid = nil
        default: invalid = expectsArray ? "Entrez une liste JSON, entre crochets." : "Entrez un objet JSON, entre accolades."; return
        }
        submitChange(store, key: key, value: parsed, pending: $pending) { dismiss() }
    }
}

/// Credentials are write-only: the current value is never shown nor kept on the phone.
struct SecretFieldEditor: View {
    let store: AgentConfigStore
    let key: String
    @State private var entry = ""
    @State private var confirmClear = false
    @Environment(\.dismiss) private var dismiss
    private var isSet: Bool { !store.value(key).string.isEmpty }

    var body: some View {
        Form {
            Section {
                Label(isSet ? "Une valeur est enregistrée sur le serveur" : "Aucune valeur enregistrée", systemImage: isSet ? "checkmark.seal" : "seal")
                    .foregroundStyle(isSet ? AppTheme.accent : .secondary)
            } footer: { Text("La valeur n’est jamais affichée ni conservée sur cet iPhone. Pour les clés de fournisseurs, préférez « Clés et identifiants ».") }
            Section("Remplacer") {
                SecureField("Nouvelle valeur", text: $entry).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Enregistrer") {
                    let value = entry; entry = ""
                    Task { if await store.save(key, .string(value)) { dismiss() } }
                }.disabled(entry.isEmpty)
            }
            SettingsFeedback(store: store)
            if isSet { Section { Button("Effacer la valeur", role: .destructive) { confirmClear = true } } }
        }.modernList()
            .navigationTitle(SettingsCatalog.label(key)).navigationBarTitleDisplayMode(.inline)
            .onDisappear { entry = "" }
            .appConfirm("Effacer cette valeur sur Hermes ?", isPresented: $confirmClear) {
                Button("Effacer", role: .destructive) { Task { if await store.save(key, "") { dismiss() } } }
            }
    }
}

struct SettingsFeedback: View {
    let store: AgentConfigStore
    /// Pages whose rows are static (catalog links) keep them visible instead of placeholders.
    var placeholders = true
    var body: some View {
        if placeholders && store.loading && !store.loaded {
            SkeletonRows(count: 5, avatar: false)
        }
        if let error = store.error {
            HStack(alignment: .top) {
                Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(AppTheme.accent)
                Spacer(minLength: 4)
                Button { store.error = nil } label: { Image(systemName: "xmark").font(.caption) }.buttonStyle(.plain)
                    .accessibilityLabel("Masquer l’erreur")
            }
        }
        if store.demo {
            Label("Aperçu : les changements ne sont pas envoyés à un serveur.", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
        }
    }
}
