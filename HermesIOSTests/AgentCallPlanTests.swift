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
        let text = AgentCallPlan.briefing(agent: "Jarvis", reason: "ton quart commence dans 30 minutes", next: shift, weather: nil,
                                          pay: "Paie du 19 novembre : tout balance")
        XCTAssertEqual(text, "Ton quart commence dans 30 minutes. Quart de soir à 14 h 30. Paie du 19 novembre : tout balance.")
        XCTAssertFalse(text.contains("Noriven"), "Jarvis keeps Maxime's life; Noriven is Hermès's")
        XCTAssertEqual(AgentCallPlan.briefing(agent: "Jarvis", reason: "", next: nil, weather: nil, pay: nil),
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
        XCTAssertFalse(AgentCallPlan.opening(reason: "trajet").contains("Noriven"))
    }
}
