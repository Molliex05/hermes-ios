import Foundation

/// What the chat shows: its messages, the shape of a conversation that is still loading, or the welcome (greeting and
/// suggestions) of a new one. The transcript, the header and the backdrop follow this one rule, so opening a conversation
/// never flashes the welcome, its glow or its folded title before the messages arrive.
enum ChatStage: Equatable, Sendable {
    case messages, loading, welcome

    /// `awaitingServer`: an existing conversation that Hermes has not delivered yet (not connected, not attached), e.g.
    /// one opened from a notification while the app reconnects. It loads; it is never a new conversation to start.
    static func of(hasContent: Bool, hasSelection: Bool, opening: Bool, awaitingServer: Bool) -> ChatStage {
        if hasContent { return .messages }
        return hasSelection && (opening || awaitingServer) ? .loading : .welcome
    }
}
