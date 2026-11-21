import XCTest
@testable import HermesIOSCore

final class BoardDeskTests: XCTestCase {
    func testEachAgentHasItsRole() {
        XCTAssertEqual(BoardRole(profile: "noriven"), .desk)
        XCTAssertEqual(BoardRole(profile: "Hermès"), .desk)
        XCTAssertEqual(BoardRole(profile: "personnel"), .day)
        XCTAssertFalse(BoardRole.desk.showsWeather, "Hermès never shows the weather")
        XCTAssertTrue(BoardRole.day.showsWeather)
    }

    func testTheWorstLinesComeFirstInTheAgentsOrder() {
        let desk = BoardDesk([
            .init(text: "Umami", tone: "warning"), .init(text: "Float", tone: "negative"),
            .init(text: "Note", tone: "neutral"), .init(text: "Sauvegardes", tone: "negative"), .init(text: "VPS", tone: "warning")])
        XCTAssertEqual(desk.items.map(\.text), ["Float", "Sauvegardes", "Umami", "VPS", "Note"])
        XCTAssertEqual(desk.level, .fix)
        XCTAssertEqual(desk.headline.figure, "2"); XCTAssertEqual(desk.headline.label, "à régler")
        XCTAssertEqual(desk.subline, "+ 2 à surveiller")
    }

    func testACalmDeskSaysSo() {
        let watched = BoardDesk([.init(text: "VPS", tone: "warning")])
        XCTAssertEqual(watched.level, .watch); XCTAssertEqual(watched.headline.label, "à surveiller"); XCTAssertEqual(watched.subline, "")
        let fine = BoardDesk([.init(text: "Déploiement", tone: "positive"), .init(text: "Ventes")])
        XCTAssertEqual(fine.level, .fine); XCTAssertEqual(fine.headline.figure, "✓"); XCTAssertEqual(fine.subline, "2 points suivis")
        XCTAssertEqual(BoardDesk([]).headline.label, "Rien à signaler")
    }
}
