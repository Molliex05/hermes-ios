import XCTest
@testable import HermesIOSCore

final class ConversationActivityTests: XCTestCase {
    private func row(_ id: String = "chat", profile: String = "default", count: Int = 2, preview: String = "Bonjour", at date: Double = 100) -> Conversation {
        Conversation(["id": .string(id), "message_count": .number(Double(count)), "preview": .string(preview), "last_active": .number(date)], profile: profile)
    }

    func testInitialHistoryAndHeartbeatStayRead() {
        var state = ConversationActivity()
        state.observe([row()]); state.observe([row(at: 200)])
        XCTAssertFalse(state.isUnread(profile: "default", id: "chat"))
        state.observe([row(count: 4, at: 210)])
        XCTAssertTrue(state.isUnread(profile: "default", id: "chat"))
        state.markRead(profile: "default", id: "chat")
        state.observe([row(count: 4, at: 220)])
        XCTAssertFalse(state.hasUnread(profile: "default"))
    }

    func testPartialRosterCannotMarkInitialHistoryUnread() {
        var state = ConversationActivity()
        state.observe([row("bot", at: 50)], establishesBaseline: false)
        state.observe([row("old-a", at: 100), row("old-b", at: 150)], at: Date(timeIntervalSince1970: 150))
        XCTAssertFalse(state.hasUnread(profile: "default"))
        state.observe([row("new", at: 200)])
        XCTAssertTrue(state.isUnread(profile: "default", id: "new"))
    }

    func testDifferentNativePreviewsDoNotCreateUnreadWithSameCount() {
        var state = ConversationActivity()
        state.observe([row(preview: "Premier message")])
        state.observe([row(preview: "Dernière réponse")], establishesBaseline: false)
        XCTAssertFalse(state.hasUnread(profile: "default"))
        state.observe([row(count: 3, preview: "Nouvelle réponse")], establishesBaseline: false)
        XCTAssertTrue(state.hasUnread(profile: "default"))
    }

    func testLateHistoryCannotUndoReadPositionAndProfilesAreIsolated() throws {
        var state = ConversationActivity()
        state.observe([row(), row(profile: "work")])
        state.observe([row(count: 4, preview: "Réponse")])
        XCTAssertTrue(state.hasUnread(profile: "default"))
        XCTAssertFalse(state.hasUnread(profile: "work"))
        state.markRead(profile: "default", id: "chat")
        state.observe([row(count: 2, preview: "Ancien")])
        state.observe([row(count: 4, preview: "Réponse")])
        XCTAssertFalse(state.hasUnread(profile: "default"))
        state.visit(profile: "work", at: Date(timeIntervalSince1970: 100))
        let restored = try JSONDecoder().decode(ConversationActivity.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.lastVisited(profile: "work"), Date(timeIntervalSince1970: 100))
        XCTAssertFalse(restored.hasUnread(profile: "default"))
    }

    func testNewConversationAndOlderPages() {
        var state = ConversationActivity()
        state.observe([row()], at: Date(timeIntervalSince1970: 100))
        state.observe([row("older", at: 50), row("new", at: 110)])
        XCTAssertFalse(state.isUnread(profile: "default", id: "older"))
        XCTAssertTrue(state.isUnread(profile: "default", id: "new"))
        state.remove(profile: "default")
        XCTAssertFalse(state.hasUnread(profile: "default"))
    }

    func testPreviewChangesWithoutCountAndLegacyCacheDecode() throws {
        var state = ConversationActivity()
        state.observe([Conversation(["id": "legacy", "preview": "Avant"], profile: "default")])
        state.observe([Conversation(["id": "legacy", "preview": "Après"], profile: "default")])
        XCTAssertTrue(state.isUnread(profile: "default", id: "legacy"))
        let old = #"{"id":"old","profile":"default","title":"Ancien","preview":"","updated":0}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(Conversation.self, from: old).messageCount)
    }

    func testOldActiveHTTPPageIsNotANewConversation() {
        var state = ConversationActivity()
        state.observe([row()], at: Date(timeIntervalSince1970: 300))
        state.observe([Conversation(["id": "old", "started_at": 50, "last_active": 400, "message_count": 8], profile: "default")])
        XCTAssertFalse(state.isUnread(profile: "default", id: "old"))
        state.observe([Conversation(["id": "new", "started_at": 310, "last_active": 400, "message_count": 2], profile: "default")])
        XCTAssertTrue(state.isUnread(profile: "default", id: "new"))
    }

    func testFirstIncomingConversationAfterEmptyHistoryIsUnread() {
        var state = ConversationActivity()
        state.observe([], emptyProfile: "default", at: Date(timeIntervalSince1970: 100))
        state.observe([row(at: 110)])
        XCTAssertTrue(state.isUnread(profile: "default", id: "chat"))
    }
}
