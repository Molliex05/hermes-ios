import AppIntents
import Foundation

/// Buttons on the Live Activity (Lock Screen and Dynamic Island). A `LiveActivityIntent` runs in the app's process,
/// so the widget extension only declares the buttons; the app installs the handler that acts on the call.
enum ActivityAction: String, Sendable { case toggleMute, endCall, stopReply }

@MainActor
enum ActivityActions {
    static var handler: ((ActivityAction) -> Void)?
}

struct ToggleMuteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Couper ou activer le micro"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { ActivityActions.handler?(.toggleMute) }
        return .result()
    }
}

struct EndCallIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Terminer l’appel"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { ActivityActions.handler?(.endCall) }
        return .result()
    }
}

struct StopReplyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter la réponse"
    static let isDiscoverable = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { ActivityActions.handler?(.stopReply) }
        return .result()
    }
}
