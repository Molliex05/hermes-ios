import XCTest
@testable import HermesIOSCore

final class QueuedMessageTests: XCTestCase {
    func testAWaitingMessageFollowsTheReplyItWaitedFor() {
        var transcript = Transcript()
        transcript.queued = [ChatMessage(role: "user", text: "Et demain ?"), ChatMessage(role: "user", text: "Merci")]
        transcript.drainQueued()
        XCTAssertEqual(transcript.messages.map(\.text), ["Et demain ?"]); XCTAssertEqual(transcript.queued.map(\.text), ["Merci"])
    }

    func testAHistoryRefreshThatBroughtItDoesNotDoubleIt() {
        var transcript = Transcript()
        transcript.messages = [ChatMessage(role: "user", text: "Et demain ?")]
        transcript.queued = [ChatMessage(role: "user", text: "Et demain ?")]
        transcript.drainQueued()
        XCTAssertEqual(transcript.messages.count, 1); XCTAssertTrue(transcript.queued.isEmpty)
    }

    func testTheServerIsAskedToHoldItNeverToInterrupt() {
        XCTAssertEqual(VoiceLiveProtocol.prompt(runtime: "r", text: "t", context: nil, queued: true)["queued"].bool, true)
        XCTAssertTrue(VoiceLiveProtocol.prompt(runtime: "r", text: "t", context: nil)["queued"].isNull)
    }
}
