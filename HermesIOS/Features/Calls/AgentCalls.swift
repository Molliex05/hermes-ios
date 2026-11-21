import AVFoundation
import CallKit
import Foundation
import PushKit
import UIKit
@preconcurrency import UserNotifications

/// The agent calls Maxime. The server rings the iPhone with a VoIP push at the moment the agent planned (a shift: halfway
/// through the drive); CallKit shows « Jarvis » like any call, on the Lock Screen, the AirPods, the watch or the car's
/// screen. The push carries only the call's number; the reason is fetched from the server once the call is answered.
///
/// Answered in the car or unlocked, the call becomes the usual voice conversation and the agent speaks first. Answered on a
/// locked iPhone elsewhere, the iPhone says a short briefing itself and the agent (who reads mail and the calendar) is
/// reached only once Face ID unlocks it (`AgentCallPlan`). Missed or declined, the briefing arrives as a notification.
@MainActor
final class AgentCalls: NSObject {
    static let shared = AgentCalls()
    nonisolated static let missedCategory = "hermes.call.missed", callBackAction = "hermes.call.back"

    /// Installed by the app at launch, background launches included (a VoIP push may be what launched it).
    private var model: AppModel?
    private let provider: CXProvider
    private let controller = CXCallController()
    private var registry: PKPushRegistry?
    private let speech = AVSpeechSynthesizer()

    private struct Call {
        let uuid: UUID, id: String, profile: String, agent: String
        var answered = false, conversation = false, briefed = ""
    }
    private var call: Call?
    private var unlockObserver: NSObjectProtocol?
    private var waitForUnlock: Task<Void, Never>?

    private override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false        // « Rappeler » goes through the app, never the Phone app
        if let mark = UIImage(systemName: "waveform") { configuration.iconTemplateImageData = mark.pngData() }
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)               // nil: the main queue
    }

    func start(_ model: AppModel) {
        self.model = model
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        let back = UNNotificationAction(identifier: Self.callBackAction, title: "Rappeler", options: [.foreground])
        PushNotifications.shared.extraCategories = [UNNotificationCategory(identifier: Self.missedCategory, actions: [back], intentIdentifiers: [], options: [])]
    }

    // MARK: Ringing

    private func ring(id: String, profile: String, agent: String) {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: agent)
        update.localizedCallerName = agent
        update.hasVideo = false
        update.supportsHolding = false; update.supportsGrouping = false; update.supportsUngrouping = false; update.supportsDTMF = false
        // A second call while one is under way is refused at once: CallKit must still hear about it (PushKit's rule).
        let busy = call != nil
        if !busy { call = Call(uuid: uuid, id: id, profile: profile, agent: agent) }
        provider.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                if busy || failed {
                    if !busy { self.call = nil }
                    self.provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                    return
                }
                self.model.map { model in Task { await model.reportAgentCall(id, outcome: "ringing") } }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(AgentCallPlan.ringSeconds))
                    guard let self, let call = self.call, call.uuid == uuid, !call.answered else { return }
                    self.provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
                    await self.missed(call, outcome: "missed")
                }
            }
        }
    }

    // MARK: Answered

    /// CallKit has activated the audio: the call goes on, as a conversation or as a briefing.
    private func began() async {
        guard var current = call, current.answered else { return }
        let carAudio = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
        let mode = AgentCallPlan.mode(carAudio: carAudio, unlocked: UIApplication.shared.isProtectedDataAvailable)
        let reason = await model?.agentCallReason(current.id) ?? ""
        guard call?.uuid == current.uuid else { return }
        switch mode {
        case .conversation:
            await converse(reason: reason)
        case .briefing:
            let text = briefing(for: current, reason: reason)
            current.briefed = text; call = current
            say(text + " " + AgentCallPlan.unlockPrompt(agent: current.agent))
            awaitUnlock(reason: reason)
        }
    }

    private func converse(reason: String) async {
        guard var current = call, let model else { return }
        stopWaiting()
        speech.stopSpeaking(at: .immediate)
        current.conversation = true; call = current
        if let problem = await model.startBackgroundCall(profile: current.profile, opening: AgentCallPlan.opening(reason: reason)) {
            say(problem)
            try? await Task.sleep(for: .seconds(4))
            end()
        }
    }

    private func awaitUnlock(reason: String) {
        stopWaiting()
        unlockObserver = NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.converse(reason: reason) } }
        }
        waitForUnlock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AgentCallPlan.unlockWaitSeconds + 15))
            guard !Task.isCancelled, let self, self.call?.conversation == false else { return }
            self.end()
        }
    }

    private func stopWaiting() {
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
        unlockObserver = nil
        waitForUnlock?.cancel(); waitForUnlock = nil
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = LocalSpeech.bestFrenchVoice()
        speech.speak(utterance)
    }

    /// The briefing from what the iPhone already holds for the widgets: never mail, never an amount.
    private func briefing(for call: Call, reason: String) -> String {
        let boards = AgentBoardStore.read()
        let now = Date.now
        let next = boards?.agendas[call.profile].flatMap { $0.isExpired(at: now) ? nil : $0 }?.items
            .first { item in (item.until ?? item.at.map { $0.addingTimeInterval(15 * 60) } ?? .distantFuture) > now }
        let weather = boards?.weather.flatMap { $0.isExpired(at: now) ? nil : $0 }
        let desk = boards?.boards.first { BoardRole(profile: $0.key) == .desk }.flatMap { $0.value.isExpired(at: now) ? nil : BoardDesk($0.value.items) }
        let pay = boards?.blocks[call.profile]?.first { $0.slot == "paie" && !$0.isExpired(at: now) }
            .map { [$0.title, $0.text].filter { !$0.isEmpty }.joined(separator: " : ") }
        return AgentCallPlan.briefing(agent: call.agent, reason: reason, next: next, weather: weather, desk: desk, pay: pay)
    }

    // MARK: Ended

    /// The voice conversation ended on its own (said goodbye, hung up on screen): the CallKit call ends with it.
    func voiceEnded() {
        guard let current = call, current.conversation else { return }
        end(current.uuid)
    }

    private func end(_ uuid: UUID? = nil) {
        guard let uuid = uuid ?? call?.uuid else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: uuid))) { _ in }
    }

    private func finished(_ uuid: UUID) {
        guard call?.uuid == uuid else { return }
        stopWaiting()
        speech.stopSpeaking(at: .immediate)
        call = nil
    }

    /// Missed or declined: the briefing as a notification, with « Rappeler ».
    private func missed(_ missedCall: Call, outcome: String) async {
        finished(missedCall.uuid)
        let reason = await model?.agentCallReason(missedCall.id) ?? ""
        let content = UNMutableNotificationContent()
        content.title = "Appel manqué de \(missedCall.agent)"
        content.body = briefing(for: missedCall, reason: reason)
        content.categoryIdentifier = Self.missedCategory
        content.userInfo = ["hermes_call_back": missedCall.profile]
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call-\(missedCall.id)", content: content, trigger: nil))
        await model?.reportAgentCall(missedCall.id, outcome: outcome)
    }

    /// « Rappeler » on the missed call's notification: the app is open and unlocked, the usual call starts.
    func callBack(_ profile: String) {
        Task { _ = await CallLauncher.start?(profile) }
    }
}

// MARK: - PushKit

/// The registry's queue is the main queue (`PKPushRegistry(queue: .main)`).
extension AgentCalls: @preconcurrency PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        PushNotifications.shared.receiveVoIPToken(credentials.token.map { String(format: "%02x", $0) }.joined())
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        PushNotifications.shared.receiveVoIPToken(nil)
    }

    /// iOS ends an app that receives a VoIP push without reporting a call: every push rings, even a malformed one (which
    /// then ends at once).
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType,
                      completion: @escaping () -> Void) {
        let hermes = payload.dictionaryPayload["hermes"] as? [String: Any] ?? [:]
        let id = hermes["call"] as? String ?? "", profile = hermes["profile"] as? String ?? ""
        let agent = (hermes["agent"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(40)) } ?? "Hermès"
        ring(id: id.isEmpty ? UUID().uuidString : id, profile: profile, agent: agent)
        if id.isEmpty || profile.isEmpty, let uuid = call?.uuid {       // malformed: rung, then ended at once, nothing missed
            provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
            finished(uuid)
        }
        completion()
    }
}

// MARK: - CallKit

/// The provider's delegate queue is the main queue (`setDelegate(_:queue: nil)`), so these run on the main actor.
extension AgentCalls: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        if let uuid = call?.uuid { finished(uuid) }
        model?.backgroundCall?.endCall()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard var current = call, current.uuid == action.callUUID else { action.fail(); return }
        current.answered = true; call = current
        // The voice's own settings, so CallKit activates the session the conversation will use.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .bluetoothCall])
        if let model { Task { await model.reportAgentCall(current.id, outcome: "answered") } }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { await began() }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let current = call, current.uuid == action.callUUID else { action.fulfill(); return }
        if !current.answered {
            Task { await missed(current, outcome: "declined") }
        } else {
            if current.conversation { model?.backgroundCall?.endCall() }
            finished(current.uuid)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        if let voice = model?.backgroundCall, voice.inputMuted != action.isMuted { voice.toggleMicrophone() }
        action.fulfill()
    }
}
