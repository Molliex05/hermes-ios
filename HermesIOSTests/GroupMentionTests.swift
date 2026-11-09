import XCTest
@testable import HermesIOSCore

final class GroupMentionTests: XCTestCase {
    func testAMentionIsOnlyTheLastWordAfterASpace() {
        XCTAssertEqual(GroupMention.query(in: "@"), "")
        XCTAssertEqual(GroupMention.query(in: "Salut @he"), "he")
        XCTAssertNil(GroupMention.query(in: "maxime@noriven"), "an address is no mention")
        XCTAssertNil(GroupMention.query(in: "@hermes tu vois"))
    }

    func testChoosingAnAgentFinishesTheMention() {
        XCTAssertEqual(GroupMention.completed("Salut @he", handle: "hermes"), "Salut @hermes ")
        XCTAssertEqual(GroupMention.completed("rien", handle: "hermes"), "rien")
        XCTAssertEqual(GroupMention.handle(title: "Hermès", fallback: "noriven"), "hermes")
        XCTAssertEqual(GroupMention.handle(title: "🤖", fallback: "noriven"), "noriven")
    }

    func testAnAgentsMessageIsToldFromThePersons() {
        XCTAssertEqual(AgentNote("Message from 🤖 Jarvis (@personnel): Alerte AWS reçue"), AgentNote("Message from Jarvis (@personnel): Alerte AWS reçue"))
        let note = AgentNote("Message from 🤖 Hermès (@noriven): Oui.\n\nC'est réglé.")
        XCTAssertEqual(note?.name, "Hermès"); XCTAssertEqual(note?.handle, "noriven"); XCTAssertEqual(note?.body, "Oui.\n\nC'est réglé.")
        XCTAssertNil(AgentNote("Dis à Message from Jarvis (@personnel): non"), "only at the very start")
    }
}
