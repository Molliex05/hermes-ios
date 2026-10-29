import Foundation

/// Something asked of the app from outside it: a widget tap, a Siri phrase or a Shortcut, the share sheet.
struct LaunchRequest: Equatable, Identifiable {
    enum Kind: Equatable {
        case open
        case voice
        /// `send: false` only fills the composer: what an agent wrote on a widget is never sent by a tap alone.
        case ask(text: String, send: Bool)
    }
    let id = UUID()
    var profile: String?
    var kind: Kind
}

/// Intents run in the app's own process, possibly before the model exists (a cold launch from Siri): requests wait here
/// until the model takes them over.
@MainActor final class LaunchBridge {
    static let shared = LaunchBridge()
    private var waiting: [LaunchRequest] = []
    private var handler: (@MainActor (LaunchRequest) -> Void)?

    func send(_ request: LaunchRequest) {
        if let handler { handler(request) } else { waiting.append(request) }
    }

    func attach(_ handler: @escaping @MainActor (LaunchRequest) -> Void) {
        self.handler = handler
        let pending = waiting
        waiting = []
        pending.forEach(handler)
    }
}

extension AppModel {
    func enqueue(_ request: LaunchRequest) {
        launchQueue.append(request)
        guard !launching else { return }
        launching = true
        Task { await runLaunchQueue(); launching = false }
    }

    /// What the share sheet left: each item goes to its agent as a new conversation.
    func collectShares() {
        for item in ShareInbox.take() where !item.message.isEmpty {
            enqueue(LaunchRequest(profile: item.profile, kind: .ask(text: item.message, send: true)))
        }
    }

    /// One request at a time, once the app is connected and idle. If it cannot be done in time the text is put in the
    /// composer, never lost.
    private func runLaunchQueue() async {
        while let request = launchQueue.first {
            let ready = await waitUntilReady()
            if !ready {
                if case .ask(let text, _) = request.kind, draft.isEmpty { draft = text; composerFocusRequest = UUID() }
                launchQueue.removeFirst()
                continue
            }
            if let name = request.profile, name != profile, profiles.contains(where: { $0.name == name }) { await changeProfile(name) }
            switch request.kind {
            case .open:
                break
            case .voice:
                pendingVoiceLaunch = true
            case .ask(let text, let send):
                newChat()
                if send, canSendQuickReply { await sendQuickReply(text) }
                else { draft = text; composerFocusRequest = UUID() }
            }
            launchQueue.removeFirst()
        }
    }

    private func waitUntilReady() async -> Bool {
        for _ in 0..<60 {
            if notificationRoutingReady, connections.isEmpty, !demo { return false }
            if notificationRoutingReady, state == .connected || demo, !opening, !sending, !voiceActive, !transcript.running { return true }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return false }
        }
        return false
    }
}
