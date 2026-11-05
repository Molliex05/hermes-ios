import AppIntents
import WidgetKit

/// The « Vu » button on the widget: the user has read the lines on screen. It runs in the widget's own process with no app
/// launch, so it only notes them: the widget hides them at once, and the app tells the server on its next refresh
/// (`WidgetRefresh`), which takes them off the agent's board for good and archives the emails they were about.
struct MarkSeenIntent: AppIntent {
    static let title: LocalizedStringResource = "Marquer comme vu"
    static let isDiscoverable = false

    @Parameter(title: "Agent") var profile: String
    /// The texts of the lines on screen, one per line (a board's texts never hold a line break).
    @Parameter(title: "Lignes") var lines: String
    /// The agent's note when it was on screen.
    @Parameter(title: "Note") var note: String

    init() {}
    init(profile: String, lines: [String], note: String) {
        self.profile = profile; self.lines = lines.joined(separator: "\n"); self.note = note
    }

    func perform() async throws -> some IntentResult {
        var shown = lines.split(separator: "\n").map(String.init)
        var focus = note
        // Nothing named (an older widget's button): everything the agent has up that is not already marked.
        if shown.isEmpty && focus.isEmpty,
           let board = AgentBoardStore.read()?.boards[profile]?.hiding(BoardDismissals.read().filter { $0.profile == profile }) {
            shown = board.items.map(\.text); focus = board.focus
        }
        if !shown.isEmpty || !focus.isEmpty { BoardDismissals.add(SeenMark(profile: profile, lines: shown, focus: focus)) }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
