import AppIntents
import AVFoundation
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

/// The same call from the car, where the iPhone stays locked in a pocket and Face ID cannot be asked: Siri on CarPlay
/// (« Appeler Jarvis en voiture avec Hermès ») or the car's widget. It only runs while the sound goes out through the car
/// (CarPlay); anywhere else it refuses and points to the Face ID call. Being at the wheel of a car this iPhone was paired
/// with (pairing needs the iPhone unlocked) stands in for Face ID, as Siri reading messages on CarPlay already does.
struct CarCallIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Appeler un agent en voiture"
    static let description = IntentDescription("Démarre un appel vocal sans déverrouiller l’iPhone, seulement quand il est connecté à la voiture (CarPlay).")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Agent") var agent: AgentEntity?

    init() {}
    init(agent: AgentEntity?) { self.agent = agent }

    static var parameterSummary: some ParameterSummary { Summary("Appeler \(\.$agent) en voiture") }

    @MainActor func perform() async throws -> some IntentResult {
        guard AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .carAudio }) else {
            throw CallLaunchError("Cette commande marche seulement quand l’iPhone est connecté à la voiture. Sinon, dites « Appeler Jarvis sans ouvrir Hermès ».")
        }
        guard let start = CallLauncher.start else { throw CallLaunchError("Ouvrez l’app Hermès une fois, puis réessayez.") }
        if let problem = await start(agent?.id) { throw CallLaunchError(problem) }
        return .result()
    }
}

/// Installed by the app at launch: starts the call and answers once its Live Activity is up, or says why it could not.
@MainActor
enum CallLauncher {
    static var start: ((_ profile: String?) async -> String?)?
    /// The call planned within the next 90 minutes, taken from the server (`CarTripIntent`).
    static var claimTrip: (() async -> (id: String, profile: String, agent: String, reason: String)?)?
}

struct CallLaunchError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}
