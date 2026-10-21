import SwiftUI

// MARK: Shared model catalog helpers

extension AgentConfigStore {
    var providers: [JSONValue] { modelOptions["providers"].array.filter { !$0["slug"].string.isEmpty } }

    func providerName(_ slug: String) -> String {
        if slug.isEmpty || slug == "auto" { return "auto" }
        let name = providers.first { $0["slug"].string == slug }?["name"].string ?? ""
        return name.isEmpty ? slug : name
    }

    /// "provider · model", or the automatic route that follows the main model.
    func routeSummary(provider: String, model: String, effort: String? = nil, inherits: String? = nil) -> String {
        var text: String
        if provider.isEmpty || provider == "auto" {
            text = inherits.map { "hérite de \($0)" } ?? "auto · utiliser le modèle principal"
        } else {
            text = "\(providerName(provider)) · \(model.isEmpty ? "(par défaut du fournisseur)" : model)"
        }
        if let effort, !effort.isEmpty { text += " · Raisonnement \(SettingsCatalog.optionLabel(effort, key: "auxiliary.reasoning_effort").lowercased())" }
        return text
    }
}

enum ModelPickTarget {
    case main
    case auxiliary(String)
    /// The caller stores the choice itself (fallbacks, MoA, plugin tasks).
    case choose((_ provider: String, _ model: String) -> Void)
}

/// Provider and model selection from `GET /api/model/options`, as the desktop picker.
struct ModelPickerView: View {
    let store: AgentConfigStore
    let title: String
    let target: ModelPickTarget
    var currentProvider = ""
    var currentModel = ""
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var customProvider = ""
    @State private var customModel = ""
    @State private var confirmation: (body: JSONValue, message: String)?
    @State private var working = false
    @Environment(\.dismiss) private var dismiss

    private var results: [(provider: JSONValue, model: String)] {
        store.providers.flatMap { provider in
            provider["models"].array.map(\.displayText)
                .filter { SettingsCatalog.normalized("\($0) \(provider["name"].string)").contains(SettingsCatalog.normalized(search)) }
                .map { (provider, $0) }
        }
    }

    var body: some View {
        List {
            AppSearchSection(text: $search, prompt: "Rechercher un modèle")
            Section {
                Text(footnote).font(.subheadline).foregroundStyle(.secondary)
            }
            SettingsFeedback(store: store)
            if store.modelOptions.isNull && store.error == nil {
                SkeletonRows(count: 5, avatar: false)
            }
            if !search.isEmpty {
                Section("Résultats") {
                    ForEach(Array(results.prefix(150).enumerated()), id: \.offset) { _, result in
                        modelButton(result.provider, result.model, caption: result.provider["name"].string)
                    }
                    if results.isEmpty { Text("Aucun modèle ne correspond.").foregroundStyle(.secondary) }
                }
            } else {
                ForEach(store.providers, id: \.["slug"].string) { provider in
                    let slug = provider["slug"].string
                    Section {
                        DisclosureGroup(isExpanded: Binding(get: { expanded.contains(slug) }, set: { if $0 { expanded.insert(slug) } else { expanded.remove(slug) } })) {
                            let models = provider["models"].array.map(\.displayText)
                            if models.isEmpty {
                                Text("Aucun modèle listé. Configurez ce fournisseur ou saisissez un modèle ci-dessous.").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(models, id: \.self) { modelButton(provider, $0) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider["name"].string.isEmpty ? slug : provider["name"].string).font(.subheadline.weight(.medium))
                                    Text("\(provider["models"].array.count) modèle\(provider["models"].array.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if slug == currentProvider { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.accent).accessibilityLabel("Fournisseur actuel") }
                            }
                        }
                    }
                }
                if !store.modelOptions.isNull && store.providers.isEmpty {
                    ContentUnavailableView("Aucun fournisseur configuré", systemImage: "cpu",
                                           description: Text("Ajoutez un fournisseur dans « Fournisseurs » pour retrouver ses modèles ici."))
                }
                if !store.providers.isEmpty {
                    Section {
                        AppPicker(title: "Fournisseur", selection: $customProvider,
                                  options: store.providers.map { (value: $0["slug"].string, label: $0["name"].string.isEmpty ? $0["slug"].string : $0["name"].string) })
                        TextField("ID du modèle", text: $customModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Utiliser ce modèle") {
                            guard let provider = store.providers.first(where: { $0["slug"].string == customProvider }) else { return }
                            pick(provider, customModel.trimmingCharacters(in: .whitespacesAndNewlines))
                        }.disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty || customProvider.isEmpty || working)
                    } header: { Text("Modèle personnalisé") } footer: { Text("Pour un modèle que le fournisseur ne liste pas encore.") }
                }
            }
        }.modernList().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .task {
                if store.modelOptions.isNull { await store.loadModelOptions() }
                if !currentProvider.isEmpty { expanded.insert(currentProvider) }
                customProvider = currentProvider.isEmpty || currentProvider == "auto" ? store.providers.first?["slug"].string ?? "" : currentProvider
            }
            .refreshable { await store.loadModelOptions(refresh: true) }
            .appAlert("Confirmation de Hermes", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("Confirmer") {
                    guard var body = confirmation?.body.object else { return }
                    body["confirm_expensive_model"] = true; confirmation = nil
                    Task { await assign(.object(body)) }
                }
                Button("Annuler", role: .cancel) { confirmation = nil }
            } message: { Text(confirmation?.message ?? "") }
    }

    private var footnote: String {
        switch target {
        case .main: "S’applique aux nouvelles sessions de \(store.title). Une conversation en cours garde son modèle."
        case .auxiliary: "Cette tâche utilisera ce modèle à la place du modèle principal."
        case .choose: "Choisissez un fournisseur puis un modèle."
        }
    }

    private func modelButton(_ provider: JSONValue, _ model: String, caption: String? = nil) -> some View {
        let selected = provider["slug"].string == currentProvider && model == currentModel
        return Button { pick(provider, model) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model).foregroundStyle(.primary).lineLimit(2)
                    if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(AppTheme.accent) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(working).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func pick(_ provider: JSONValue, _ model: String) {
        guard !model.isEmpty else { return }
        let slug = provider["slug"].string
        var body: [String: JSONValue] = ["provider": .string(slug), "model": .string(model)]
        if !provider["base_url"].string.isEmpty { body["base_url"] = provider["base_url"] }
        switch target {
        case .choose(let handler): handler(slug, model); dismiss()
        case .main: body["scope"] = "main"; Task { await assign(.object(body)) }
        case .auxiliary(let task): body["scope"] = "auxiliary"; body["task"] = .string(task); Task { await assign(.object(body)) }
        }
    }

    private func assign(_ body: JSONValue) async {
        working = true; defer { working = false }
        store.error = nil
        do {
            switch try await store.assignModel(body) {
            case .needsConfirmation(let message): confirmation = (body, message)
            case .done: await store.refreshModels(); dismiss()
            }
        } catch is CancellationError {
        } catch { store.error = error.localizedDescription }
    }
}

// MARK: Main model

struct MainModelSettingsView: View {
    let store: AgentConfigStore
    private static let custom: Set<String> = ["model", "model_context_length", "agent.reasoning_effort", "agent.service_tier"]

    private var model: String { store.modelOptions["model"].string.isEmpty ? store.value("model").string : store.modelOptions["model"].string }
    private var provider: String { store.modelOptions["provider"].string }
    private var capabilities: JSONValue { store.providers.first { $0["slug"].string == provider }?["capabilities"][model] ?? .null }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "shippingbox").font(.title2).foregroundStyle(AppTheme.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.isEmpty ? "Aucun modèle choisi" : model).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if !provider.isEmpty { Text(store.providerName(provider)).font(.caption).foregroundStyle(.secondary) }
                        if store.modelInfo["effective_context_length"].int > 0 {
                            Text("Contexte : \(store.modelInfo["effective_context_length"].int.formatted()) jetons").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.vertical, 6).accessibilityElement(children: .combine)
                NavigationLink {
                    ModelPickerView(store: store, title: "Modèle principal", target: .main, currentProvider: provider, currentModel: model)
                } label: { Label("Changer de modèle", systemImage: "arrow.left.arrow.right") }
                    .accessibilityIdentifier("settings-change-model")
            } footer: { Text("S’applique aux nouvelles sessions de cet agent. Une conversation en cours garde son modèle.") }
            SettingsFeedback(store: store)
            Section("Par défaut") {
                if capabilities["reasoning"] != false { ConfigFieldRow(store: store, key: "agent.reasoning_effort") }
                if store.fields["agent.service_tier"] != nil { ConfigFieldRow(store: store, key: "agent.service_tier") }
            }
            if store.fields["model_context_length"] != nil {
                Section {
                    ConfigFieldRow(store: store, key: "model_context_length")
                } header: { Text("Contexte") } footer: {
                    if store.modelInfo["auto_context_length"].int > 0 {
                        Text("Détecté automatiquement : \(store.modelInfo["auto_context_length"].int.formatted()) jetons.")
                    }
                }
            }
            let others = store.keys(on: "model.main").filter { !Self.custom.contains($0) }
            if !others.isEmpty { Section("Autres réglages") { ConfigFieldRows(store: store, keys: others) } }
        }.modernList().navigationTitle("Modèle principal").navigationBarTitleDisplayMode(.inline)
            .task { await store.loadModelOptions(); await store.loadModelInfo() }
            .refreshable { await store.refreshModels() }
    }
}

// MARK: Fallbacks

struct FallbackModelsView: View {
    let store: AgentConfigStore
    private var routes: [FallbackRoute] { FallbackRoute.parse(store.value("fallback_providers")) }

    var body: some View {
        List {
            Section { Text("Fournisseurs et modèles essayés dans l’ordre si le modèle par défaut échoue.").font(.subheadline).foregroundStyle(.secondary) }
            SettingsFeedback(store: store)
            Section("Ordre d’essai") {
                if routes.isEmpty {
                    Text("Aucun modèle de secours — le modèle par défaut est utilisé sauf en cas d’échec.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(routes.enumerated()), id: \.offset) { index, route in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(minWidth: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(route.model.isEmpty ? "Modèle à choisir" : route.model).font(.subheadline.weight(.medium))
                            Text(store.providerName(route.provider)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine).accessibilityLabel("Secours \(index + 1) : \(route.model), \(store.providerName(route.provider))")
                }
                .onDelete { offsets in write(routes.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)) }
                .onMove { source, destination in
                    var next = routes; next.move(fromOffsets: source, toOffset: destination); write(next)
                }
                NavigationLink {
                    ModelPickerView(store: store, title: "Ajouter un secours", target: .choose { provider, model in
                        guard !routes.contains(where: { $0.provider == provider && $0.model == model }) else { return }
                        write(routes + [FallbackRoute(provider: provider, model: model)])
                    })
                } label: { Label("Ajouter un secours", systemImage: "plus") }
            }
            let others = store.keys(on: "model.fallbacks").filter { $0 != "fallback_providers" }
            if !others.isEmpty { Section("Autres réglages") { ConfigFieldRows(store: store, keys: others) } }
        }.modernList().navigationTitle("Modèles de secours").navigationBarTitleDisplayMode(.inline)
            .toolbar { if !routes.isEmpty { AppToolbarItem(placement: .primaryAction) { EditButton() } } }
            .task { if store.modelOptions.isNull { await store.loadModelOptions() } }
    }

    private func write(_ next: [FallbackRoute]) { Task { await store.save("fallback_providers", FallbackRoute.encode(next)) } }
}

// MARK: Auxiliary tasks

enum AuxiliaryTasks {
    /// `_AUX_TASK_SLOTS` order, then any other block found in the configuration.
    static let builtIn = ["vision", "compression", "skills_hub", "approval", "mcp", "title_generation", "review", "voice_chat",
                          "triage_specifier", "kanban_decomposer", "profile_describer", "curator"]

    static let copy: [String: (label: String, hint: String)] = [
        "vision": ("Vision", "Analyse d’image"), "compression": ("Compression", "Compaction de contexte"),
        "skills_hub": ("Hub de compétences", "Recherche de compétences"), "approval": ("Approbation", "Auto-approbation intelligente"),
        "mcp": ("MCP", "Routage d’outils MCP"), "title_generation": ("Génération de titre", "Titres de session"),
        "review": ("Révision", "Sous-agent de révision /review"), "voice_chat": ("Chat vocal", "Réponses parlées du mode vocal"),
        "triage_specifier": ("Précision du triage", "Détail des spécifications Kanban"), "kanban_decomposer": ("Décomposition Kanban", "Décomposition des tâches"),
        "profile_describer": ("Description de profil", "Descriptions automatiques des profils"), "curator": ("Curateur", "Revue d’utilisation des compétences"),
        "background_review": ("Revue en arrière-plan", "Relecture après les tours"), "goal_judge": ("Juge des objectifs", "Suivi des /goal"),
        "memory_query_rewrite": ("Recherche en mémoire", "Reformulation des requêtes mémoire"), "moa_aggregator": ("Agrégateur MoA", "Mixture of Agents"),
        "moa_reference": ("Références MoA", "Avis des modèles de référence"), "monitor": ("Surveillance", "Suivi des exécutions"),
        "tts_audio_tags": ("Balises audio", "Expressivité de la synthèse vocale")
    ]

    static let voiceChatExplanation = "Quand vous parlez à l’agent (conversation vocale, note vocale), chaque tour parlé peut être confié à un modèle plus rapide que le modèle principal, pour des réponses orales plus réactives. En « auto », le modèle principal répond. Si la conversation est trop longue pour ce modèle, Hermes revient au modèle principal pour ce tour."

    static func label(_ task: String, server: JSONValue = .null) -> String {
        copy[task]?.label ?? (server["label"].string.isEmpty ? task.replacingOccurrences(of: "_", with: " ").capitalized : server["label"].string)
    }
    static func hint(_ task: String, server: JSONValue = .null) -> String { copy[task]?.hint ?? server["hint"].string }
}

struct AuxiliaryModelsView: View {
    let store: AgentConfigStore
    @State private var confirmReset = false

    private var slots: [String] { store.auxiliary["tasks"].array.map { $0["task"].string } }
    private var tasks: [String] {
        let configured = Set(store.keys.filter { $0.hasPrefix("auxiliary.") }.compactMap { key -> String? in
            let parts = key.split(separator: ".")
            return parts.count >= 3 ? String(parts[1]) : nil
        })
        let ordered = slots.isEmpty ? AuxiliaryTasks.builtIn.filter(configured.contains) : slots
        return ordered + configured.subtracting(ordered).sorted()
    }

    var body: some View {
        List {
            Section { Text("Les tâches d’assistance s’exécutent sur le modèle principal par défaut. Attribuez un modèle dédié à toute tâche pour le remplacer.").font(.subheadline).foregroundStyle(.secondary) }
            SettingsFeedback(store: store)
            Section {
                ForEach(tasks, id: \.self) { task in
                    let route = AuxTaskRoute(store: store, task: task)
                    NavigationLink { AuxTaskDetailView(store: store, task: task, isSlot: slots.contains(task)) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AuxiliaryTasks.label(task, server: route.server)).font(.subheadline.weight(.medium))
                            let hint = AuxiliaryTasks.hint(task, server: route.server)
                            if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(.secondary) }
                            Text(route.summary).font(.caption.monospaced()).foregroundStyle(route.pinned ? AppTheme.accent : .secondary).lineLimit(2)
                        }.padding(.vertical, 3)
                    }.accessibilityIdentifier("aux-task-" + task)
                }
            }
            if !slots.isEmpty {
                Section { Button("Tout réinitialiser au principal", role: .destructive) { confirmReset = true } }
            }
        }.modernList().navigationTitle("Modèles auxiliaires").navigationBarTitleDisplayMode(.inline)
            .task {
                await store.loadAuxiliary()
                if store.modelOptions.isNull { await store.loadModelOptions() }
            }
            .refreshable { await store.refreshModels() }
            .appConfirm("Remettre toutes les tâches sur le modèle principal ?", isPresented: $confirmReset) {
                Button("Tout réinitialiser", role: .destructive) {
                    Task {
                        do {
                            _ = try await store.assignModel(["scope": "auxiliary", "task": "__reset__", "provider": "auto", "model": ""])
                            await store.refreshModels()
                        } catch { store.error = error.localizedDescription }
                    }
                }
            }
    }
}

/// Current route of a task: the server row for built-in slots, the configuration otherwise.
@MainActor struct AuxTaskRoute {
    let store: AgentConfigStore
    let task: String
    var server: JSONValue { store.auxiliary["tasks"].array.first { $0["task"].string == task } ?? .null }
    var provider: String { server.isNull ? store.value("auxiliary.\(task).provider").string : server["provider"].string }
    var model: String { server.isNull ? store.value("auxiliary.\(task).model").string : server["model"].string }
    var effort: String { server.isNull ? store.value("auxiliary.\(task).reasoning_effort").string : server["reasoning_effort"].string }
    var pinned: Bool { !(provider.isEmpty || provider == "auto") }
    var summary: String {
        let inherits = server["inherit_from"].string
        if !pinned, !inherits.isEmpty, server["effective"]["provider"].string != "auto", !server["effective"]["provider"].string.isEmpty {
            return "hérite de \(AuxiliaryTasks.label(inherits)) · " + store.routeSummary(provider: server["effective"]["provider"].string, model: server["effective"]["model"].string)
        }
        return store.routeSummary(provider: provider, model: model, effort: effort, inherits: inherits.isEmpty ? nil : AuxiliaryTasks.label(inherits))
    }
}

struct AuxTaskDetailView: View {
    let store: AgentConfigStore
    let task: String
    let isSlot: Bool
    private var route: AuxTaskRoute { AuxTaskRoute(store: store, task: task) }
    private var fieldKeys: [String] {
        store.keys.filter { $0.hasPrefix("auxiliary.\(task).") && !["auxiliary.\(task).provider", "auxiliary.\(task).model"].contains($0) }
            .sorted { ($0.hasSuffix(".reasoning_effort") ? 0 : 1, $0) < ($1.hasSuffix(".reasoning_effort") ? 0 : 1, $1) }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AuxiliaryTasks.hint(task, server: route.server)).font(.subheadline).foregroundStyle(.secondary)
                    if task == "voice_chat" { Text(AuxiliaryTasks.voiceChatExplanation).font(.subheadline).fixedSize(horizontal: false, vertical: true) }
                }
            }
            SettingsFeedback(store: store)
            Section("Modèle utilisé") {
                Text(route.summary).font(.subheadline.monospaced()).foregroundStyle(route.pinned ? AppTheme.accent : .secondary)
                NavigationLink {
                    ModelPickerView(store: store, title: AuxiliaryTasks.label(task), target: isSlot ? .auxiliary(task) : .choose { provider, model in
                        Task { await store.apply(["auxiliary": [task: ["provider": .string(provider), "model": .string(model)]]],
                                                 keys: ["auxiliary.\(task).provider", "auxiliary.\(task).model"]) }
                    }, currentProvider: route.provider, currentModel: route.model)
                } label: { Label("Choisir un modèle", systemImage: "cpu") }
                if route.pinned {
                    Button { Task { await followMain() } } label: { Label("Utiliser le modèle principal (auto)", systemImage: "arrow.uturn.backward") }
                }
            }
            if !fieldKeys.isEmpty { Section("Réglages de la tâche") { ConfigFieldRows(store: store, keys: fieldKeys) } }
        }.modernList().navigationTitle(AuxiliaryTasks.label(task, server: route.server)).navigationBarTitleDisplayMode(.inline)
    }

    private func followMain() async {
        if isSlot {
            do {
                _ = try await store.assignModel(["scope": "auxiliary", "task": .string(task), "provider": "auto", "model": ""])
                await store.refreshModels()
            } catch { store.error = error.localizedDescription }
        } else {
            await store.apply(["auxiliary": [task: ["provider": "auto", "model": ""]]], keys: ["auxiliary.\(task).provider", "auxiliary.\(task).model"])
        }
    }
}

// MARK: Mixture of Agents

struct MoASettingsView: View {
    let store: AgentConfigStore
    @State private var moa: JSONValue = .null
    @State private var naming = false
    @State private var newName = ""
    @State private var working = false
    private static let managed: Set<String> = ["moa.default_preset", "moa.active_preset"]

    private var defaultPreset: String { moa["default_preset"].string }
    private var presetNames: [String] {
        moa["presets"].object.keys.sorted { ($0 == defaultPreset ? 0 : 1, $0) < ($1 == defaultPreset ? 0 : 1, $1) }
    }

    var body: some View {
        List {
            Section { Text("Des préréglages nommés qui apparaissent comme modèles chez le fournisseur Mixture of Agents. L’agrégateur est le modèle actif : il exécute chaque étape et son fournisseur facture presque tout le coût. Les modèles de référence donnent un avis une fois par tour.").font(.subheadline).foregroundStyle(.secondary) }
            SettingsFeedback(store: store)
            if moa.isNull && store.error == nil { SkeletonRows(count: 3, avatar: false) }
            ForEach(presetNames, id: \.self) { name in presetSection(name) }
            if !moa.isNull {
                Section { Button { naming = true } label: { Label("Ajouter un préréglage", systemImage: "plus") }.disabled(working) }
            }
            let options = store.keys(on: "model.moa").filter { !$0.hasPrefix("moa.presets.") && !Self.managed.contains($0) }
            if !options.isEmpty { Section("Options") { ConfigFieldRows(store: store, keys: options) } }
        }.modernList().navigationTitle("Mixture of Agents").navigationBarTitleDisplayMode(.inline)
            .task { await load() }.refreshable { await load() }
            .disabled(working)
            .appAlert("Nouveau préréglage", isPresented: $naming) {
                TextField("Nom", text: $newName).textInputAutocapitalization(.never)
                Button("Ajouter") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines); newName = ""
                    guard !name.isEmpty, moa["presets"][name].isNull else { return }
                    var presets = moa["presets"].object
                    presets[name] = moa["presets"][defaultPreset].isNull ? ["enabled": true, "reference_models": [], "aggregator": ["provider": "", "model": ""]] : moa["presets"][defaultPreset]
                    save(presets: presets)
                }
                Button("Annuler", role: .cancel) { newName = "" }
            } message: { Text("Il reprend les modèles du préréglage par défaut, que vous pourrez ensuite modifier.") }
    }

    @ViewBuilder private func presetSection(_ name: String) -> some View {
        let preset = moa["presets"][name]
        let references = preset["reference_models"].array
        Section {
            Toggle("Activé", isOn: Binding(get: { preset["enabled"] != false }, set: { update(name, ["enabled": .bool($0)]) })).tint(AppTheme.accent)
            NavigationLink {
                ModelPickerView(store: store, title: "Agrégateur", target: .choose { provider, model in
                    var aggregator = preset["aggregator"].object
                    aggregator["provider"] = .string(provider); aggregator["model"] = .string(model)
                    update(name, ["aggregator": .object(aggregator)])
                }, currentProvider: preset["aggregator"]["provider"].string, currentModel: preset["aggregator"]["model"].string)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agrégateur").font(.subheadline.weight(.medium))
                    Text(store.routeSummary(provider: preset["aggregator"]["provider"].string, model: preset["aggregator"]["model"].string)).font(.caption.monospaced()).foregroundStyle(AppTheme.accent)
                    Text("modèle actif · facturé pour l’exécution").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(references.enumerated()), id: \.offset) { index, reference in
                Toggle(isOn: Binding(get: { reference["enabled"] != false }, set: { enabled in
                    var next = references
                    next[index] = AgentConfigStore.merge(reference, ["enabled": .bool(enabled)])
                    update(name, ["reference_models": .array(next)])
                })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Référence \(index + 1)").font(.subheadline.weight(.medium))
                        Text(store.routeSummary(provider: reference["provider"].string, model: reference["model"].string)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }.tint(AppTheme.accent)
            }.onDelete { offsets in
                update(name, ["reference_models": .array(references.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))])
            }
            NavigationLink {
                ModelPickerView(store: store, title: "Modèle de référence", target: .choose { provider, model in
                    update(name, ["reference_models": .array(references + [["provider": .string(provider), "model": .string(model), "enabled": true]])])
                })
            } label: { Label("Ajouter un modèle de référence", systemImage: "plus") }
            if name != defaultPreset {
                Button("Définir par défaut") { save(presets: moa["presets"].object, defaultName: name) }
                Button("Supprimer ce préréglage", role: .destructive) {
                    var presets = moa["presets"].object; presets[name] = nil; save(presets: presets)
                }
            }
        } header: {
            Text(name == defaultPreset ? "\(name) · par défaut" : name)
        }
    }

    private func load() async {
        do { moa = try await store.fetch("/api/model/moa") }
        catch is CancellationError {}
        catch { store.error = error.localizedDescription }
        if store.modelOptions.isNull { await store.loadModelOptions() }
    }

    private func update(_ preset: String, _ changes: [String: JSONValue]) {
        var presets = moa["presets"].object
        presets[preset] = AgentConfigStore.merge(presets[preset] ?? [:], .object(changes))  // arrays replace
        save(presets: presets)
    }

    private func save(presets: [String: JSONValue], defaultName: String? = nil) {
        let target = defaultName ?? (presets[defaultPreset] == nil ? presets.keys.sorted().first ?? "default" : defaultPreset)
        let active = presets[moa["active_preset"].string] == nil ? "" : moa["active_preset"].string
        let body: JSONValue = ["default_preset": .string(target), "active_preset": .string(active), "presets": .object(presets)]
        let previous = moa
        moa = AgentConfigStore.merge(moa, ["default_preset": .string(target), "active_preset": .string(active)])
        moa = .object(moa.object.merging(["presets": .object(presets)]) { $1 })
        guard !store.demo else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let result = try await store.tools.request("/api/model/moa", method: "PUT", body: body)
                if !result["presets"].isNull { moa = result }
            } catch {
                moa = previous; store.error = error.localizedDescription
            }
        }
    }
}
