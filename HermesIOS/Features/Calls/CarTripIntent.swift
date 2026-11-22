import AppIntents
import AVFoundation
import Foundation

/// « Topo de trajet » for a Shortcuts automation « When CarPlay connects »: if an agent planned a call within the next
/// 90 minutes (the drive to a shift), the iPhone rings now in the car and the server never rings it again. Nothing
/// planned: nothing happens, silently (an automation runs on every connection). Only through the car's audio, like
/// `CarCallIntent`: answered there, the call reaches the agent without Face ID.
struct CarTripIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Topo de trajet"
    static let description = IntentDescription("À lancer quand l’iPhone se connecte à CarPlay : si Jarvis a prévu de t’appeler pour ton trajet, il t’appelle tout de suite.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor func perform() async throws -> some IntentResult {
        // The automation can run a moment before the sound switches to the car.
        for _ in 0..<20 where !AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .carAudio }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { $0.portType == .carAudio }),
              let claim = await CallLauncher.claimTrip?() else { return .result() }
        AgentCalls.shared.ringFromCar(id: claim.id, profile: claim.profile, agent: claim.agent.isEmpty ? "Jarvis" : claim.agent, reason: claim.reason)
        return .result()
    }
}
