import Foundation

/// One settings page: the same field grouping as Hermes Desktop (`config-subpages.ts`),
/// widened with prefixes so every server field lands on a page.
struct SettingsPage: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let fields: [String]
    let prefixes: [String]
}

struct SettingsSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let pages: [SettingsPage]
}

/// How a configuration field is edited on the phone.
enum ConfigFieldKind: Equatable, Sendable {
    case toggle
    /// Closed list, or suggestions for a free-input value (voice and model names).
    case choice(options: [String], freeInput: Bool, searchable: Bool)
    case number
    case text(long: Bool)
    /// Declared without a usable default (`null`): numbers, booleans and text are all accepted.
    case loose
    case stringList
    case structured(isArray: Bool)
    /// Credentials are never displayed; they can only be replaced or cleared.
    case secret
}

/// One `fallback_providers` entry. Extra routing keys (base_url, key_env…) ride along untouched.
struct FallbackRoute: Equatable, Sendable {
    var provider: String
    var model: String
    var extra: [String: JSONValue] = [:]

    init(provider: String, model: String, extra: [String: JSONValue] = [:]) {
        self.provider = provider; self.model = model; self.extra = extra
    }

    var json: JSONValue {
        var object = extra
        object["provider"] = .string(provider); object["model"] = .string(model)
        return .object(object)
    }

    /// Mirrors the desktop editor: objects keep their keys, legacy "provider/model" strings are split.
    static func parse(_ value: JSONValue) -> [FallbackRoute] {
        value.array.compactMap { item in
            switch item {
            case .object(var object):
                let provider = object.removeValue(forKey: "provider")?.string ?? ""
                let model = object.removeValue(forKey: "model")?.string ?? ""
                return FallbackRoute(provider: provider, model: model, extra: object)
            case .string(let text):
                guard let slash = text.firstIndex(of: "/"), slash != text.startIndex else { return FallbackRoute(provider: "", model: text) }
                return FallbackRoute(provider: String(text[..<slash]), model: String(text[text.index(after: slash)...]))
            default: return nil
            }
        }
    }

    static func encode(_ routes: [FallbackRoute]) -> JSONValue {
        .array(routes.filter { !$0.provider.isEmpty && !$0.model.isEmpty }.map(\.json))
    }
}

enum StringListEditing {
    /// Adds a trimmed, non-empty, not-yet-present entry.
    static func adding(_ entry: String, to list: [String]) -> [String] {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !list.contains(value) else { return list }
        return list + [value]
    }
    static func removing(at offsets: IndexSet, from list: [String]) -> [String] {
        list.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }
    static func moving(from source: IndexSet, to destination: Int, in list: [String]) -> [String] {
        let moving = source.sorted().map { list[$0] }
        var rest = list.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertion = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertion, rest.count)))
        return rest
    }
    static func strings(_ value: JSONValue) -> [String] {
        value.array.map { if case .string(let text) = $0 { text } else { $0.displayText } }
    }
}

enum SettingsCatalog {
    // MARK: Pages

    static let sections: [SettingsSection] = [
        SettingsSection(id: "model", title: "Modèle", symbol: "cpu", summary: "Principal, secours, auxiliaires", pages: [
            SettingsPage(id: "model.main", title: "Modèle principal", symbol: "shippingbox", summary: "Fournisseur, raisonnement, vitesse",
                         fields: ["model", "model_context_length", "agent.reasoning_effort", "agent.service_tier", "agent.fast_auto_seconds"], prefixes: ["model."]),
            SettingsPage(id: "model.fallbacks", title: "Modèles de secours", symbol: "arrow.triangle.branch", summary: "Si le modèle principal échoue",
                         fields: ["fallback_providers"], prefixes: ["fallback."]),
            SettingsPage(id: "model.auxiliary", title: "Modèles auxiliaires", symbol: "cpu", summary: "Vision, compression, voix…",
                         fields: [], prefixes: ["auxiliary."]),
            SettingsPage(id: "model.moa", title: "Mixture of Agents", symbol: "person.3", summary: "Préréglages multi-modèles",
                         fields: [], prefixes: ["moa."])
        ]),
        SettingsSection(id: "chat", title: "Conversation", symbol: "bubble.left.and.bubble.right", summary: "Personnalité, fuseau, images", pages: [
            SettingsPage(id: "chat.behavior", title: "Comportement", symbol: "bubble.left", summary: "Personnalité, fuseau horaire, raisonnement",
                         fields: ["display.personality", "timezone", "display.show_reasoning"], prefixes: []),
            SettingsPage(id: "chat.attachments", title: "Pièces jointes", symbol: "photo", summary: "Images envoyées au modèle",
                         fields: ["agent.image_input_mode"], prefixes: ["attachments."])
        ]),
        SettingsSection(id: "workspace", title: "Espace de travail", symbol: "folder", summary: "Projets, shell, fichiers", pages: [
            SettingsPage(id: "workspace.projects", title: "Projets et découverte", symbol: "folder", summary: "Dossier de travail, dépôts",
                         fields: ["terminal.cwd"], prefixes: ["desktop.repo_scan_"]),
            SettingsPage(id: "workspace.shell", title: "Environnement du shell", symbol: "terminal", summary: "Shell persistant, variables",
                         fields: ["terminal.persistent_shell", "terminal.env_passthrough"], prefixes: []),
            SettingsPage(id: "workspace.files", title: "Fichiers et exécution", symbol: "doc.text", summary: "Lecture de fichiers, exécution du code",
                         fields: ["code_execution.mode", "file_read_max_chars", "context_file_max_chars", "context_file_read_timeout"], prefixes: ["code_execution."])
        ]),
        SettingsSection(id: "safety", title: "Sécurité", symbol: "lock.shield", summary: "Approbations, confidentialité", pages: [
            SettingsPage(id: "safety.approvals", title: "Approbations", symbol: "hand.raised", summary: "Quand demander votre accord",
                         fields: ["command_allowlist"], prefixes: ["approvals."]),
            SettingsPage(id: "safety.privacy", title: "Confidentialité et réseau", symbol: "lock", summary: "Secrets, adresses privées, proxy",
                         fields: [], prefixes: ["security.", "privacy.", "proxy.", "auth."]),
            SettingsPage(id: "safety.checkpoints", title: "Points de restauration", symbol: "archivebox", summary: "Instantanés avant modification",
                         fields: [], prefixes: ["checkpoints."])
        ]),
        SettingsSection(id: "browser", title: "Navigateur", symbol: "globe", summary: "Profil, adresses privées", pages: [
            SettingsPage(id: "browser.profile", title: "Profil du navigateur", symbol: "person.crop.circle", summary: "Vos vraies connexions",
                         fields: ["browser.use_real_profile"], prefixes: ["browser.real_profile_"]),
            SettingsPage(id: "browser.network", title: "URL locales et privées", symbol: "network", summary: "Accès au réseau local",
                         fields: ["browser.allow_private_urls", "browser.auto_local_for_private_urls"], prefixes: []),
            SettingsPage(id: "browser.engine", title: "Moteur et délais", symbol: "gearshape", summary: "Backend, délais, extensions",
                         fields: [], prefixes: ["browser."])
        ]),
        SettingsSection(id: "memory", title: "Mémoire", symbol: "brain", summary: "Mémoire persistante, contexte", pages: [
            SettingsPage(id: "memory.persistent", title: "Mémoire persistante", symbol: "brain", summary: "Ce qu’il retient d’une session à l’autre",
                         fields: [], prefixes: ["memory."]),
            SettingsPage(id: "memory.context", title: "Contexte et compression", symbol: "doc.text.magnifyingglass", summary: "Longues conversations",
                         fields: [], prefixes: ["context.", "compression.", "auxiliary.compression."])
        ]),
        SettingsSection(id: "voice", title: "Voix", symbol: "waveform", summary: "Conversation, transcription, synthèse", pages: [
            SettingsPage(id: "voice.conversation", title: "Conversation vocale", symbol: "mic", summary: "Mode, écoute, interruption",
                         fields: ["voice.voice_chat_mode", "voice.max_recording_seconds", "voice.client_direct"], prefixes: ["voice.gpt_live.", "voice."]),
            SettingsPage(id: "voice.transcription", title: "Reconnaissance vocale", symbol: "text.bubble", summary: "Transcrire votre voix",
                         fields: [], prefixes: ["stt."]),
            SettingsPage(id: "voice.speech", title: "Synthèse vocale", symbol: "speaker.wave.2", summary: "La voix de l’agent",
                         fields: ["voice.auto_tts"], prefixes: ["tts."])
        ]),
        SettingsSection(id: "advanced", title: "Avancé", symbol: "wrench.and.screwdriver", summary: "Exécution, outils, terminal", pages: [
            SettingsPage(id: "advanced.runtime", title: "Limites de l’agent", symbol: "cpu", summary: "Étapes, nouveaux essais, délais",
                         fields: ["agent.max_turns", "agent.api_max_retries"], prefixes: ["agent."]),
            SettingsPage(id: "advanced.tools", title: "Accès aux outils", symbol: "wrench", summary: "Ensembles d’outils activés",
                         fields: ["toolsets", "agent.tool_use_enforcement", "agent.disabled_toolsets"], prefixes: ["tools."]),
            SettingsPage(id: "advanced.terminal", title: "Backend du terminal", symbol: "terminal", summary: "Local, Docker, SSH…",
                         fields: [], prefixes: ["terminal."]),
            SettingsPage(id: "advanced.delegation", title: "Sous-agents", symbol: "person.2", summary: "Délégation et parallélisme",
                         fields: [], prefixes: ["delegation."]),
            SettingsPage(id: "advanced.output", title: "Limites de sortie", symbol: "text.alignleft", summary: "Taille des sorties d’outils",
                         fields: [], prefixes: ["tool_output."]),
            SettingsPage(id: "advanced.updates", title: "Mises à jour", symbol: "arrow.down.circle", summary: "Mises à jour de Hermes",
                         fields: [], prefixes: ["updates."])
        ])
    ]

    static let pages: [SettingsPage] = sections.flatMap(\.pages)

    static func page(id: String) -> SettingsPage? { pages.first { $0.id == id } }
    static func section(of pageID: String) -> SettingsSection? { sections.first { $0.pages.contains { $0.id == pageID } } }

    /// Explicit fields win (in section order), then the longest matching prefix.
    static func pageID(for key: String) -> String? {
        if let page = pages.first(where: { $0.fields.contains(key) }) { return page.id }
        var best: (page: String, length: Int)?
        for page in pages {
            for prefix in page.prefixes where key.hasPrefix(prefix) && prefix.count > (best?.length ?? 0) {
                best = (page.id, prefix.count)
            }
        }
        return best?.page
    }

    /// Keys of one page: declared fields first, then the rest alphabetically.
    static func keys(on pageID: String, from all: [String]) -> [String] {
        guard let page = page(id: pageID) else { return [] }
        let mine = Set(all.filter { self.pageID(for: $0) == pageID })
        let declared = page.fields.filter { mine.contains($0) }
        return declared + mine.subtracting(declared).sorted()
    }

    /// Every key no page claims, grouped by its first path component ("Autres réglages").
    static func otherGroups(_ all: [String]) -> [(id: String, title: String, keys: [String])] {
        let unclaimed = all.filter { pageID(for: $0) == nil }
        let grouped = Dictionary(grouping: unclaimed) { $0.contains(".") ? String($0.split(separator: ".")[0]) : "general" }
        return grouped.map { (id: $0.key, title: groupTitle($0.key), keys: $0.value.sorted()) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func groupTitle(_ id: String) -> String {
        groupTitles[id] ?? id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static let groupTitles: [String: String] = [
        "general": "Général", "display": "Affichage", "discord": "Discord", "gateway": "Passerelle", "dashboard": "Tableau de bord web",
        "cron": "Routines", "kanban": "Kanban", "secrets": "Coffres de secrets", "desktop": "Application de bureau",
        "wake_word": "Mot d’activation", "skills": "Compétences", "sessions": "Sessions", "monitoring": "Surveillance",
        "tool_loop_guardrails": "Garde-fous des outils", "lsp": "Serveurs de langage (LSP)", "web": "Recherche web",
        "curator": "Curateur", "computer_use": "Contrôle de l’ordinateur", "bedrock": "AWS Bedrock", "slack": "Slack",
        "plugins": "Extensions", "vault": "Coffre", "telegram": "Telegram", "streaming": "Diffusion en continu",
        "local_runtime": "Exécution locale", "bot_desktop": "Bot de bureau", "x_search": "Recherche X",
        "model_catalog": "Catalogue de modèles", "mattermost": "Mattermost", "loops": "Boucles", "openrouter": "OpenRouter",
        "nous": "Nous Portal", "matrix": "Matrix", "logging": "Journaux", "human_delay": "Délai de frappe simulé",
        "database": "Base de données", "vision": "Vision", "vertex": "Vertex AI", "onboarding": "Prise en main",
        "mcp": "MCP", "bot_mode": "Mode bot", "whatsapp": "WhatsApp", "telemetry": "Télémétrie", "honcho": "Honcho",
        "goals": "Objectifs", "network": "Réseau", "session": "Session", "runtime": "Exécution", "doctor": "Diagnostic",
        "models_dev": "models.dev", "prompt_caching": "Cache des prompts", "connections": "Connexions", "providers": "Fournisseurs"
    ]

    // MARK: Field kinds

    static let secretComponents: Set<String> = ["api_key", "password", "password_hash", "secret", "session_key", "access_key", "secret_key"]

    static func isSecret(_ key: String) -> Bool {
        let last = key.split(separator: ".").last.map(String.init) ?? key
        return secretComponents.contains(last) || last.hasSuffix("_api_key") || last.hasSuffix("_password")
    }

    /// Changes that alter what the agent may do on its own ask for a confirmation first.
    static func isSensitive(_ key: String) -> Bool {
        ["approvals.", "security.", "privacy.", "proxy.", "auth."].contains { key.hasPrefix($0) }
            || ["command_allowlist", "terminal.backend", "toolsets", "code_execution.mode", "browser.use_real_profile",
                "browser.allow_private_urls", "browser.allow_unsafe_evaluate", "delegation.subagent_auto_approve", "hooks_auto_accept"].contains(key)
    }

    static func kind(key: String, schema: JSONValue, value: JSONValue, defaultValue: JSONValue) -> ConfigFieldKind {
        if isSecret(key) { return .secret }
        let type = schema["type"].string
        if type == "boolean" { return .toggle }
        let options = schema["options"].array.map(\.displayText)
        let known = enumOptions[key] ?? (key.hasSuffix(".reasoning_effort") ? [""] + reasoningEfforts : nil)
        if !options.isEmpty || known != nil {
            return .choice(options: options.isEmpty ? known ?? [] : options,
                           freeInput: freeInputKeys.contains(key), searchable: schema["searchable"].bool || options.count > 40)
        }
        switch type {
        case "number": return .number
        case "list":
            if objectListKeys.contains(key) { return .structured(isArray: true) }
            let sample = value.isNull ? defaultValue : value
            return sample.array.allSatisfy { if case .string = $0 { true } else { false } } ? .stringList : .structured(isArray: true)
        case "object": return .structured(isArray: false)
        default:
            if defaultValue.isNull {
                switch value {
                case .bool: return .toggle
                case .number: return .number
                case .array: return .structured(isArray: true)
                case .object: return .structured(isArray: false)
                case .null: return .loose
                case .string: break
                }
            }
            let text = value.string
            return .text(long: type == "text" || longTextKeys.contains(key) || text.count > 80 || text.contains("\n"))
        }
    }

    /// Parses a typed value for a field that has no declared type.
    static func looseValue(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .null }
        if let number = number(trimmed) { return .number(number) }
        switch trimmed.lowercased() {
        case "true", "oui": return .bool(true)
        case "false", "non": return .bool(false)
        default: return .string(text)
        }
    }

    /// Accepts "1,5" as well as "1.5"; rejects non-finite input.
    static func number(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "\u{202F}", with: "").replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty, let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    /// Whether a value differs from the server default (missing defaults never count as modified).
    static func isModified(value: JSONValue, defaultValue: JSONValue?) -> Bool {
        guard let defaultValue else { return false }
        if value.isNull && defaultValue.isNull { return false }
        if case .number(let left) = value, case .number(let right) = defaultValue { return abs(left - right) > 1e-9 }
        return value != defaultValue
    }

    // MARK: Voice providers

    static let sttProviders = ["local", "groq", "openai", "mistral", "xai", "elevenlabs", "deepinfra"]
    static let ttsProviders = ["edge", "elevenlabs", "openai", "neutts", "minimax", "mistral", "gemini", "gemini-voix", "xai", "kittentts", "piper"]
    /// Providers whose live transcription session shows text while you speak.
    static let liveTranscriptionProviders: Set<String> = ["openai", "xai", "elevenlabs"]
    /// Providers that stream chunked PCM audio (lowest latency) rather than one clip per sentence.
    static let streamingSpeechProviders: Set<String> = ["openai", "elevenlabs", "gemini", "gemini-voix"]
    /// Plugin providers that read another provider's settings section (`gemini-voix` → `tts.gemini.*`).
    static func settingsSection(_ provider: String) -> String { provider == "gemini-voix" ? "gemini" : provider }
    /// Engines that run on the Hermes server itself, without a provider key.
    static let keylessVoiceProviders: Set<String> = ["local", "edge", "neutts", "kittentts", "piper"]

    /// Environment variables Hermes reads for each voice provider (any one is enough).
    static func voiceKeyNames(_ provider: String) -> [String] {
        switch provider {
        case "openai": ["VOICE_TOOLS_OPENAI_KEY", "OPENAI_API_KEY"]
        case "elevenlabs": ["ELEVENLABS_API_KEY"]
        case "groq": ["GROQ_API_KEY"]
        case "mistral": ["MISTRAL_API_KEY"]
        case "xai": ["XAI_API_KEY"]
        case "deepinfra": ["DEEPINFRA_API_KEY"]
        case "minimax": ["MINIMAX_API_KEY", "MINIMAX_CN_API_KEY"]
        case "gemini", "gemini-voix": ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        default: []
        }
    }

    /// The desktop only renders fields of the selected TTS/STT provider (`voiceFieldVisible`).
    static func voiceFieldVisible(_ key: String, config: JSONValue) -> Bool {
        let parts = key.split(separator: ".").map(String.init)
        guard parts.count >= 3, ["tts", "stt"].contains(parts[0]), parts[1] != "streaming" else { return true }
        let domain = parts[0]
        guard sttProviders.contains(parts[1]) || ttsProviders.contains(parts[1]) || parts[1] == "deepinfra" else { return true }
        if domain == "stt", config.at("stt.enabled") == .bool(false) { return false }
        let selected = config.at("\(domain).provider").string
        return parts[1] == settingsSection(selected.isEmpty ? (domain == "tts" ? "edge" : "local") : selected)
    }

    static let openAITTS1Voices: Set<String> = ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"]

    /// Options for a field, narrowed by context and always including the current value.
    static func options(for key: String, base: [String], current: String, config: JSONValue) -> [String] {
        var options = base
        if key == "tts.openai.voice", ["tts-1", "tts-1-hd"].contains(config.at("tts.openai.model").string) {
            options = options.filter { openAITTS1Voices.contains($0) }
        }
        if !current.isEmpty && !options.contains(current) { options.append(current) }
        return options
    }

    // MARK: Search

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    /// Every word of the query must appear in the key, its label or its description.
    static func matches(_ query: String, key: String, description: String?) -> Bool {
        let haystack = normalized("\(key) \(key.replacingOccurrences(of: "_", with: " ")) \(label(key)) \(description ?? "")")
        return normalized(query).split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
    }

    /// Path shown under a search result, e.g. "Voix › Synthèse vocale".
    static func location(of key: String) -> String {
        if let id = pageID(for: key), let page = page(id: id), let section = section(of: id) { return "\(section.title) › \(page.title)" }
        let group = key.contains(".") ? String(key.split(separator: ".")[0]) : "general"
        return "Autres réglages › \(groupTitle(group))"
    }

    // MARK: Copy

    static func label(_ key: String) -> String {
        if let label = labels[key] { return label }
        let last = key.split(separator: ".").last.map(String.init) ?? key
        if let label = componentLabels[last] { return label }
        let words = last.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// French copy first, then the server description unless it only restates the key.
    static func description(_ key: String, schema: JSONValue) -> String? {
        if let text = descriptions[key] { return text }
        let server = schema["description"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        let squash: (String) -> String = { normalized($0).filter { $0.isLetter || $0.isNumber } }
        guard !server.isEmpty, squash(server) != squash(key), squash(server) != squash(label(key)) else { return nil }
        return server
    }

    static func optionLabel(_ option: String, key: String) -> String {
        if let label = optionLabels[key]?[option] { return label }
        if key.hasSuffix("reasoning_effort"), let label = reasoningLabels[option] { return label }
        if option.isEmpty {
            switch key {
            case "display.personality": return "Aucune"
            case "memory.provider": return "Mémoire intégrée uniquement"
            case "timezone": return "Fuseau du système"
            default: return "Aucun"
            }
        }
        return option
    }

    static let reasoningEfforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static let reasoningLabels: [String: String] = [
        "": "Hériter", "none": "Désactivé", "minimal": "Minimal", "low": "Faible", "medium": "Moyen",
        "high": "Élevé", "xhigh": "Très élevé", "max": "Max", "ultra": "Ultra"
    ]

    static let providerNames: [String: String] = [
        "local": "Local (faster-whisper)", "groq": "Groq", "openai": "OpenAI", "mistral": "Mistral", "xai": "xAI (Grok)",
        "elevenlabs": "ElevenLabs", "deepinfra": "DeepInfra", "edge": "Edge (Microsoft)", "neutts": "NeuTTS",
        "minimax": "MiniMax", "gemini": "Gemini", "gemini-voix": "Gemini 3.8 · voix personnalisée", "kittentts": "KittenTTS", "piper": "Piper"
    ]

    static let optionLabels: [String: [String: String]] = [
        "agent.reasoning_effort": ["": "Par défaut (Moyen)"],
        "delegation.reasoning_effort": ["": "Hériter de l’agent"],
        "approvals.mode": ["smart": "Évaluation intelligente", "manual": "Me demander", "off": "Sans demande d’accord"],
        "approvals.cron_mode": ["deny": "Refuser", "approve": "Autoriser"],
        "approvals.single_query_mode": ["deny": "Refuser", "approve": "Autoriser"],
        "approvals.unattended_mode": ["deny": "Refuser", "approve": "Autoriser"],
        "voice.voice_chat_mode": ["chained": "Enchaîné", "gpt-live": "GPT-Live"],
        "agent.image_input_mode": ["auto": "Automatique", "native": "Image envoyée au modèle", "text": "Description textuelle"],
        "code_execution.mode": ["project": "Limité au projet", "strict": "Strict"],
        "context.engine": ["compressor": "Compression", "default": "Par défaut", "custom": "Personnalisé"],
        "agent.service_tier": ["": "Par défaut", "normal": "Standard", "fast": "Rapide", "ultrafast": "Ultrafast",
                               "auto": "Rapide au début de chaque tour", "cold": "Rapide au premier tour"],
        "terminal.backend": ["local": "Local", "docker": "Docker", "ssh": "SSH", "modal": "Modal", "daytona": "Daytona",
                             "vercel_sandbox": "Vercel Sandbox", "singularity": "Singularity"],
        "stt.provider": providerNames, "tts.provider": providerNames,
        "updates.non_interactive_local_changes": ["stash": "Conserver (stash)", "discard": "Abandonner"],
        "voice.submit_mode": ["direct": "Envoyer directement", "draft": "Brouillon modifiable"],
        "browser.dialog_policy": ["must_respond": "Répondre", "auto_dismiss": "Fermer", "auto_accept": "Accepter"],
        "display.busy_input_mode": ["interrupt": "Interrompre", "queue": "Mettre en file", "steer": "Réorienter"],
        "tts.neutts.device": ["cpu": "Processeur (CPU)", "cuda": "GPU NVIDIA (CUDA)", "mps": "GPU Apple (MPS)"]
    ]

    /// Select options the server schema declares as plain strings (desktop `ENUM_OPTIONS`).
    static let enumOptions: [String: [String]] = [
        "agent.image_input_mode": ["auto", "native", "text"],
        "agent.reasoning_effort": reasoningEfforts,
        "approvals.cron_mode": ["deny", "approve"], "approvals.single_query_mode": ["deny", "approve"], "approvals.unattended_mode": ["deny", "approve"],
        "code_execution.mode": ["project", "strict"],
        "context.engine": ["compressor", "default", "custom"],
        "voice.voice_chat_mode": ["chained", "gpt-live"],
        "voice.submit_mode": ["direct", "draft"],
        "browser.dialog_policy": ["must_respond", "auto_dismiss", "auto_accept"],
        "voice.gpt_live.voice": ["marin", "cedar", "quartz", "ripple", "vesper", "willow", "stone", "gleam", "meridian", "bossa", "tempo", "beacon", "delta", "cinder"],
        "tts.openai.voice": ["alloy", "ash", "ballad", "cedar", "coral", "echo", "fable", "marin", "nova", "onyx", "sage", "shimmer", "verse"],
        "tts.openai.model": ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"],
        "tts.edge.voice": ["fr-FR-DeniseNeural", "fr-FR-HenriNeural", "fr-FR-VivienneMultilingualNeural", "en-US-AriaNeural", "en-US-JennyNeural", "en-US-AndrewNeural", "en-GB-SoniaNeural"],
        "tts.elevenlabs.model_id": ["eleven_v3", "eleven_ttv_v3", "eleven_multilingual_v2", "eleven_turbo_v2", "eleven_turbo_v2_5", "eleven_flash_v2", "eleven_flash_v2_5"],
        "tts.gemini.model": ["gemini-2.5-flash-preview-tts", "gemini-2.5-pro-preview-tts"],
        "tts.gemini.voice": ["Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe", "Enceladus", "Iapetus",
                             "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar", "Alnilam", "Schedar",
                             "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"],
        "tts.xai.voice_id": ["eve"],
        "tts.minimax.model": ["speech-02-hd", "speech-02-turbo"],
        "tts.mistral.model": ["voxtral-mini-tts-2603"],
        "tts.kittentts.model": ["KittenML/kitten-tts-nano-0.8-int8", "KittenML/kitten-tts-micro-0.8-int8", "KittenML/kitten-tts-mini-0.8-int8"],
        "tts.kittentts.voice": ["Jasper"],
        "tts.piper.voice": ["en_US-lessac-medium", "en_US-amy-medium", "en_US-ryan-high", "en_GB-alan-medium"],
        "tts.neutts.model": ["neuphonic/neutts-air-q4-gguf", "neuphonic/neutts-air-q8-gguf", "neuphonic/neutts-air"],
        "tts.neutts.device": ["cpu", "cuda", "mps"],
        "stt.elevenlabs.model_id": ["scribe_v2", "scribe_v1"],
        "stt.local.model": ["tiny", "base", "small", "medium", "large-v3", "turbo"],
        "stt.openai.model": ["whisper-1", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "gpt-transcribe"],
        "stt.openai.streaming_model": ["gpt-live-transcribe", "gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"],
        "stt.groq.model": ["whisper-large-v3-turbo", "whisper-large-v3"],
        "stt.mistral.model": ["voxtral-mini-latest", "voxtral-mini-2602"],
        "stt.xai.model": ["grok-voice-transcribe-2.0", "grok-voice-transcribe-1.0"],
        "updates.non_interactive_local_changes": ["stash", "discard"]
    ]

    /// Open-world names: the options are suggestions, any value is accepted.
    static let freeInputKeys: Set<String> = [
        "tts.edge.voice", "voice.gpt_live.voice", "tts.openai.model", "tts.openai.voice", "tts.elevenlabs.voice_id", "tts.elevenlabs.model_id",
        "stt.openai.model", "stt.groq.model", "stt.mistral.model", "stt.xai.model", "stt.deepinfra.model", "tts.gemini.model", "tts.gemini.voice",
        "tts.xai.voice_id", "tts.minimax.model", "tts.minimax.voice_id", "tts.mistral.model", "tts.mistral.voice_id", "tts.neutts.model",
        "tts.kittentts.model", "tts.kittentts.voice", "tts.piper.voice", "tts.deepinfra.model", "tts.deepinfra.voice"
    ]

    static let objectListKeys: Set<String> = ["fallback_providers", "delegation.fallback_providers"]

    static let longTextKeys: Set<String> = [
        "approvals.smart_policy", "voice.gpt_live.instructions", "agent.coding_instructions", "agent.environment_hint", "stt.local.initial_prompt"
    ]

    /// Generic names for the last path component (auxiliary task blocks and the like).
    static let componentLabels: [String: String] = [
        "provider": "Fournisseur", "model": "Modèle", "base_url": "URL du point de terminaison", "api_key": "Clé API",
        "timeout": "Délai (s)", "extra_body": "Paramètres supplémentaires de requête", "reasoning_effort": "Raisonnement",
        "download_timeout": "Délai de téléchargement (s)", "enabled": "Activé", "api_mode": "Mode API", "language": "Langue",
        "voice": "Voix", "voice_id": "Voix", "model_id": "Modèle"
    ]

    static let labels: [String: String] = [
        "model": "Modèle par défaut", "model_context_length": "Fenêtre de contexte du modèle principal (forçage)",
        "fallback_providers": "Modèles de secours", "toolsets": "Ensembles d’outils activés", "timezone": "Fuseau horaire",
        "display.personality": "Personnalité", "display.show_reasoning": "Blocs de raisonnement",
        "desktop.repo_scan_enabled": "Découverte automatique de dépôts", "desktop.repo_scan_roots": "Racines de découverte de dépôts",
        "desktop.repo_scan_exclude_paths": "Chemins de dépôt exclus",
        "agent.max_turns": "Étapes max. de l’agent", "agent.image_input_mode": "Pièces jointes d’image", "agent.api_max_retries": "Nouveaux essais API",
        "agent.service_tier": "Vitesse (niveau de service)", "agent.tool_use_enforcement": "Contrôle de l’utilisation des outils",
        "agent.reasoning_effort": "Raisonnement", "agent.fast_auto_seconds": "Durée du mode rapide automatique (s)",
        "agent.disabled_toolsets": "Ensembles d’outils désactivés",
        "terminal.cwd": "Répertoire de travail", "terminal.backend": "Backend d’exécution", "terminal.timeout": "Délai d’expiration de la commande",
        "terminal.persistent_shell": "Shell persistant", "terminal.env_passthrough": "Transmission de l’environnement",
        "terminal.docker_image": "Image Docker", "terminal.singularity_image": "Image Singularity", "terminal.modal_image": "Image Modal",
        "terminal.daytona_image": "Image Daytona",
        "file_read_max_chars": "Limite de lecture de fichier",
        "tool_output.max_bytes": "Limite de sortie du terminal", "tool_output.max_lines": "Limite de pagination de fichier",
        "tool_output.max_line_length": "Limite de longueur de ligne", "code_execution.mode": "Mode d’exécution du code",
        "approvals.mode": "Quand demander mon accord", "approvals.timeout": "Délai de réponse", "approvals.cron_mode": "Actions sensibles des routines",
        "approvals.single_query_mode": "Actions sans conversation", "approvals.unattended_mode": "Actions automatisées",
        "approvals.deny": "Règles interdites", "command_allowlist": "Règles toujours autorisées",
        "approvals.smart_policy": "Consignes de l’évaluation intelligente", "approvals.denial_breaker_threshold": "Limite des refus consécutifs",
        "approvals.destructive_slash_confirm": "Confirmer les commandes destructives", "approvals.mcp_reload_confirm": "Confirmer le rechargement MCP",
        "security.redact_secrets": "Masquer les secrets", "security.allow_private_urls": "Autoriser les adresses web privées",
        "browser.allow_private_urls": "Adresses web privées du navigateur", "browser.auto_local_for_private_urls": "Navigateur local pour les adresses web privées",
        "browser.use_real_profile": "Utiliser mon vrai profil de navigateur",
        "checkpoints.enabled": "Points de contrôle de fichiers", "checkpoints.max_snapshots": "Limite de points de contrôle",
        "voice.max_recording_seconds": "Durée maximale d’enregistrement", "voice.auto_tts": "Lire les réponses à haute voix",
        "voice.voice_chat_mode": "Mode de conversation vocale", "voice.gpt_live.voice": "Voix GPT-Live", "voice.gpt_live.instructions": "Personnalité GPT-Live",
        "voice.gpt_live.model": "Modèle GPT-Live", "voice.client_direct": "Voix directe depuis l’appareil",
        "voice.silence_duration": "Durée de silence avant envoi (s)", "voice.silence_threshold": "Seuil de silence",
        "voice.barge_in": "Interrompre l’agent en parlant", "voice.barge_in_grace_seconds": "Délai avant interruption (s)",
        "voice.barge_in_threshold_multiplier": "Sensibilité de l’interruption", "voice.stop_phrases": "Phrases d’arrêt",
        "voice.record_key": "Raccourci d’enregistrement", "voice.submit_mode": "Envoi de la transcription",
        "voice.beep_enabled": "Bip de début et de fin", "voice.beep_volume": "Volume du bip", "voice.thinking_sound": "Son de réflexion",
        "stt.enabled": "Reconnaissance vocale", "stt.echo_transcripts": "Réémettre les transcriptions", "stt.provider": "Fournisseur de reconnaissance vocale",
        "stt.streaming": "Transcription en direct", "stt.language": "Langue par défaut",
        "stt.cloud_trim_silence": "Couper les silences avant envoi", "stt.cloud_trim_threshold_db": "Seuil de silence (dB)",
        "stt.cloud_trim_keep_ms": "Marge conservée (ms)",
        "stt.local.model": "Modèle de transcription local", "stt.local.language": "Langue de transcription",
        "stt.openai.model": "Modèle STT OpenAI", "stt.openai.streaming_model": "Modèle de transcription en direct OpenAI",
        "stt.openai.language": "Langue OpenAI", "stt.groq.model": "Modèle STT Groq", "stt.mistral.model": "Modèle STT Mistral",
        "stt.xai.model": "Modèle STT xAI", "stt.deepinfra.model": "Modèle STT DeepInfra",
        "stt.elevenlabs.model_id": "Modèle STT ElevenLabs", "stt.elevenlabs.language_code": "Langue ElevenLabs",
        "stt.elevenlabs.tag_audio_events": "Étiqueter les événements audio", "stt.elevenlabs.diarize": "Diarisation des locuteurs",
        "tts.provider": "Fournisseur de synthèse vocale", "tts.edge.voice": "Voix Edge", "tts.openai.model": "Modèle TTS OpenAI",
        "tts.openai.voice": "Voix OpenAI", "tts.elevenlabs.voice_id": "Voix ElevenLabs", "tts.elevenlabs.model_id": "Modèle ElevenLabs",
        "tts.xai.voice_id": "Voix xAI (Grok)", "tts.xai.language": "Langue xAI", "tts.xai.speed": "Vitesse de lecture xAI",
        "tts.xai.auto_speech_tags": "Étiquettes vocales automatiques xAI", "tts.xai.optimize_streaming_latency": "Optimisation de la latence xAI",
        "tts.xai.sample_rate": "Fréquence d’échantillonnage xAI", "tts.xai.bit_rate": "Débit binaire xAI",
        "tts.minimax.model": "Modèle TTS MiniMax", "tts.minimax.voice_id": "Voix MiniMax", "tts.mistral.model": "Modèle TTS Mistral",
        "tts.mistral.voice_id": "Voix Mistral", "tts.gemini.model": "Modèle TTS Gemini", "tts.gemini.voice": "Voix Gemini",
        "tts.neutts.model": "Modèle NeuTTS", "tts.neutts.device": "Appareil NeuTTS", "tts.kittentts.model": "Modèle KittenTTS",
        "tts.kittentts.voice": "Voix KittenTTS", "tts.piper.voice": "Voix Piper", "tts.deepinfra.model": "Modèle TTS DeepInfra",
        "tts.deepinfra.voice": "Voix DeepInfra", "tts.keep_warm_seconds": "Garder le moteur prêt (s)",
        "tts.streaming.min_len": "Longueur minimale d’un segment",
        "memory.memory_enabled": "Mémoire persistante", "memory.user_profile_enabled": "Profil utilisateur", "memory.memory_char_limit": "Budget mémoire",
        "memory.user_char_limit": "Budget profil", "memory.provider": "Fournisseur de mémoire", "memory.write_approval": "Approuver les écritures en mémoire",
        "memory.nudge_interval": "Rappel de mémorisation (tours)",
        "context.engine": "Moteur de contexte", "compression.enabled": "Auto-compression", "compression.threshold": "Seuil de compression",
        "compression.codex_gpt55_autoraise": "Relèvement automatique de la compression Codex", "compression.target_ratio": "Objectif de compression",
        "compression.protect_last_n": "Messages récents protégés", "auxiliary.compression.timeout": "Délai du modèle de compression (s)",
        "delegation.model": "Modèle sous-agent", "delegation.provider": "Fournisseur sous-agent", "delegation.max_iterations": "Limite de tours sous-agent",
        "delegation.max_concurrent_children": "Sous-agents parallèles", "delegation.child_timeout_seconds": "Délai sous-agent",
        "delegation.reasoning_effort": "Intensité du raisonnement sous-agent",
        "updates.non_interactive_local_changes": "Modifications locales à la mise à jour intégrée"
    ]

    static let descriptions: [String: String] = [
        "model_context_length": "Remplace la fenêtre de contexte détectée du modèle principal uniquement (en jetons). Laissez 0 pour utiliser la valeur détectée. N’affecte pas les modèles auxiliaires.",
        "fallback_providers": "Fournisseurs et modèles essayés dans l’ordre si le modèle par défaut échoue.",
        "display.personality": "Style par défaut de l’assistant pour les nouvelles sessions.",
        "display.show_reasoning": "Afficher les sections de raisonnement quand le modèle les fournit.",
        "desktop.repo_scan_enabled": "Analyser les dossiers du serveur à la recherche de dépôts Git à afficher dans Projets.",
        "desktop.repo_scan_roots": "Dossiers à analyser. Laissez vide pour analyser le répertoire personnel.",
        "desktop.repo_scan_exclude_paths": "Dossiers et leurs descendants à ignorer lors de la découverte de dépôts.",
        "timezone": "Fuseau horaire IANA. Si vide, Hermes utilise celui du système.",
        "browser.use_real_profile": "La navigation locale utilise vos vraies connexions : Hermes copie le profil de votre navigateur par défaut dans un instantané géré et le pilote avec son Chromium intégré. Seuls les navigateurs Chromium sont pris en charge.",
        "agent.image_input_mode": "Contrôle la façon dont les images jointes sont envoyées au modèle.",
        "agent.max_turns": "Nombre maximal de tours d’appel d’outils avant que Hermes n’arrête une exécution.",
        "agent.service_tier": "Mode rapide : toujours, au début de chaque tour, ou au premier tour seulement, quand le modèle le propose.",
        "agent.reasoning_effort": "Intensité de réflexion par défaut du modèle principal pour les nouvelles sessions.",
        "terminal.cwd": "Dossier de projet par défaut pour les outils et le terminal.",
        "terminal.persistent_shell": "Conserve l’état du shell entre les commandes lorsque le backend le permet.",
        "terminal.env_passthrough": "Variables d’environnement transmises à l’exécution des outils.",
        "terminal.docker_image": "Image de conteneur utilisée lorsque le backend d’exécution est Docker.",
        "terminal.singularity_image": "Image utilisée lorsque le backend d’exécution est Singularity.",
        "terminal.modal_image": "Image utilisée lorsque le backend d’exécution est Modal.",
        "terminal.daytona_image": "Image utilisée lorsque le backend d’exécution est Daytona.",
        "code_execution.mode": "Degré de restriction de l’exécution du code au projet actuel.",
        "file_read_max_chars": "Nombre maximal de caractères que Hermes peut lire dans une demande de fichier.",
        "approvals.timeout": "Après ce délai sans réponse, Hermes refuse l’action en attente (en secondes).",
        "approvals.cron_mode": "Pour les commandes sensibles des routines, sans personne pour répondre : refuser ou autoriser automatiquement.",
        "approvals.single_query_mode": "Pour les commandes sensibles lancées hors conversation : refuser ou autoriser automatiquement.",
        "approvals.unattended_mode": "Pour les commandes sensibles des actions automatisées : refuser ou autoriser automatiquement.",
        "approvals.deny": "Les commandes correspondant à ces règles sont refusées, même en mode sans demande d’accord.",
        "command_allowlist": "Ces règles autorisent les commandes correspondantes sans nouvelle demande. Les interdictions restent prioritaires.",
        "security.redact_secrets": "Masque les secrets détectés du contenu visible par le modèle lorsque c’est possible.",
        "checkpoints.enabled": "Créer des instantanés de restauration avant les modifications de fichiers.",
        "memory.memory_enabled": "Sauvegarder des souvenirs durables pouvant aider les sessions futures.",
        "memory.user_profile_enabled": "Maintenir un profil compact de vos préférences.",
        "context.engine": "Stratégie pour gérer les longues conversations proches de la limite de contexte.",
        "compression.enabled": "Résumer le contexte ancien quand les conversations grossissent.",
        "compression.codex_gpt55_autoraise": "Relever la compression à 85 % pour les modèles ChatGPT Codex OAuth pris en charge.",
        "auxiliary.compression.timeout": "Secondes d’attente du modèle de compression par appel (120 par défaut). Augmentez pour les modèles locaux lents.",
        "voice.auto_tts": "Lit automatiquement les réponses de l’agent à voix haute.",
        "voice.voice_chat_mode": "Enchaîné : reconnaissance vocale → Hermes → synthèse vocale, avec les fournisseurs choisis ci-dessous. GPT-Live : un modèle vocal OpenAI full-duplex écoute et parle, et confie chaque vraie demande à Hermes. Nécessite une clé OpenAI ; la couche vocale est facturée 0,05 $ par minute.",
        "voice.gpt_live.voice": "Voix du mode GPT-Live. Les identifiants de voix personnalisés sont acceptés.",
        "voice.gpt_live.instructions": "Phrases supplémentaires pour la personnalité vocale en direct (ton, rythme, langue). Hermes conserve son propre prompt système.",
        "voice.max_recording_seconds": "Au-delà de cette durée, l’enregistrement s’arrête et votre message est envoyé.",
        "voice.client_direct": "Laisse l’appareil parler directement aux fournisseurs de voix compatibles, sans relais par le serveur.",
        "voice.silence_duration": "Temps de silence après lequel Hermes considère que vous avez fini de parler.",
        "voice.silence_threshold": "Niveau sonore en dessous duquel le micro est considéré comme silencieux.",
        "voice.barge_in": "Parler pendant que l’agent répond coupe sa voix pour vous écouter.",
        "voice.barge_in_grace_seconds": "Temps pendant lequel l’agent ignore votre voix juste après avoir commencé à parler.",
        "voice.barge_in_threshold_multiplier": "Plus la valeur est élevée, plus il faut parler fort pour interrompre l’agent.",
        "voice.stop_phrases": "Dire l’une de ces phrases arrête la conversation vocale.",
        "stt.enabled": "Activer la transcription vocale locale ou via un fournisseur.",
        "stt.echo_transcripts": "Publier la transcription brute des messages vocaux dans la conversation.",
        "stt.streaming": "Affiche le texte pendant que vous parlez. Seuls OpenAI, xAI et ElevenLabs proposent ces sessions en direct ; en cas d’échec, Hermes revient à l’enregistrement complet.",
        "stt.elevenlabs.language_code": "Code de langue ISO-639-3 facultatif. Vide = détection automatique par ElevenLabs.",
        "tts.xai.voice_id": "ID de voix xAI (ex. eve) ou un ID de voix personnalisé.",
        "tts.xai.language": "Code de langue parlée (ex. fr, pt-BR) ou « auto » pour la détection automatique.",
        "tts.xai.speed": "Vitesse de lecture. 0,7 = plus lent, 1,0 = normal, 1,5 = plus rapide.",
        "tts.xai.auto_speech_tags": "Laisser un LLM insérer des balises audio expressives ([laughing], [sighs]) avant la synthèse.",
        "tts.xai.optimize_streaming_latency": "Compromis latence/qualité. 0 = meilleure qualité, 2 = latence minimale.",
        "tts.xai.sample_rate": "Fréquence d’échantillonnage audio en Hz. Plus élevée = meilleure qualité, fichiers plus volumineux.",
        "tts.xai.bit_rate": "Débit binaire MP3 en bps. S’applique uniquement lorsque le codec est mp3.",
        "tts.neutts.device": "Périphérique d’inférence local pour NeuTTS.",
        "delegation.reasoning_effort": "Vide : les sous-agents héritent de l’intensité de raisonnement de l’agent.",
        "updates.non_interactive_local_changes": "Quand Hermes se met à jour depuis une application, conserve les modifications locales (stash) ou les abandonne (discard)."
    ]
}
