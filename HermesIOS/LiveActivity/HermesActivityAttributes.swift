import ActivityKit
import Foundation

/// A Live Activity for a voice call (`call`, driven by the app) or a reply in progress (`reply`, updated by
/// the app while it runs and by the server's push afterwards). The content-state keys are a contract with the
/// `hermes-ios-push` plugin (`phase`, `title`, `detail`, `muted`, `startedAt`): rename none of them.
/// Never put conversation text in a reply's state: Live Activity pushes travel through Apple without end-to-end encryption.
/// A call is only ever updated by the app itself, so its card glance stays on the device.
struct HermesActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// listening, thinking, speaking, waiting, paused (calls) · working, done (replies)
        var phase: String
        var title: String
        var detail: String
        var muted: Bool
        /// Seconds since 1970: the elapsed timer keeps counting without further updates.
        var startedAt: Double
        /// Calls only: the newest card the agent showed, set by the app on the device. A reply's state is pushed by the
        /// server and never carries one.
        var glance: CardGlance? = nil

        var start: Date { Date(timeIntervalSince1970: startedAt) }
        var isFinished: Bool { phase == "done" }
    }

    var kind: String
    var profile: String
}

extension HermesActivityAttributes.ContentState {
    static func call(title: String, phase: String, muted: Bool, startedAt: Date, glance: CardGlance? = nil) -> Self {
        .init(phase: phase, title: title, detail: detail(forCallPhase: phase, muted: muted), muted: muted, startedAt: startedAt.timeIntervalSince1970, glance: glance)
    }

    static func detail(forCallPhase phase: String, muted: Bool) -> String {
        if muted { return "Micro coupé" }
        switch phase {
        case "listening": return "Je vous écoute"
        case "thinking": return "Réfléchit…"
        case "speaking": return "Répond"
        case "waiting": return "Attend votre réponse"
        case "paused": return "En pause"
        default: return "Appel vocal"
        }
    }
}
