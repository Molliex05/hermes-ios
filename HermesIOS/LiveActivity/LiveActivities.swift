import ActivityKit
import Foundation

/// Starts, updates and ends the app's Live Activities. Best effort: when the user turned Live Activities off,
/// or the system refuses, everything here is a quiet no-op. At most one call and one reply at a time.
/// ActivityKit's `Activity` is not `Sendable`; every use below happens on one detached task per call.
private struct ActivityBox: @unchecked Sendable { let activity: Activity<HermesActivityAttributes> }

@MainActor
final class LiveActivities {
    static let shared = LiveActivities()

    /// Sends a reply activity's push token to the server (set by `AppModel`). Calls never register: the app is alive.
    var register: (@Sendable (_ token: String, _ activityID: String, _ startedAt: Double) async -> Void)?
    var unregister: (@Sendable (_ activityID: String) async -> Void)?

    private var call: Activity<HermesActivityAttributes>?
    private var callStart = Date()
    private var reply: Activity<HermesActivityAttributes>?
    private var replyStart = Date()
    private var replyTokens: Task<Void, Never>?
    private var callBeat: Task<Void, Never>?
    private var callState: HermesActivityAttributes.ContentState?
    /// A call card goes stale (« Appel interrompu ») this long after the app last confirmed it: if the app is force-quit
    /// nothing else can tell the system the call is over.
    private static let callStale: TimeInterval = 110

    private var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // MARK: Voice call

    func startCall(title: String, profile: String, phase: String, muted: Bool) {
        callStart = Date()
        guard call == nil, enabled else { return }
        let state = HermesActivityAttributes.ContentState.call(title: title, phase: phase, muted: muted, startedAt: callStart)
        callState = state
        call = try? Activity.request(attributes: .init(kind: "call", profile: profile), content: .init(state: state, staleDate: .now.addingTimeInterval(Self.callStale)), pushType: nil)
        startBeat()
    }

    /// Refreshes the stale date every ~50 s while the call is really alive.
    private func startBeat() {
        callBeat?.cancel()
        callBeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(50))
                guard !Task.isCancelled, let self, let call = self.call, let state = self.callState else { return }
                let box = ActivityBox(activity: call)
                await Task.detached { await box.activity.update(.init(state: state, staleDate: .now.addingTimeInterval(Self.callStale))) }.value
            }
        }
    }

    /// At launch no call can be running: end any card left behind by an app that was force-quit or crashed.
    func endOrphans() {
        for activity in Activity<HermesActivityAttributes>.activities where activity.id != call?.id && activity.id != reply?.id {
            let box = ActivityBox(activity: activity)
            Task.detached { await box.activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func updateCall(title: String, phase: String, muted: Bool) {
        guard let call else { return }
        let state = HermesActivityAttributes.ContentState.call(title: title, phase: phase, muted: muted, startedAt: callStart)
        callState = state
        let box = ActivityBox(activity: call)
        Task.detached { await box.activity.update(.init(state: state, staleDate: .now.addingTimeInterval(Self.callStale))) }
    }

    func endCall() {
        callBeat?.cancel(); callBeat = nil; callState = nil
        guard let activity = call else { return }
        call = nil
        let box = ActivityBox(activity: activity)
        Task.detached { await box.activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: Reply in progress

    func startReply(title: String, profile: String) {
        guard reply == nil, call == nil, enabled else { return }
        replyStart = Date()
        let state = HermesActivityAttributes.ContentState(phase: "working", title: title, detail: "Réfléchit…", muted: false, startedAt: replyStart.timeIntervalSince1970)
        guard let activity = try? Activity<HermesActivityAttributes>.request(attributes: .init(kind: "reply", profile: profile), content: .init(state: state, staleDate: nil), pushType: .token) else { return }
        reply = activity
        let started = replyStart.timeIntervalSince1970, identifier = activity.id, register = register
        let box = ActivityBox(activity: activity)
        replyTokens = Task.detached {
            for await token in box.activity.pushTokenUpdates { await register?(token.map { String(format: "%02x", $0) }.joined(), identifier, started) }
        }
    }

    func updateReply(detail: String) {
        guard let reply else { return }
        let state = HermesActivityAttributes.ContentState(phase: "working", title: reply.content.state.title, detail: detail, muted: false, startedAt: replyStart.timeIntervalSince1970)
        let box = ActivityBox(activity: reply)
        Task.detached { await box.activity.update(.init(state: state, staleDate: nil)) }
    }

    /// A call starts: any reply activity goes away at once.
    func endReply(quiet: Bool) {
        guard let activity = reply else { return }
        reply = nil
        replyTokens?.cancel(); replyTokens = nil
        let identifier = activity.id, unregister = unregister
        let box = ActivityBox(activity: activity)
        Task.detached { await box.activity.end(nil, dismissalPolicy: .immediate); await unregister?(identifier) }
    }

    /// The turn finished. In the foreground the activity just disappears; otherwise it stays as « Réponse prête ».
    func finishReply(foreground: Bool) {
        guard let activity = reply else { return }
        reply = nil
        replyTokens?.cancel(); replyTokens = nil
        let identifier = activity.id, unregister = unregister
        let state = HermesActivityAttributes.ContentState(phase: "done", title: activity.content.state.title, detail: "Réponse prête", muted: false, startedAt: replyStart.timeIntervalSince1970)
        let box = ActivityBox(activity: activity)
        Task.detached {
            await box.activity.end(.init(state: state, staleDate: nil), dismissalPolicy: foreground ? .immediate : .after(.now + 15 * 60))
            await unregister?(identifier)
        }
    }
}
