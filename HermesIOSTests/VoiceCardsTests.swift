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

    func testTheCallActivityGetsASmallVersionOfTheNewestCard() {
        let reply = ChatMessage(id: "w", role: "assistant", text: weather)
        let glance = VoiceCards.glance(in: [reply], before: [])
        XCTAssertEqual(glance?.title, "Saint-Constant"); XCTAssertEqual(glance?.value, "7°"); XCTAssertEqual(glance?.symbol, "cloud.sun.fill")
        let dentist = VoiceCards.glance(in: [ChatMessage(id: "e", role: "assistant", text: event)], before: [])
        XCTAssertEqual(dentist?.title, "Dentiste"); XCTAssertEqual(dentist?.symbol, "calendar")
        XCTAssertNil(VoiceCards.glance(in: [reply], before: VoiceCards.snapshot([reply])), "nothing from before the call")
        let streaming = ChatMessage(id: "s", role: "assistant", text: "Voici.\n\n```ui\n{\"type\":\"weather\"", streaming: true)
        XCTAssertNil(VoiceCards.glance(in: [streaming], before: []), "a card still being written is not shown")
    }

    func testAGlanceStaysSmall() {
        let glance = CardGlance(symbol: "list.bullet", title: String(repeating: "a", count: 200), value: "1234567890123456789",
                                lines: ["un\ndeux", "", "trois", "quatre"])
        XCTAssertEqual(glance.title.count, 70); XCTAssertEqual(glance.value.count, 14)
        XCTAssertEqual(glance.lines, ["un deux", "trois"])
    }
}
