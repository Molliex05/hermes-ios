import XCTest
@testable import HermesIOSCore

final class VoiceCardsTests: XCTestCase {
    private let weather = "Il fait doux.\n\n```ui\n{\"type\":\"weather\",\"place\":\"Saint-Constant\",\"now\":{\"temp\":7}}\n```"
    private let event = "C'est noté.\n\n```ui\n{\"type\":\"event\",\"title\":\"Dentiste\",\"start\":\"2026-11-03T14:00\"}\n```"

    func testShowsTheNewestReplyWithCardsGivenDuringTheCall() {
        let old = ChatMessage(id: "a", role: "assistant", text: weather)
        let before = VoiceCards.snapshot([old])
        XCTAssertNil(VoiceCards.latest(in: [old], before: before), "a card from before the call is not shown")
        let asked = ChatMessage(id: "u", role: "user", text: "🎙️ Ajoute le dentiste demain")
        let reply = ChatMessage(id: "b", role: "assistant", text: event)
        let shown = VoiceCards.latest(in: [old, asked, reply], before: before)
        XCTAssertEqual(shown?.messageID, "b"); XCTAssertEqual(shown?.cards.count, 1); XCTAssertTrue(shown?.cards.first?.complete ?? false)
        let plain = ChatMessage(id: "c", role: "assistant", text: "Autre chose ?")
        XCTAssertEqual(VoiceCards.latest(in: [old, asked, reply, plain], before: before)?.messageID, "b", "the card stays until a newer one")
        let reloaded = ChatMessage(id: "a-hydrated", role: "assistant", text: weather)
        XCTAssertEqual(VoiceCards.latest(in: [reloaded, asked, reply], before: before)?.messageID, "b", "a reloaded old reply is still old")
    }

    func testAStreamingCardIsShownAsPreparing() {
        let streaming = ChatMessage(id: "s", role: "assistant", text: "Voici.\n\n```ui\n{\"type\":\"weather\"", streaming: true)
        XCTAssertEqual(VoiceCards.latest(in: [streaming], before: [])?.cards.first?.complete, false)
    }
}
