import XCTest
@testable import HermesIOSCore

final class WidgetBlockTests: XCTestCase {
    private let json = """
    {"version":1,"boards":{},"blocks":{
      "noriven":[
        {"slot":"finances","order":2,"expires_at":"2026-11-02T20:00:00Z","card":{"type":"metrics","title":"Trésorerie","ask":"Détaille",
          "items":[{"label":"Solde","value":"8 420 $","delta":"+3 %","tone":"POSITIVE"},{"label":"","value":"x"}]}},
        {"slot":"journee","order":1,"expires_at":"2026-11-02T20:00:00Z","card":{"type":"meteo"}},
        {"slot":"courbe","order":3,"expires_at":"2026-11-02T20:00:00Z","card":{"type":"chart","style":"bar","value":"3 900 $",
          "points":[{"label":"sept","value":3200},{"label":"oct","value":"pas un nombre"},{"label":"nov","value":3900}]}},
        {"slot":"vide","order":4,"expires_at":"2026-11-02T20:00:00Z","card":{"type":"list","items":[{"title":""}]}},
        {"slot":"inconnu","order":4,"expires_at":"2026-11-02T20:00:00Z","card":{"type":"brief"}},
        {"slot":"finances","order":0,"expires_at":"2026-11-02T20:00:00Z","card":{"type":"note","text":"doublon"}}],
      "personnel":"pas une liste"}}
    """

    func testBlocksAreDecodedInOrderAndBadOnesDropped() throws {
        let boards = try AgentBoards.decode(Data(json.utf8))
        XCTAssertEqual(Array(boards.blocks.keys), ["noriven"], "a profile with nothing valid is left out")
        let blocks = try XCTUnwrap(boards.blocks["noriven"])
        XCTAssertEqual(blocks.map(\.slot), ["journee", "finances", "courbe"], "by order; empty, unknown and repeated slots dropped")
        XCTAssertEqual(blocks[1].metrics.map(\.label), ["Solde"]); XCTAssertEqual(blocks[1].metrics[0].tone, "positive")
        XCTAssertEqual(blocks[1].ask, "Détaille")
        XCTAssertEqual(blocks[2].points.map(\.value), [3200, 3900]); XCTAssertTrue(blocks[2].bars)
        XCTAssertTrue(blocks[0].isPlacement)
    }

    func testABlockEndsAtItsExpiryAndOneWithoutIsNeverShown() throws {
        let block = try XCTUnwrap(AgentBoards.decode(Data(json.utf8)).blocks["noriven"]?.first)
        let expiry = try XCTUnwrap(block.expiresAt)
        XCTAssertFalse(block.isExpired(at: expiry.addingTimeInterval(-1))); XCTAssertTrue(block.isExpired(at: expiry))
        XCTAssertTrue(WidgetBlock(slot: "x", kind: .note).isExpired())
    }

    func testRingsNeedAPositiveGoalAndStayInRange() {
        let value: JSONValue = .object(["slot": .string("anneaux"), "order": .number(1), "expires_at": .string("2026-11-02T20:00:00Z"),
                                        "card": .object(["type": .string("progress"), "items": .array([
                                            .object(["label": .string("Calories"), "value": .number(2600), "goal": .number(2400)]),
                                            .object(["label": .string("Zéro"), "value": .number(1), "goal": .number(0)])])])])
        let block = WidgetBlock(value)
        XCTAssertEqual(block?.rings.map(\.label), ["Calories"]); XCTAssertEqual(block?.rings.first?.fraction, 1)
    }

    func testAServerWithoutBlocksStillDecodes() throws {
        XCTAssertTrue(try AgentBoards.decode(Data(#"{"boards":{}}"#.utf8)).blocks.isEmpty)
    }
}
