import Foundation
import Observation

/// Configuration of one Hermes agent (profile), shared by every settings page of that agent.
/// Requests are pinned to `profile`, whatever conversation is open.
@MainActor @Observable
final class AgentConfigStore {
    let tools: NativeToolSession
    private(set) var config: JSONValue = .null
    private(set) var fields: [String: JSONValue] = [:]
    private(set) var defaults: JSONValue = .null
    private(set) var keys: [String] = []
    private(set) var loading = false
    var error: String?
    private(set) var saving: Set<String> = []
    /// `GET /api/model/options`, `/api/model/auxiliary`, `/api/model/info`.
    var modelOptions: JSONValue = .null
    var auxiliary: JSONValue = .null
    var modelInfo: JSONValue = .null
    /// Which credentials exist on the server (`is_set` only — values are never read).
    private(set) var credentials: [String: Bool] = [:]

    var app: AppModel { tools.app }
    var profile: String { tools.profile }
    var demo: Bool { app.demo }
    var loaded: Bool { !fields.isEmpty }
    var title: String { app.profiles.first { $0.name == profile }?.title ?? (profile == "default" ? "Hermes" : profile.capitalized) }
    var serverName: String { app.activeConnection?.name ?? "Aperçu interactif" }

    /// Fields the desktop shows although `DEFAULT_CONFIG` does not declare them.
    private static let extraFields: [String: JSONValue] = ["agent.reasoning_effort": ["type": "string"]]

    init(app: AppModel, profile: String) { tools = NativeToolSession(app, profile: profile) }

    // MARK: Loading

    func load() async {
        loading = true; error = nil
        defer { loading = false }
        if demo { applyDemo(); return }
        do {
            async let configRequest = tools.request("/api/config")
            async let schemaRequest = tools.request("/api/config/schema")
            async let defaultsRequest = tools.request("/api/config/defaults")
            let (loadedConfig, schema) = try await (configRequest, schemaRequest)
            let loadedDefaults = (try? await defaultsRequest) ?? .null
            config = loadedConfig; defaults = loadedDefaults
            var merged = schema["fields"].object
            for (key, field) in Self.extraFields where merged[key] == nil { merged[key] = field }
            fields = merged; keys = merged.keys.sorted()
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    func fetch(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        if demo { return SettingsDemo.response(path) }
        return try await tools.request(path, query: query)
    }

    func loadModelOptions(refresh: Bool = false) async {
        do {
            modelOptions = try await fetch("/api/model/options", query: refresh ? [URLQueryItem(name: "refresh", value: "true")] : [])
        } catch is CancellationError {
        } catch { self.error = error.localizedDescription }
    }

    func loadAuxiliary() async {
        do { auxiliary = try await fetch("/api/model/auxiliary") }
        catch is CancellationError {}
        catch { self.error = error.localizedDescription }
    }

    func loadModelInfo() async { modelInfo = (try? await fetch("/api/model/info")) ?? .null }

    func loadCredentials() async {
        guard let rows = try? await fetch("/api/env") else { return }
        credentials = rows.object.mapValues { $0["is_set"].bool }
    }

    /// `nil` while unknown, `true` when any of the provider's credentials is set on the server.
    func hasCredential(for provider: String) -> Bool? {
        let names = SettingsCatalog.voiceKeyNames(provider)
        guard !names.isEmpty else { return true }
        guard !credentials.isEmpty else { return nil }
        return names.contains { credentials[$0] == true }
    }

    // MARK: Values

    func value(_ key: String) -> JSONValue { config.at(key) }

    /// The server default, or `nil` when `DEFAULT_CONFIG` has no such path.
    func defaultValue(_ key: String) -> JSONValue? {
        var current = defaults
        for part in key.split(separator: ".") {
            guard case .object(let object) = current, let next = object[String(part)] else { return nil }
            current = next
        }
        return current
    }

    func schema(_ key: String) -> JSONValue { fields[key] ?? Self.extraFields[key] ?? ["type": "string"] }

    func kind(_ key: String) -> ConfigFieldKind {
        SettingsCatalog.kind(key: key, schema: schema(key), value: value(key), defaultValue: defaultValue(key) ?? .null)
    }

    func isModified(_ key: String) -> Bool {
        if key == "model_context_length" { return value(key).double > 0 }
        return SettingsCatalog.isModified(value: value(key), defaultValue: defaultValue(key))
    }

    func description(_ key: String) -> String? { SettingsCatalog.description(key, schema: schema(key)) }

    func keys(on pageID: String) -> [String] { SettingsCatalog.keys(on: pageID, from: keys) }

    // MARK: Saving

    /// Optimistic save of one field through `PUT /api/config` (deep-merged by Hermes).
    @discardableResult
    func save(_ key: String, _ newValue: JSONValue) async -> Bool {
        await apply(JSONValue.patch(key, value: newValue), keys: [key])
    }

    @discardableResult
    func resetToDefault(_ key: String) async -> Bool {
        await save(key, key == "model_context_length" ? .number(0) : defaultValue(key) ?? .null)
    }

    @discardableResult
    func apply(_ patch: JSONValue, keys changed: [String]) async -> Bool {
        let previous = changed.map { ($0, value($0)) }
        config = Self.merge(config, patch)
        saving.formUnion(changed); error = nil
        defer { saving.subtract(changed) }
        if demo { return true }
        do {
            _ = try await tools.request("/api/config", method: "PUT", body: ["config": patch])
            return true
        } catch {
            for (key, old) in previous { config = Self.merge(config, JSONValue.patch(key, value: old)) }
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return false
        }
    }

    /// `POST /api/model/set`. Hermes asks for an explicit confirmation before an expensive model.
    enum Assignment { case done, needsConfirmation(String) }

    func assignModel(_ body: JSONValue) async throws -> Assignment {
        if demo {
            if body["scope"] == "main" {
                config = Self.merge(config, ["model": body["model"]])
                modelOptions = Self.merge(modelOptions, ["model": body["model"], "provider": body["provider"]])
            }
            return .done
        }
        let result = try await tools.request("/api/model/set", method: "POST", body: body)
        if result["confirm_required"].bool {
            let message = result["confirm_message"].string
            return .needsConfirmation(message.isEmpty ? "Ce modèle peut entraîner des coûts élevés. Hermes demande votre confirmation avant de l’utiliser." : message)
        }
        return .done
    }

    /// Reloads what a model change can affect.
    func refreshModels() async {
        async let options: Void = loadModelOptions()
        async let aux: Void = loadAuxiliary()
        async let info: Void = loadModelInfo()
        _ = await (options, aux, info)
        if !demo, let fresh = try? await tools.request("/api/config") { config = fresh }
    }

    nonisolated static func merge(_ source: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard case .object(let changes) = patch else { return patch }
        var result = source.object
        for (key, value) in changes { result[key] = merge(result[key] ?? .null, value) }
        return .object(result)
    }

    // MARK: Demo

    private func applyDemo() {
        config = SettingsDemo.config
        defaults = SettingsDemo.defaults
        var inferred: [String: JSONValue] = [:]
        func walk(_ value: JSONValue, _ prefix: String) {
            if case .object(let object) = value, !object.isEmpty {
                for (key, child) in object { walk(child, prefix.isEmpty ? key : prefix + "." + key) }
                return
            }
            let type: String = switch value {
            case .bool: "boolean"
            case .number: "number"
            case .array: "list"
            case .object: "object"
            default: "string"
            }
            inferred[prefix] = ["type": .string(type)]
        }
        walk(SettingsDemo.defaults, "")
        for (key, options) in SettingsDemo.selects { inferred[key] = ["type": "select", "options": .array(options.map(JSONValue.string))] }
        fields = inferred; keys = inferred.keys.sorted()
        credentials = ["OPENAI_API_KEY": true, "ELEVENLABS_API_KEY": false, "GROQ_API_KEY": false]
    }
}

/// Offline preview data, so the settings stay explorable without a server.
enum SettingsDemo {
    static let selects: [String: [String]] = [
        "approvals.mode": ["manual", "smart", "off"],
        "stt.provider": SettingsCatalog.sttProviders,
        "tts.provider": ["edge", "elevenlabs", "openai", "xai", "minimax", "mistral", "gemini", "neutts", "kittentts", "piper"],
        "agent.service_tier": ["", "normal", "fast", "auto", "cold"],
        "terminal.backend": ["local", "docker", "ssh", "modal", "daytona", "singularity"],
        "memory.provider": [""], "timezone": ["", "Europe/Paris", "America/New_York", "UTC"]
    ]

    static let defaults: JSONValue = [
        "model": "", "model_context_length": 0, "fallback_providers": [], "toolsets": ["hermes-cli"], "timezone": "",
        "display": ["personality": "", "show_reasoning": false],
        "agent": ["max_turns": .null, "api_max_retries": 3, "service_tier": "", "image_input_mode": "auto", "tool_use_enforcement": "auto"],
        "approvals": ["mode": "smart", "timeout": 300, "cron_mode": "deny", "single_query_mode": "deny", "unattended_mode": "deny",
                      "smart_policy": "", "denial_breaker_threshold": 3, "deny": [], "mcp_reload_confirm": true, "destructive_slash_confirm": true],
        "command_allowlist": [],
        "security": ["redact_secrets": true, "allow_private_urls": false],
        "checkpoints": ["enabled": false, "max_snapshots": 20],
        "browser": ["use_real_profile": false, "allow_private_urls": false, "auto_local_for_private_urls": true, "inactivity_timeout": 120],
        "memory": ["memory_enabled": true, "user_profile_enabled": true, "memory_char_limit": 2200, "user_char_limit": 1375, "provider": ""],
        "context": ["engine": "compressor"],
        "compression": ["enabled": true, "threshold": .number(0.5), "protect_last_n": 20],
        "terminal": ["cwd": "~/Projects", "backend": "local", "timeout": 180, "persistent_shell": true, "env_passthrough": []],
        "code_execution": ["mode": "project"], "file_read_max_chars": 100000,
        "tool_output": ["max_bytes": 50000, "max_lines": 2000, "max_line_length": 2000],
        "delegation": ["max_iterations": 250, "max_concurrent_children": 10, "reasoning_effort": ""],
        "voice": ["voice_chat_mode": "chained", "max_recording_seconds": 120, "auto_tts": false, "client_direct": true,
                  "silence_threshold": 200, "silence_duration": .number(3.0), "barge_in": true, "barge_in_grace_seconds": .number(0.5),
                  "barge_in_threshold_multiplier": .number(3.0), "stop_phrases": ["stop"],
                  "gpt_live": ["model": "gpt-live-1", "voice": "marin", "instructions": ""]],
        "stt": ["enabled": true, "provider": "local", "streaming": false, "echo_transcripts": true, "language": "en",
                "local": ["model": "base", "language": ""], "openai": ["model": "whisper-1", "streaming_model": "gpt-live-transcribe"],
                "elevenlabs": ["model_id": "scribe_v2", "language_code": ""]],
        "tts": ["provider": "edge", "edge": ["voice": "en-US-AriaNeural"], "openai": ["model": "gpt-4o-mini-tts", "voice": "alloy"],
                "elevenlabs": ["voice_id": "pNInz6obpgDQGcFmaJgB", "model_id": "eleven_multilingual_v2"]],
        "auxiliary": ["vision": ["provider": "auto", "model": "", "timeout": 120], "compression": ["provider": "auto", "model": "", "timeout": 120],
                      "voice_chat": ["provider": "auto", "model": "", "timeout": 120, "reasoning_effort": "none"]],
        "moa": ["save_traces": false],
        "updates": ["non_interactive_local_changes": "stash"]
    ]

    static var config: JSONValue {
        AgentConfigStore.merge(defaults, [
            "model": "Hermes", "timezone": "Europe/Paris",
            "voice": ["voice_chat_mode": "chained", "silence_duration": .number(1.2)],
            "stt": ["provider": "openai", "streaming": true, "language": "fr"],
            "tts": ["provider": "openai", "openai": ["voice": "nova"]],
            "fallback_providers": [["provider": "openrouter", "model": "anthropic/claude-sonnet-4.6"]],
            "command_allowlist": ["git status"]
        ])
    }

    static func response(_ path: String) -> JSONValue {
        switch path {
        case "/api/model/options": [
            "model": "Hermes", "provider": "nous",
            "providers": [
                ["slug": "nous", "name": "Nous Research", "models": ["Hermes", "Hermes-4-405B"], "is_current": true,
                 "capabilities": ["Hermes": ["reasoning": true, "fast": false]]],
                ["slug": "openrouter", "name": "OpenRouter", "models": ["anthropic/claude-sonnet-4.6", "openai/gpt-5.5", "google/gemini-3-flash"]]
            ]]
        case "/api/model/auxiliary": [
            "main": ["provider": "nous", "model": "Hermes"],
            "tasks": [["task": "vision", "provider": "auto", "model": ""], ["task": "compression", "provider": "auto", "model": ""],
                      ["task": "voice_chat", "provider": "openrouter", "model": "google/gemini-3-flash", "reasoning_effort": "none"]]]
        case "/api/model/info": ["model": "Hermes", "provider": "nous", "auto_context_length": 131072, "effective_context_length": 131072]
        case "/api/model/moa": [
            "default_preset": "default", "active_preset": "",
            "presets": ["default": ["enabled": true, "aggregator": ["provider": "openrouter", "model": "anthropic/claude-opus-4.8"],
                                    "reference_models": [["provider": "openrouter", "model": "openai/gpt-5.5", "enabled": true]]]]]
        case "/api/env": ["OPENAI_API_KEY": ["is_set": true], "ELEVENLABS_API_KEY": ["is_set": false]]
        case "/api/audio/elevenlabs/voices": ["available": false, "voices": []]
        case "/api/audio/voice-live/status": ["mode": "chained", "available": true]
        default: [:]
        }
    }
}
