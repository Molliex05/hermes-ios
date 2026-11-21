import XCTest
@testable import HermesIOSCore

final class AgentCallPlanTests: XCTestCase {
    func testTheAgentIsReachedOnlyInTheCarOrUnlocked() {
        XCTAssertEqual(AgentCallPlan.mode(carAudio: true, unlocked: false), .conversation, "at the wheel, as the car call already trusts")
        XCTAssertEqual(AgentCallPlan.mode(carAudio: false, unlocked: true), .conversation)
        XCTAssertEqual(AgentCallPlan.mode(carAudio: false, unlocked: false), .briefing, "a locked iPhone in any hand never reaches the agent")
    }

    func testTheBriefingSaysTheDayWithoutMailOrAmounts() {
        let shift = AgentBoard.Item(text: "Quart de soir", detail: "Police", time: "14:30")
        let desk = BoardDesk([.init(text: "Float", tone: "negative"), .init(text: "Sauvegardes", tone: "negative"), .init(text: "VPS", tone: "warning")])
        let text = AgentCallPlan.briefing(agent: "Jarvis", reason: "ton quart commence dans 30 minutes", next: shift, weather: nil,
                                          desk: desk, pay: "Paie du 19 novembre : tout balance")
        XCTAssertEqual(text, "Ton quart commence dans 30 minutes. Quart de soir à 14 h 30. Noriven : 2 choses à régler. Paie du 19 novembre : tout balance.")
        XCTAssertEqual(AgentCallPlan.briefing(agent: "Jarvis", reason: "", next: nil, weather: nil, desk: BoardDesk([]), pay: nil),
                       "Rien de particulier aujourd’hui.")
    }

    func testTimesAreSpokenTheQuebecWay() {
        XCTAssertEqual(AgentCallPlan.spokenTime("14:30"), "14 h 30")
        XCTAssertEqual(AgentCallPlan.spokenTime("9:00"), "9 h")
        XCTAssertEqual(AgentCallPlan.spokenTime("6h45"), "6 h 45")
        XCTAssertEqual(AgentCallPlan.spokenTime("midi"), "midi")
    }

    func testTheAgentSpeaksFirstWithItsReason() {
        XCTAssertTrue(AgentCallPlan.opening(reason: "trajet vers le quart de 14 h 30").contains("Tu m’appelles : trajet vers le quart de 14 h 30"))
        let desk = BoardDesk([.init(text: "Float", tone: "negative"), .init(text: "Sauvegardes", tone: "negative"), .init(text: "VPS", tone: "warning")])
        XCTAssertEqual(AgentCallPlan.deskLine(desk), "2 à régler, 1 à surveiller")
        XCTAssertEqual(AgentCallPlan.deskLine(BoardDesk([.init(text: "Ventes", tone: "positive")])), "rien à signaler")
        XCTAssertNil(AgentCallPlan.deskLine(nil))
        XCTAssertTrue(AgentCallPlan.opening(reason: "trajet", noriven: "2 à régler").hasSuffix("Côté Noriven, selon le tableau d’Hermès : 2 à régler.)"))
    }
}
