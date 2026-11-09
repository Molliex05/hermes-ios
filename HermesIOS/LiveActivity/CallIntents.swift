import AppIntents
import Foundation

/// Starts a voice call with an agent without opening the app: after Face ID the call runs in the background and shows in
/// the Dynamic Island and on the Lock Screen (mute, hang up). An `AudioRecordingIntent` is iOS's one way to start the
/// microphone from the background, on condition that a Live Activity shows it: the call's own activity does.
/// Compiled into the app and the widgets (the Lock Screen widget and the control); it always runs in the app's process.
struct StartCallIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Appeler un agent"
    static let description = IntentDescription("Démarre un appel vocal avec Jarvis, Hermès ou un autre agent sans ouvrir l’app. Face ID est demandé.")
    static let openAppWhenRun = false
    /// The agents read mail, the calendar and accounts: never from a locked phone in someone else's hands.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Agent") var agent: AgentEntity?

    init() {}
    init(agent: AgentEntity?) { self.agent = agent }

    static var parameterSummary: some ParameterSummary { Summary("Appeler \(\.$agent)") }

    @MainActor func perform() async throws -> some IntentResult {
        let profile = agent?.id
        guard let start = CallLauncher.start else { throw CallLaunchError("Ouvrez l’app Hermès une fois, puis réessayez.") }
        if let problem = await start(profile) { throw CallLaunchError(problem) }
        return .result()
    }
}

/// Installed by the app at launch: starts the call and answers once its Live Activity is up, or says why it could not.
@MainActor
enum CallLauncher {
    static var start: ((_ profile: String?) async -> String?)?
}

struct CallLaunchError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
