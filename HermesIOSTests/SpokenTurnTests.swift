import XCTest
@testable import HermesIOSCore

final class SpokenTurnTests: XCTestCase {
    func testASpokenTurnKeepsTheVoiceMarkFirst() {
        XCTAssertEqual(SpokenTurn.text("Salut"), "🎙️ Salut")
        XCTAssertEqual(SpokenTurn.text("Salut", driving: false, near: "Delson"), "🎙️ Salut", "the place is only sent at the wheel")
    }

    func testAtTheWheelTheCarAndTheTownFollowTheVoiceMark() {
        XCTAssertEqual(SpokenTurn.text("Il fait quoi dehors ?", driving: true), "🎙️🚗 Il fait quoi dehors ?")
        XCTAssertEqual(SpokenTurn.text("Une station ?", driving: true, near: " Saint-Constant "), "🎙️🚗 (près de Saint-Constant) Une station ?")
        XCTAssertEqual(SpokenTurn.text("Ok", driving: true, near: "  "), "🎙️🚗 Ok")
        XCTAssertTrue(SpokenTurn.text("Ok", driving: true).hasPrefix(SpokenTurn.voiceMark))
    }

    func testAnOddPlaceNameIsKeptOnOneShortLine() {
        let text = SpokenTurn.text("Ok", driving: true, near: "Ville\nmonde" + String(repeating: "x", count: 100))
        XCTAssertFalse(text.contains("\n"))
        XCTAssertLessThan(text.count, 90)
    }
}
