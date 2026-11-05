import XCTest
@testable import HermesIOSCore

final class ChatStageTests: XCTestCase {
    func testContentAlwaysShowsTheMessages() {
        XCTAssertEqual(ChatStage.of(hasContent: true, hasSelection: true, opening: true, awaitingServer: true), .messages)
        XCTAssertEqual(ChatStage.of(hasContent: true, hasSelection: false, opening: false, awaitingServer: false), .messages)
    }

    func testANewConversationIsTheWelcome() {
        XCTAssertEqual(ChatStage.of(hasContent: false, hasSelection: false, opening: false, awaitingServer: false), .welcome)
        // Nothing selected: even a reconnect in progress is no reason to show a loading conversation.
        XCTAssertEqual(ChatStage.of(hasContent: false, hasSelection: false, opening: true, awaitingServer: true), .welcome)
    }

    func testAnUncachedConversationLoadsWhileItOpens() {
        XCTAssertEqual(ChatStage.of(hasContent: false, hasSelection: true, opening: true, awaitingServer: false), .loading)
    }

    func testAConversationOpenedWhileReconnectingLoadsInsteadOfGreeting() {
        // A notification tapped on a cold launch: the conversation is selected before the socket is up.
        XCTAssertEqual(ChatStage.of(hasContent: false, hasSelection: true, opening: false, awaitingServer: true), .loading)
    }

    func testADeliveredEmptyConversationIsTheWelcome() {
        XCTAssertEqual(ChatStage.of(hasContent: false, hasSelection: true, opening: false, awaitingServer: false), .welcome)
    }
}
