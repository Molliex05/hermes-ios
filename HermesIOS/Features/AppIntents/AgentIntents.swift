import AppIntents

/// « Demande à Jarvis… » from Siri, the Action button, a Shortcut or an automation. What is spoken or written here is
/// the user's own request, so it is sent as it is; the app opens on the answer.
struct AskAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Demander à un agent"
    static let description = IntentDescription("Envoie une demande à Jarvis, Hermès ou un autre agent et ouvre la réponse.")
    static let openAppWhenRun = true

    @Parameter(title: "Demande", requestValueDialog: "Que voulez-vous demander ?") var text: String
    @Parameter(title: "Agent") var agent: AgentEntity

    static var parameterSummary: some ParameterSummary { Summary("Demander \(\.$text) à \(\.$agent)") }

    @MainActor func perform() async throws -> some IntentResult {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .result() }
        LaunchBridge.shared.send(LaunchRequest(profile: agent.id, kind: .ask(text: String(message.prefix(4_000)), send: true)))
        return .result()
    }
}

/// A voice call with an agent, in one phrase or one tap.
struct TalkToAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Parler à un agent"
    static let description = IntentDescription("Ouvre un appel vocal avec Jarvis, Hermès ou un autre agent.")
    static let openAppWhenRun = true

    @Parameter(title: "Agent") var agent: AgentEntity

    static var parameterSummary: some ParameterSummary { Summary("Parler à \(\.$agent)") }

    @MainActor func perform() async throws -> some IntentResult {
        LaunchBridge.shared.send(LaunchRequest(profile: agent.id, kind: .voice))
        return .result()
    }
}

/// The phrases Siri knows without any setup, and the tiles in the Shortcuts app.
struct AgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToAgentIntent(),
                    phrases: ["Parler à \(\.$agent) dans \(.applicationName)", "Appeler \(\.$agent) dans \(.applicationName)", "Parler dans \(.applicationName)"],
                    shortTitle: "Parler à un agent", systemImageName: "waveform")
        AppShortcut(intent: AskAgentIntent(),
                    phrases: ["Demander à \(\.$agent) dans \(.applicationName)", "Demander dans \(.applicationName)"],
                    shortTitle: "Demander à un agent", systemImageName: "text.bubble")
    }
}
