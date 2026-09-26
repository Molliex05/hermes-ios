import XCTest
@testable import HermesIOSCore

final class ToolActivityTests: XCTestCase {
    private func event(_ sequence: Int, _ type: String, id: String = "", name: String = "terminal", payload: JSONValue? = nil) -> JSONValue {
        ["seq": .number(Double(sequence)), "type": .string(type),
         "payload": payload ?? ["tool_id": .string(id), "name": .string(name)]]
    }

    private var runningSnapshot: JSONValue {
        ["running": true, "messages": [["role": "user", "text": "Fais le point"]],
         "inflight": ["user": "Fais le point", "assistant": "Je regarde."]]
    }

    func testTruncatedReplayReconcilesKnownAndNewToolsWithoutTurnStart() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        transcript.apply(event(2, "tool.start", id: "first"))
        let replay = [event(6, "tool.complete", id: "first"), event(7, "tool.start", id: "second", name: "web_search")]

        transcript.recover(runningSnapshot, events: replay, latestSequence: 7)

        XCTAssertEqual(transcript.toolSteps.map(\.id), ["first", "second"])
        XCTAssertEqual(transcript.toolSteps.map(\.state), [.completed, .running])
        XCTAssertTrue(transcript.running)
        XCTAssertEqual(transcript.activity, "web_search")
        XCTAssertEqual(transcript.lastSequence, 7)
        transcript.apply(event(7, "tool.start", id: "second", name: "web_search"))
        XCTAssertEqual(transcript.toolSteps.count, 2)
    }

    func testTruncatedReplayCanRecoverCompletionWithoutKnownToolStart() {
        var transcript = Transcript()
        transcript.recover(runningSnapshot, events: [event(8, "tool.complete", id: "finished")], latestSequence: 8)

        XCTAssertEqual(transcript.toolSteps.map(\.id), ["finished"])
        XCTAssertEqual(transcript.toolSteps.map(\.state), [.completed])
        XCTAssertTrue(transcript.running)
        XCTAssertEqual(transcript.activity, "Réfléchit…")
    }

    func testToolCompletionKeepsWaitingVisibleUntilTheModelAnswers() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        transcript.apply(event(2, "tool.start", id: "first"))
        transcript.apply(event(3, "tool.start", id: "second", name: "web_search"))
        transcript.apply(event(4, "tool.complete", id: "second", name: "web_search"))
        XCTAssertEqual(transcript.activity, "terminal")

        transcript.apply(event(5, "tool.complete", id: "first"))
        XCTAssertEqual(transcript.activity, "Réfléchit…")
        XCTAssertTrue(transcript.isWaitingForResponse(at: transcript.lastActivityAt.addingTimeInterval(16)))
    }

    func testDuplicateLifecycleEventsDoNotCreateRowsOrReopenCompletedTools() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        transcript.apply(event(2, "tool.start", id: "first"))
        transcript.apply(event(3, "tool.complete", id: "first"))
        transcript.apply(event(2, "tool.start", id: "first"))
        transcript.apply(event(3, "tool.complete", id: "first"))
        // A repeated lifecycle id with a new transport sequence still denotes one call.
        transcript.apply(event(4, "tool.start", id: "first"))
        transcript.apply(event(5, "tool.complete", id: "first"))

        XCTAssertEqual(transcript.toolSteps.count, 1)
        XCTAssertEqual(transcript.toolSteps.first?.state, .completed)
    }

    func testLongTurnKeepsOnlyFortyRecentTools() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        for index in 0..<45 {
            transcript.apply(event(index * 2 + 2, "tool.start", id: "tool-\(index)"))
            transcript.apply(event(index * 2 + 3, "tool.complete", id: "tool-\(index)"))
        }
        XCTAssertEqual(transcript.toolSteps.map(\.id), (5..<45).map { "tool-\($0)" })
        XCTAssertTrue(transcript.toolSteps.allSatisfy { $0.state == .completed })
    }

    func testInterruptedTurnStopsOpenToolsWithoutUndoingCompletions() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        transcript.apply(event(2, "tool.start", id: "finished"))
        transcript.apply(event(3, "tool.complete", id: "finished"))
        transcript.apply(event(4, "tool.start", id: "interrupted"))
        transcript.apply(event(5, "message.complete", payload: ["status": "interrupted", "text": ""]))

        XCTAssertEqual(transcript.toolSteps.map(\.state), [.completed, .stopped])
        XCTAssertFalse(transcript.running)
        XCTAssertNil(transcript.activity)
        transcript.apply(event(6, "tool.complete", id: "interrupted"))
        XCTAssertFalse(transcript.running)
        XCTAssertNil(transcript.activity)
    }

    func testIdleSnapshotDoesNotReviveOldRunningToolsFromReplay() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        transcript.apply(event(2, "tool.start", id: "old"))
        transcript.recover(["running": false, "messages": [["role": "assistant", "text": "Terminé"]]], events: [
            event(1, "message.start"), event(2, "tool.start", id: "old"), event(3, "tool.start", id: "older")
        ], latestSequence: 3)

        XCTAssertEqual(transcript.toolSteps.map(\.id), ["old"])
        XCTAssertEqual(transcript.toolSteps.first?.state, .stopped)
        XCTAssertFalse(transcript.running)
        XCTAssertNil(transcript.activity)
        XCTAssertEqual(transcript.messages.map(\.text), ["Terminé"])
    }

    func testRecoverUsesOnlyLatestProvenTurnEvenWithoutUserMessage() {
        var transcript = Transcript()
        transcript.apply(event(1, "tool.start", id: "cached-old"))
        transcript.recover(["running": true, "messages": []], events: [
            event(2, "tool.start", id: "old"),
            event(3, "message.complete", payload: ["text": "Ancienne réponse"]),
            event(4, "message.start"),
            event(5, "tool.start", id: "current")
        ], latestSequence: 5)

        XCTAssertEqual(transcript.toolSteps.map(\.id), ["current"])
        XCTAssertEqual(transcript.toolSteps.first?.state, .running)
        XCTAssertTrue(transcript.running)
        XCTAssertTrue(transcript.messages.isEmpty)
    }
}
