import SwiftUI
import Observation

// Shared plumbing for the account screens (keys, providers, messaging, extensions, agents).
// Secrets typed here go straight to the Hermes server; nothing is cached or shown back
// except the masked hints the server itself returns.

/// One row of `GET /api/env` (hermes_cli/web_routers/config_env.py `_get_env_vars_sync`).
struct AccountsCredential: Identifiable, Equatable {
    let key: String
    var id: String { key }
    var isSet: Bool
    var hint: String
    var detail: String
    var url: URL?
    var category: String
    var isPassword: Bool
    var advanced: Bool
    var channelManaged: Bool
    var provider: String
    var providerLabel: String
    var providerPrimary: Bool
    var custom: Bool

    init(key: String, _ row: JSONValue) {
        self.key = key
        isSet = row["is_set"].bool
        hint = Accounts.maskedHint(row["redacted_value"].string)
        detail = row["description"].string
        url = URL(string: row["url"].string).flatMap { ["https", "http"].contains($0.scheme ?? "") ? $0 : nil }
        category = row["category"].string
        isPassword = row["is_password"].isNull ? true : row["is_password"].bool
        advanced = row["advanced"].bool
        channelManaged = row["channel_managed"].bool
        provider = row["provider"].string
        providerLabel = row["provider_label"].string
        providerPrimary = row["provider_primary"].bool
        custom = row["custom"].bool
    }

    var title: String { Accounts.knownTitles[key] ?? (providerLabel.isEmpty ? key : "\(providerLabel) · \(Accounts.suffix(key))") }
    var status: String { isSet ? (hint.isEmpty ? "Configurée" : "Configurée · \(hint)") : "Non définie" }
}

enum Accounts {
    /// Strips the server's display-only sentinel (`«redacted:sk-…abcd»`) down to its masked hint.
    static func maskedHint(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if raw.hasPrefix("«redacted:") {
            var hint = String(raw.dropFirst("«redacted:".count))
            if hint.hasSuffix("»") { hint.removeLast() }
            return hint
        }
        return raw.hasPrefix("«") ? "" : raw
    }

    static func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? value
    }

    static func validEnvName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.letters.union(CharacterSet(charactersIn: "_")).contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "_" }
    }

    static func validProfileName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }
    }

    static func suffix(_ key: String) -> String {
        if key.hasSuffix("_BASE_URL") { return "URL de base" }
        if key.hasSuffix("_API_KEY") || key.hasSuffix("_KEY") { return "clé API" }
        if key.hasSuffix("_TOKEN") { return "jeton" }
        return key
    }

    static let knownTitles: [String: String] = [
        "ELEVENLABS_API_KEY": "ElevenLabs",
        "VOICE_TOOLS_OPENAI_KEY": "OpenAI · voix (STT/TTS)",
        "OPENAI_API_KEY": "OpenAI",
        "GROQ_API_KEY": "Groq",
        "MISTRAL_API_KEY": "Mistral (Voxtral)",
        "XAI_API_KEY": "xAI",
        "DEEPINFRA_API_KEY": "DeepInfra",
        "MINIMAX_API_KEY": "MiniMax",
        "GEMINI_API_KEY": "Gemini",
        "GOOGLE_API_KEY": "Google AI Studio",
        "OPENROUTER_API_KEY": "OpenRouter",
        "ANTHROPIC_API_KEY": "Anthropic",
        "PORCUPINE_ACCESS_KEY": "Picovoice (mot d’éveil)",
        "FIRECRAWL_API_KEY": "Firecrawl",
        "TAVILY_API_KEY": "Tavily",
        "EXA_API_KEY": "Exa",
        "BRAVE_API_KEY": "Brave Search",
        "FAL_KEY": "fal.ai",
        "GITHUB_TOKEN": "GitHub"
    ]

    static func scopeNote(_ title: String) -> String {
        "Ces valeurs sont enregistrées dans le fichier .env du profil « \(title) » sur votre serveur Hermes. Chaque agent a ses propres clés ; elles ne sont jamais conservées sur cet iPhone."
    }
}

/// Owns the env-credential lifecycle for one profile (same contract as the desktop `useEnvCredentials`).
@MainActor @Observable
final class AccountsEnvStore {
    let tools: NativeToolSession
    var rows: [String: AccountsCredential] = [:]
    var loaded = false
    var loading = false

    init(tools: NativeToolSession) { self.tools = tools }

    func load() async {
        if tools.app.demo { rows = Self.demoRows; loaded = true; return }
        loading = true
        defer { loading = false }
        do {
            let result = try await tools.request("/api/env")
            rows = Dictionary(uniqueKeysWithValues: result.object.map { ($0.key, AccountsCredential(key: $0.key, $0.value)) })
            loaded = true
        } catch is CancellationError {
        } catch { tools.error = error.localizedDescription }
    }

    /// PUT /api/env — writes the profile's .env through the server's credential lifecycle.
    @discardableResult func save(_ key: String, value: String, providerSetup: Bool = false) async -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { tools.error = "Saisissez d’abord une valeur."; return false }
        var done = false
        await tools.perform {
            var body: [String: JSONValue] = ["key": .string(key), "value": .string(trimmed)]
            if providerSetup { body["provider_setup"] = true }
            _ = try await tools.request("/api/env", method: "PUT", body: .object(body))
            done = true
        }
        if done { await load() }
        return done
    }

    /// DELETE /api/env — clears the .env entry and its mirrors server side.
    @discardableResult func remove(_ key: String) async -> Bool {
        var done = false
        await tools.perform {
            _ = try await tools.request("/api/env", method: "DELETE", body: ["key": .string(key)])
            done = true
        }
        if done { await load() }
        return done
    }

    static let demoRows: [String: AccountsCredential] = {
        func row(_ key: String, _ category: String, _ set: Bool, _ detail: String, label: String = "") -> (String, AccountsCredential) {
            (key, AccountsCredential(key: key, ["is_set": .bool(set), "redacted_value": set ? "«redacted:sk-…a1b2»" : .null,
                "description": .string(detail), "category": .string(category), "is_password": true, "provider_label": .string(label)]))
        }
        return Dictionary(uniqueKeysWithValues: [
            row("ELEVENLABS_API_KEY", "tool", false, "ElevenLabs API key for premium text-to-speech voices and Scribe transcription"),
            row("OPENAI_API_KEY", "provider", true, "OpenAI API key", label: "OpenAI"),
            row("OPENROUTER_API_KEY", "provider", false, "OpenRouter API key", label: "OpenRouter"),
            row("GROQ_API_KEY", "tool", false, "Groq API key for Whisper transcription"),
            row("FIRECRAWL_API_KEY", "tool", true, "Firecrawl API key for web extraction")
        ])
    }()
}

/// "S’applique à" — the desktop's shared settings profile scope.
struct AccountsScopeSection: View {
    let app: AppModel
    @Binding var profile: String
    var note: String
    private var title: String { app.profiles.first { $0.name == profile }?.title ?? profile }
    var body: some View {
        Section {
            if app.profiles.count > 1 {
                AppPicker(title: "S’applique à", selection: $profile,
                          options: (app.profiles.contains(where: { $0.name == profile }) ? [] : [(value: profile, label: profile)]) + app.profiles.map { (value: $0.name, label: $0.title) },
                          systemImage: "person.crop.circle")
            } else {
                LabeledContent { Text(title) } label: { Label("S’applique à", systemImage: "person.crop.circle") }
            }
        } footer: { Text(note) }
    }
}

/// Status line for a credential: a dot plus the server's masked hint, never the value.
struct AccountsStatusLabel: View {
    let set: Bool
    var text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(set ? Color.green.opacity(0.8) : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}

/// An optional next step offered right after a key is saved (e.g. make ElevenLabs the voice).
struct AccountsFollowUp {
    struct Action {
        var label: String
        var done: String
        var run: @MainActor () async throws -> Void
    }
    var title: String
    var message: String
    var actions: [Action]
}

/// Edit, replace or remove one env credential.
struct AccountsCredentialEditor: View {
    let store: AccountsEnvStore
    let key: String
    let profileTitle: String
    var providerSetup = false
    var followUp: AccountsFollowUp?
    var saved: (() -> Void)?
    @State private var value = ""
    @State private var removing = false
    @State private var offering = false
    @State private var confirmation: String?
    @FocusState private var focused: Bool
    private var row: AccountsCredential? { store.rows[key] }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row?.title ?? key).font(.headline)
                    Text(key).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    AccountsStatusLabel(set: row?.isSet == true, text: row?.status ?? "Non définie")
                }.padding(.vertical, 4)
            } footer: {
                if let detail = row?.detail, !detail.isEmpty { Text(detail) }
            }
            Section {
                Group {
                    if row?.isPassword ?? true {
                        SecureField(row?.isSet == true ? "Nouvelle valeur" : "Coller la clé", text: $value)
                    } else {
                        TextField(row?.isSet == true ? "Nouvelle valeur" : "Valeur", text: $value)
                    }
                }.textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                    .accessibilityIdentifier("credential-value")
                Button {
                    Task {
                        let ok = await store.save(key, value: value, providerSetup: providerSetup)
                        if ok {
                            value = ""; focused = false; confirmation = "\(key) mis à jour."; saved?()
                            if followUp != nil { offering = true }
                        }
                    }
                } label: {
                    HStack { Text(row?.isSet == true ? "Remplacer" : "Enregistrer"); if store.tools.busy { Spacer(); ProgressView() } }
                }.disabled(value.trimmingCharacters(in: .whitespaces).isEmpty || store.tools.busy || store.tools.app.demo)
            } header: {
                Text(row?.isSet == true ? "Remplacer la valeur actuelle" : "Définir")
            } footer: {
                Text("La valeur est envoyée à Hermes pour « \(profileTitle) » puis effacée de ce champ. Hermès iOS ne la conserve pas.")
            }
            if let confirmation { Section { Label(confirmation, systemImage: "checkmark.circle").foregroundStyle(.green) } }
            ToolFeedback(tools: store.tools)
            if let url = row?.url {
                Section { Link(destination: url) { Label("Obtenir une clé", systemImage: "arrow.up.right.square") } }
            }
            if row?.isSet == true {
                Section { Button("Supprimer", role: .destructive) { removing = true }.disabled(store.tools.busy || store.tools.app.demo) }
            }
        }.modernList().navigationTitle(row?.title ?? key).navigationBarTitleDisplayMode(.inline)
            .appConfirm("Supprimer \(key) de .env ?", isPresented: $removing) {
                Button("Supprimer", role: .destructive) {
                    Task { if await store.remove(key) { confirmation = "\(key) supprimé." } }
                }
            } message: { Text("La valeur stockée pour « \(profileTitle) » sera supprimée du serveur. Cette action ne peut pas être annulée depuis l’app.") }
            .appConfirm(followUp?.title ?? "", isPresented: $offering, cancel: nil) {
                ForEach(Array((followUp?.actions ?? []).enumerated()), id: \.offset) { _, action in
                    Button(action.label) {
                        Task {
                            var ok = false
                            await store.tools.perform { try await action.run(); ok = true }
                            if ok { confirmation = action.done }
                        }
                    }
                }
                Button("Plus tard", role: .cancel) { }
            } message: { Text(followUp?.message ?? "") }
            .onDisappear { value = "" }
    }
}

/// A gentle placeholder for the interactive preview.
struct AccountsDemoNotice: View {
    var body: some View {
        Section {
            Label("Aperçu : connectez votre Hermes pour gérer ces réglages sur votre serveur.", systemImage: "info.circle")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// Copyable command shown for flows that only work from the desktop app or the CLI.
struct AccountsCommandRow: View {
    let command: String
    @State private var copied = false
    var body: some View {
        HStack {
            Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: 8)
            Button {
                UIPasteboard.general.string = command; copied = true
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 32, height: 32) }
                .buttonStyle(.borderless).accessibilityLabel("Copier la commande")
        }
    }
}

/// Identifiable wrapper so JSON rows can drive `.sheet(item:)`.
struct AccountsIdentified: Identifiable {
    let value: JSONValue
    var id: String { value["id"].string.isEmpty ? value["name"].string : value["id"].string }
}
