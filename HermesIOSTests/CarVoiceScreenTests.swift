import XCTest
@testable import HermesIOSCore

final class CarVoiceScreenTests: XCTestCase {
    func testTheCallPhaseMapsToFiveCarStates() {
        XCTAssertEqual(CarVoiceScreen.state(phase: nil, muted: false), .idle, "no call")
        XCTAssertEqual(CarVoiceScreen.state(phase: "paused", muted: false), .idle)
        XCTAssertEqual(CarVoiceScreen.state(phase: "listening", muted: false), .listening)
        XCTAssertEqual(CarVoiceScreen.state(phase: "thinking", muted: false), .thinking)
        XCTAssertEqual(CarVoiceScreen.state(phase: "waiting", muted: false), .thinking)
        XCTAssertEqual(CarVoiceScreen.state(phase: "speaking", muted: false), .speaking)
        XCTAssertEqual(CarVoiceScreen.state(phase: "listening", muted: true), .muted)
        XCTAssertEqual(CarVoiceScreen.state(phase: "speaking", muted: true), .muted, "the button must offer to turn the microphone back on")
        XCTAssertLessThanOrEqual(CarVoiceScreen.State.allCases.count, 5, "CarPlay keeps five states at most")
    }

    func testTitlesNameTheAgentAndHaveAShortVariant() {
        XCTAssertEqual(CarVoiceScreen.titles(.listening, agent: "Jarvis").first, "Jarvis vous écoute")
        XCTAssertEqual(CarVoiceScreen.titles(.idle, agent: " ").first, "Appeler Hermès")
        for state in CarVoiceScreen.State.allCases {
            XCTAssertTrue(CarVoiceScreen.titles(state, agent: "Jarvis").contains { $0.count <= 14 }, "\(state) fits a narrow screen")
        }
    }

    private func reply(_ id: String, _ json: String) -> ChatMessage {
        ChatMessage(id: id, role: "assistant", text: "Voici.\n\n```ui\n\(json)\n```")
    }

    func testOnePlaceGivenDuringTheCallIsADestination() throws {
        let one = reply("p", #"{"type":"places","items":[{"name":"Costco Candiac","address":"100 boul. Montcalm, Candiac","lat":45.39,"lon":-73.5}]}"#)
        let found = try XCTUnwrap(VoiceCards.destination(in: [one], before: []))
        XCTAssertEqual(found.messageID, "p")
        let query = URLComponents(url: found.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(found.url.host, "maps.apple.com")
        XCTAssertEqual(query.first { $0.name == "daddr" }?.value, "45.39,-73.5")
        XCTAssertEqual(query.first { $0.name == "dirflg" }?.value, "d", "a driving route")
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "Costco Candiac")
    }

    func testAnAddressWithoutCoordinatesIsLookedUpByName() throws {
        let one = reply("p", #"{"type":"places","items":[{"name":"Barbier","address":"12 rue Principale, Saint-Constant"}]}"#)
        let url = try XCTUnwrap(VoiceCards.destination(in: [one], before: [])?.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "daddr" }?.value,
                       "Barbier, 12 rue Principale, Saint-Constant")
    }

    func testSeveralPlacesOrAnOldReplyAreNotADestination() {
        let two = reply("t", #"{"type":"places","items":[{"name":"A","address":"1 rue A"},{"name":"B","address":"2 rue B"}]}"#)
        XCTAssertNil(VoiceCards.destination(in: [two], before: []), "the driver picks one by voice")
        let one = reply("p", #"{"type":"places","items":[{"name":"Costco","address":"Candiac"}]}"#)
        XCTAssertNil(VoiceCards.destination(in: [one], before: VoiceCards.snapshot([one])), "given before the call")
        let weather = reply("w", #"{"type":"weather","place":"Delson","now":{"temp":3}}"#)
        XCTAssertNil(VoiceCards.destination(in: [weather], before: []))
        let streaming = ChatMessage(id: "s", role: "assistant", text: "Voici.\n\n```ui\n{\"type\":\"places\",\"items\":[{\"name\":\"Cos", streaming: true)
        XCTAssertNil(VoiceCards.destination(in: [streaming], before: []), "not before the card is whole")
    }
}
