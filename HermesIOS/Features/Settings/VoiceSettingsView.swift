import AVFoundation
import SwiftUI

private func providerSpecific(_ key: String) -> String? {
    let parts = key.split(separator: ".").map(String.init)
    guard parts.count >= 3, ["stt", "tts"].contains(parts[0]) else { return nil }
    let known = Set(SettingsCatalog.sttProviders + SettingsCatalog.ttsProviders + ["deepinfra"])
    return known.contains(parts[1]) ? parts[1] : nil
}

// MARK: Conversation

struct VoiceConversationSettingsView: View {
    let store: AgentConfigStore
    @State private var live: JSONValue = .null
    private static let listening = ["voice.silence_duration", "voice.silence_threshold", "voice.barge_in", "voice.barge_in_grace_seconds",
                                    "voice.barge_in_threshold_multiplier", "voice.stop_phrases", "voice.max_recording_seconds"]
    private static let modes: [(id: String, title: String, detail: String)] = [
        ("chained", "Enchaîné", "La reconnaissance vocale transcrit votre voix, Hermes répond, puis la synthèse vocale lit la réponse, avec les fournisseurs choisis dans « Reconnaissance vocale » et « Synthèse vocale »."),
        ("gpt-live", "GPT-Live", "Un modèle vocal OpenAI full-duplex écoute et parle en temps réel, et confie chaque vraie demande à Hermes avec tous ses outils. Nécessite une clé OpenAI ; la couche vocale est facturée 0,05 $ par minute.")
    ]
    private var mode: String { store.value("voice.voice_chat_mode").string.isEmpty ? "chained" : store.value("voice.voice_chat_mode").string }
    private var pageKeys: [String] { store.keys(on: "voice.conversation") }

    var body: some View {
        List {
            SettingsFeedback(store: store)
            if store.fields["voice.voice_chat_mode"] != nil {
                Section {
                    ForEach(Self.modes, id: \.id) { option in
                        Button { Task { await store.save("voice.voice_chat_mode", .string(option.id)) } } label: {
                            RadioRow(title: option.title, detail: option.detail, selected: mode == option.id)
                        }.buttonStyle(.plain).accessibilityAddTraits(mode == option.id ? .isSelected : [])
                            .accessibilityIdentifier("voice-mode-" + option.id)
                    }
                    if mode == "gpt-live", !live.isNull {
                        CredentialStatusRow(store: store, configured: live["available"].bool,
                                            configuredText: "Clé OpenAI disponible sur le serveur",
                                            missingText: "Aucune clé OpenAI : GPT-Live ne peut pas démarrer.")
                    }
                } header: { Text("Mode de conversation") }
            }
            if mode == "gpt-live" {
                let liveKeys = pageKeys.filter { $0.hasPrefix("voice.gpt_live.") }
                if !liveKeys.isEmpty { Section("GPT-Live") { ConfigFieldRows(store: store, keys: liveKeys) } }
            }
            Section {
                ConfigFieldRows(store: store, keys: Self.listening)
            } header: { Text("Écoute et interruption") } footer: {
                Text("Ces réglages décident quand Hermes considère que vous avez fini de parler, et comment vous pouvez lui couper la parole.")
            }
            let others = pageKeys.filter { $0 != "voice.voice_chat_mode" && !$0.hasPrefix("voice.gpt_live.") && !Self.listening.contains($0) }
            if !others.isEmpty { Section("Autres réglages") { ConfigFieldRows(store: store, keys: others) } }
        }.modernList().navigationTitle("Conversation vocale").navigationBarTitleDisplayMode(.inline)
            .task { await loadStatus() }
            .onChange(of: mode) { Task { await loadStatus() } }
    }

    private func loadStatus() async { live = (try? await store.fetch("/api/audio/voice-live/status")) ?? .null }
}

// MARK: Transcription

struct TranscriptionSettingsView: View {
    let store: AgentConfigStore
    private var provider: String { store.value("stt.provider").string.isEmpty ? "local" : store.value("stt.provider").string }
    private var providers: [String] {
        let declared = store.schema("stt.provider")["options"].array.map(\.displayText)
        return SettingsCatalog.options(for: "stt.provider", base: declared.isEmpty ? SettingsCatalog.sttProviders : declared, current: provider, config: store.config)
    }
    private var pageKeys: [String] { store.keys(on: "voice.transcription") }

    var body: some View {
        List {
            SettingsFeedback(store: store)
            Section { ConfigFieldRows(store: store, keys: ["stt.enabled"]) }
            if store.value("stt.enabled") != false {
                Section {
                    VoiceProviderPicker(store: store, key: "stt.provider", providers: providers) { name in
                        SettingsCatalog.liveTranscriptionProviders.contains(name) ? "En direct" : nil
                    }
                } header: { Text("Fournisseur") } footer: {
                    Text("« En direct » : le texte s’affiche pendant que vous parlez. Les fournisseurs sans clé tournent sur le serveur Hermes.")
                }
                if store.fields["stt.streaming"] != nil {
                    Section {
                        ConfigFieldRow(store: store, key: "stt.streaming")
                        if store.value("stt.streaming").bool && !SettingsCatalog.liveTranscriptionProviders.contains(provider) {
                            Label("\(SettingsCatalog.optionLabel(provider, key: "stt.provider")) ne propose pas de session en direct : Hermes transcrira l’enregistrement complet.", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if provider == "openai" { ConfigFieldRows(store: store, keys: ["stt.openai.streaming_model"]) }
                    } header: { Text("Transcription en direct") }
                }
                let specific = pageKeys.filter { providerSpecific($0) == provider && $0 != "stt.openai.streaming_model" }
                if !specific.isEmpty {
                    Section("Réglages \(SettingsCatalog.optionLabel(provider, key: "stt.provider"))") { ConfigFieldRows(store: store, keys: specific) }
                }
                let general = pageKeys.filter { providerSpecific($0) == nil && !["stt.enabled", "stt.provider", "stt.streaming"].contains($0) }
                if !general.isEmpty { Section("Général") { ConfigFieldRows(store: store, keys: general) } }
            }
        }.modernList().navigationTitle("Reconnaissance vocale").navigationBarTitleDisplayMode(.inline)
            .task { await store.loadCredentials() }
    }
}

// MARK: Speech

struct SpeechSettingsView: View {
    let store: AgentConfigStore
    @State private var voices: JSONValue = .null
    private var provider: String { store.value("tts.provider").string.isEmpty ? "edge" : store.value("tts.provider").string }
    private var providers: [String] {
        let declared = store.schema("tts.provider")["options"].array.map(\.displayText)
        return SettingsCatalog.options(for: "tts.provider", base: declared.isEmpty ? SettingsCatalog.ttsProviders : declared, current: provider, config: store.config)
    }
    private var pageKeys: [String] { store.keys(on: "voice.speech") }

    var body: some View {
        List {
            SettingsFeedback(store: store)
            Section { ConfigFieldRows(store: store, keys: ["voice.auto_tts"]) }
            Section {
                VoiceProviderPicker(store: store, key: "tts.provider", providers: providers) { name in
                    SettingsCatalog.streamingSpeechProviders.contains(name) ? "Flux continu" : "Par phrase"
                }
            } header: { Text("Fournisseur") } footer: {
                Text("« Flux continu » : l’audio arrive par morceaux dès les premiers mots, pour la latence la plus faible. « Par phrase » : chaque phrase est synthétisée puis lue.")
            }
            let specific = pageKeys.filter { providerSpecific($0) == SettingsCatalog.settingsSection(provider) }
            if !specific.isEmpty {
                Section {
                    ForEach(specific, id: \.self) { key in
                        if key == "tts.elevenlabs.voice_id" { elevenLabsVoice }
                        else if key == "tts.gemini.voice" { ConfigFieldRow(store: store, key: key, options: Self.geminiVoices) }
                        else if key == "tts.gemini.model" { ConfigFieldRow(store: store, key: key, options: Self.geminiModels) }
                        else { ConfigFieldRow(store: store, key: key) }
                    }
                } header: { Text("Réglages \(SettingsCatalog.optionLabel(provider, key: "tts.provider"))") } footer: {
                    if provider == "gemini-voix" {
                        Text("Voix : le nom exact de votre voix Voice design dans AI Studio, son identifiant voice_…, ou une voix de base. Modèle conseillé : gemini-3.8-flash-lite-tts. Nécessite le plugin gemini-voix sur le serveur et GEMINI_API_KEY dans les clés de ce profil.")
                    } else if provider == "elevenlabs", !voices.isNull, !voices["available"].bool {
                        Text(voices["error"].string == "unauthorized"
                             ? "La clé ElevenLabs a été refusée : les voix de votre compte ne peuvent pas être listées."
                             : "Ajoutez la clé ElevenLabs dans « Clés et identifiants » pour choisir parmi les voix de votre compte.")
                    }
                }
            }
            VoiceSampleSection(store: store)
            let general = pageKeys.filter { providerSpecific($0) == nil && !["voice.auto_tts", "tts.provider"].contains($0) }
            if !general.isEmpty { Section("Général") { ConfigFieldRows(store: store, keys: general) } }
        }.modernList().navigationTitle("Synthèse vocale").navigationBarTitleDisplayMode(.inline)
            .task { await store.loadCredentials(); await loadVoices() }
            .onChange(of: provider) { Task { await loadVoices() } }
    }

    /// Gemini's 30 prebuilt voices speak every supported language; regional accents need a
    /// voice from Google's extended library (any name can still be typed in « Autre valeur »).
    static let geminiVoices = ["Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede", "Callirrhoe", "Autonoe",
        "Enceladus", "Iapetus", "Umbriel", "Algieba", "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar",
        "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi", "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"]
    static let geminiModels = ["gemini-3.8-flash-tts", "gemini-3.8-flash-lite-tts", "gemini-3.1-flash-tts-preview", "gemini-2.5-flash-preview-tts"]

    @ViewBuilder private var elevenLabsVoice: some View {
        let list = voices["voices"].array
        if voices["available"].bool, !list.isEmpty {
            ConfigFieldRow(store: store, key: "tts.elevenlabs.voice_id",
                           options: list.map { $0["voice_id"].string },
                           optionLabels: Dictionary(list.map { ($0["voice_id"].string, $0["label"].string) }, uniquingKeysWith: { first, _ in first }))
        } else {
            ConfigFieldRow(store: store, key: "tts.elevenlabs.voice_id")
        }
    }

    private func loadVoices() async {
        guard provider == "elevenlabs" else { return }
        do { voices = try await store.fetch("/api/audio/elevenlabs/voices") }
        catch is CancellationError {}
        catch { voices = ["available": false, "voices": [], "error": "unavailable"] }
    }
}

// MARK: Shared pieces

struct RadioRow: View {
    let title: String
    var detail: String?
    var badge: String?
    var status: String?
    var statusOK = true
    let selected: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    if let badge {
                        Text(badge).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(AppTheme.accent.opacity(0.12), in: Capsule()).foregroundStyle(AppTheme.accent)
                    }
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let status { Text(status).font(.caption2).foregroundStyle(statusOK ? Color.secondary : AppTheme.accent) }
            }
            Spacer(minLength: 0)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? AppTheme.accent : .secondary).font(.title3).accessibilityHidden(true)
        }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

/// Provider choice with its streaming badge and whether its key exists on the server.
struct VoiceProviderPicker: View {
    let store: AgentConfigStore
    let key: String
    let providers: [String]
    var badge: (String) -> String?
    private var selected: String { store.value(key).string.isEmpty ? (key == "tts.provider" ? "edge" : "local") : store.value(key).string }

    var body: some View {
        ForEach(providers, id: \.self) { name in
            let credential = store.hasCredential(for: name)
            Button { Task { await store.save(key, .string(name)) } } label: {
                RadioRow(title: SettingsCatalog.optionLabel(name, key: key), badge: badge(name), status: status(name, credential),
                         statusOK: credential != false, selected: selected == name)
            }.buttonStyle(.plain).disabled(store.saving.contains(key))
                .accessibilityAddTraits(selected == name ? .isSelected : [])
                .accessibilityIdentifier("\(key)-\(name)")
        }
        if store.hasCredential(for: selected) == false {
            CredentialStatusRow(store: store, configured: false, configuredText: "",
                                missingText: "Clé \(SettingsCatalog.voiceKeyNames(selected).last ?? "") manquante sur le serveur.")
        }
    }

    private func status(_ name: String, _ credential: Bool?) -> String? {
        if SettingsCatalog.keylessVoiceProviders.contains(name) { return "Sur le serveur, sans clé" }
        switch credential {
        case true: return "Clé configurée"
        case false: return "Clé manquante"
        default: return nil
        }
    }
}

/// Key status without ever showing the key, with a way to add it.
struct CredentialStatusRow: View {
    let store: AgentConfigStore
    let configured: Bool
    let configuredText: String
    let missingText: String
    var body: some View {
        if configured {
            Label(configuredText, systemImage: "checkmark.seal").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label(missingText, systemImage: "key").font(.caption).foregroundStyle(AppTheme.accent)
                NavigationLink { CredentialsSettingsView(app: store.app, profile: store.profile) } label: {
                    Text("Ajouter la clé dans « Clés et identifiants »").font(.caption.weight(.medium))
                }
            }
        }
    }
}


/// Speaks a sample through the agent's own configured provider and voice (`POST /api/audio/speak`),
/// so a voice can be auditioned from the phone before a call. Billed like any spoken reply.
private struct VoiceSampleSection: View {
    let store: AgentConfigStore
    @State private var text = "Bonjour! C’est moi, ton agent. Dis-moi ce que je peux faire pour toi aujourd’hui."
    @State private var busy = false
    @State private var failure: String?
    @State private var player: AVAudioPlayer?

    var body: some View {
        Section {
            TextField("Phrase à faire lire", text: $text, axis: .vertical).lineLimit(1...4)
            Button {
                Task { await play() }
            } label: {
                HStack {
                    Label(busy ? "Synthèse…" : "Tester la voix", systemImage: "play.circle")
                    if busy { Spacer(); ProgressView() }
                }
            }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.app.demo)
                .accessibilityIdentifier("voice-sample")
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        } header: { Text("Essayer") } footer: {
            Text("Lit la phrase avec le fournisseur et la voix enregistrés pour cet agent. Enregistrez d’abord un changement de voix pour l’entendre.")
        }
    }

    private func play() async {
        busy = true; failure = nil
        defer { busy = false }
        do {
            let result = try await store.tools.request("/api/audio/speak", method: "POST", body: ["text": .string(text)])
            let url = result["data_url"].string
            guard let comma = url.firstIndex(of: ","), let audio = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
                throw RPCFailure("Hermes n’a pas renvoyé d’audio.")
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let sample = try AVAudioPlayer(data: audio)
            player = sample
            sample.play()
        } catch is CancellationError {
        } catch { failure = error.localizedDescription }
    }
}
