import AppIntents
import WidgetKit

/// The « Vu » button on the widget: the user has read what the agent put there, so it is cleared from the screen. It runs in
/// the widget's own process with no app launch and only remembers which board was seen (by its signature); the server and the
/// agent are untouched, and whatever the agent writes next shows again.
struct MarkSeenIntent: AppIntent {
    static let title: LocalizedStringResource = "Marquer comme vu"
    static let isDiscoverable = false

    @Parameter(title: "Agent") var profile: String

    init() {}
    init(profile: String) { self.profile = profile }

    func perform() async throws -> some IntentResult {
        if let board = AgentBoardStore.read()?.boards[profile] { BoardDismissals.dismiss(profile: profile, signature: board.signature) }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
