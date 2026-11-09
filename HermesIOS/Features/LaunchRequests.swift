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
    /// The share-sheet item this comes from: it leaves the shared inbox only once it has been handled.
    var shareID: String?
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

    /// What the share sheet left: each item goes to its agent as a new conversation. An item stays in the inbox until it has
    /// been sent (or put in the composer), so a request cut short by a closed app is picked up again at the next launch.
    func collectShares() {
        for item in ShareInbox.read() where !item.message.isEmpty && !queuedShareIDs.contains(item.id) {
            queuedShareIDs.insert(item.id)
            enqueue(LaunchRequest(profile: item.profile, kind: .ask(text: item.message, send: true), shareID: item.id))
        }
    }

    /// One request at a time, once the app is connected and idle.
    private func runLaunchQueue() async {
        while let request = launchQueue.first {
            await perform(request)
            if let id = request.shareID { ShareInbox.remove(ids: [id]); queuedShareIDs.remove(id) }
            launchQueue.removeFirst()
        }
    }

    private func perform(_ request: LaunchRequest) async {
        guard await waitUntilReady() else {
            keep(request, notice: "Votre demande est dans le champ de saisie : l’agent n’était pas disponible.")
            return
        }
        var target = profile
        if let name = request.profile {
            // An agent that is gone (hidden, renamed) never receives a text meant for it, and never another agent either.
            guard profiles.contains(where: { $0.name == name }) else {
                keep(request, notice: "L’agent « \(name) » est introuvable : votre texte est dans le champ de saisie.")
                return
            }
            if name != profile { await changeProfile(name) }
            target = name
        }
        // The switch awaits the network: something may have started meanwhile, and then nothing is sent anywhere.
        guard profile == target else {
            keep(request, notice: "Votre demande est dans le champ de saisie : une autre action était en cours.")
            return
        }
        switch request.kind {
        case .open:
            break
        case .voice:
            pendingVoiceLaunch = true
        case .ask(let text, let send):
            newChat()
            guard send, selected == nil, canSendQuickReply else { keep(request); return }
            chatError = nil
            await sendQuickReply(text)
            if chatError != nil { keep(request) }              // the send failed: the text is not lost
        }
    }

    /// The text of an ask goes at the end of the composer (what is typed there stays), never nowhere.
    private func keep(_ request: LaunchRequest, notice message: String? = nil) {
        if case .ask(let text, _) = request.kind {
            draft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : draft + "\n\n" + text
            composerFocusRequest = UUID()
        }
        if let message { notice = message }
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
