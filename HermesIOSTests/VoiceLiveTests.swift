import XCTest
@testable import HermesIOSCore

final class VoiceLiveTests: XCTestCase {
    func testOverlappingSpeechAndDelayedTranscriptProduceOneCompleteRequest() throws {
        var transcript = VoiceLiveTranscript()
        _ = transcript.receive(["type": "session.input_transcript.delta", "delta": "Cherche ", "start_ms": 0, "end_ms": 400], now: 1)
        _ = transcript.receive(["type": "session.output_transcript.delta", "delta": "D’accord.", "start_ms": 200, "end_ms": 800], now: 1)
        let delegation: JSONValue = ["type": "session.delegation.created", "offset_ms": 1000, "delegation": ["id": "first"]]
        XCTAssertEqual(transcript.receive(delegation, now: 2), "first")
        XCTAssertNil(try transcript.nextRequest(now: 2.1))
        _ = transcript.receive(["type": "session.input_transcript.delta", "delta": "mes rendez-vous.", "start_ms": 400, "end_ms": 1000], now: 2.2)
        let request = try XCTUnwrap(transcript.nextRequest(now: 2.5))
        XCTAssertEqual(request.prompt, "Cherche mes rendez-vous.")
        XCTAssertNil(transcript.receive(delegation, now: 3))
        _ = transcript.receive(["type": "session.delegation.created", "offset_ms": 1000, "delegation": ["id": "same-utterance"]], now: 3)
        XCTAssertNil(try transcript.nextRequest(now: 4))
    }

    func testQueuedDelegationsDoNotOverwriteOrIncludeFutureSpeech() throws {
        var transcript = VoiceLiveTranscript()
        for n in 1...2 {
            _ = transcript.receive(["type": "session.input_transcript.delta", "delta": .string("Question \(n)."), "start_ms": .number(Double(n * 1000)), "end_ms": .number(Double(n * 1000 + 500))], now: Double(n))
            _ = transcript.receive(["type": "session.delegation.created", "offset_ms": .number(Double(n * 1000 + 500)), "delegation": ["id": .string("request-\(n)")]], now: Double(n))
        }
        let first = try XCTUnwrap(transcript.nextRequest(now: 5))
        XCTAssertEqual(first.id, "request-1")
        XCTAssertEqual(first.prompt, "Question 1.")
        XCTAssertFalse(first.context.contains("Question 2"))
        XCTAssertEqual(try transcript.nextRequest(now: 5)?.prompt, "Question 2.")
        XCTAssertNil(try transcript.nextRequest(now: 5))
    }

    func testDelegationBeforeAnyTranscriptWaitsRatherThanDroppingRequest() throws {
        var transcript = VoiceLiveTranscript()
        _ = transcript.receive(["type": "session.delegation.created", "offset_ms": 2000, "delegation": ["id": "early"]], now: 1)
        XCTAssertNil(try transcript.nextRequest(now: 1.5))
        _ = transcript.receive(["type": "session.input_transcript.delta", "delta": "Bonjour", "start_ms": 1000, "end_ms": 2000], now: 2)
        XCTAssertEqual(try transcript.nextRequest(now: 2)?.prompt, "Bonjour")
    }

    func testReceiptsRequireMatchingAcknowledgementAndSurfaceIncompleteInjection() throws {
        var receipts = VoiceLiveReceipts()
        let event = VoiceLiveProtocol.append("commentary", delegation: "first", content: "Résultat confirmé.")
        receipts.sent(event, now: 1)
        let id = event["event_id"].string
        receipts.receive(["type": "session.commentary.appended", "client_event_id": "unrelated"])
        receipts.receive(["type": "session.thinking.appended", "client_event_id": .string(id)])
        XCTAssertTrue(receipts.contains(id))
        XCTAssertThrowsError(try receipts.check(now: 31))
        receipts.receive(["type": "session.commentary.appended", "client_event_id": .string(id)])
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertNoThrow(try receipts.check(now: 32))
        receipts.sent(event, now: 33)
        receipts.receive(["type": "error", "error": ["code": "context_injection_incomplete", "message": "fixture"]])
        XCTAssertThrowsError(try receipts.check(now: 34))
    }

    func testSlowTurnAcknowledgesOnceAndDoesNotFillSilenceForever() {
        var progress = VoiceLiveProgress(startedAt: 100)
        func next(_ time: Double) -> String? {
            progress.next(now: time, lastSpeechAt: 100, lastOutputAt: 0,
                          running: true, receivedReply: false, tools: [])
        }
        XCTAssertNil(next(101))
        XCTAssertEqual(next(102), "Je m’en occupe.")
        XCTAssertNil(next(109))
        XCTAssertEqual(next(110), "Je travaille encore sur votre demande.")
        XCTAssertNil(next(120))
        XCTAssertNil(next(200))
    }

    func testLiveAcknowledgementAndUserSpeechDeferProgress() {
        var progress = VoiceLiveProgress(startedAt: 100)
        // GPT-Live may acknowledge just before or after emitting the delegation.
        XCTAssertNil(progress.next(now: 102, lastSpeechAt: 99, lastOutputAt: 99,
                                   running: true, receivedReply: false, tools: []))
        XCTAssertNil(progress.next(now: 110, lastSpeechAt: 109, lastOutputAt: 101,
                                   running: true, receivedReply: false, tools: []))
        XCTAssertNotNil(progress.next(now: 117, lastSpeechAt: 109, lastOutputAt: 101,
                                      running: true, receivedReply: false, tools: []))
    }

    func testProgressUsesOnlyActiveKnownToolsAndLimitsAnnouncements() {
        var progress = VoiceLiveProgress(startedAt: 100)
        let search = Transcript.ToolStep(id: "search", name: "web_search", state: .running)
        let read = Transcript.ToolStep(id: "read", name: "read_file", state: .running)
        let privateTool = Transcript.ToolStep(id: "private", name: "secret_value", state: .running)
        let completed = Transcript.ToolStep(id: "done", name: "terminal", state: .completed)
        func next(_ time: Double, _ tools: [Transcript.ToolStep]) -> String? {
            progress.next(now: time, lastSpeechAt: 100, lastOutputAt: 0,
                          running: true, receivedReply: false, tools: tools)
        }
        XCTAssertEqual(next(102, []), "Je m’en occupe.")
        XCTAssertEqual(next(110, [search, privateTool, completed]), "Je recherche les informations sur le web.")
        XCTAssertNil(next(111, [read]))
        XCTAssertEqual(next(118, [search, read]), "Je consulte les fichiers nécessaires.")
        XCTAssertNil(next(130, [privateTool, completed]))
        // Unknown tool names never become spoken content; a fresh delegation resets the cap.
        var fresh = VoiceLiveProgress(startedAt: 200)
        XCTAssertEqual(fresh.next(now: 210, lastSpeechAt: 201, lastOutputAt: 201,
                                 running: true, receivedReply: false, tools: [privateTool, completed]),
                       "Je travaille encore sur votre demande.")
    }

    func testReplyOrCompletionSuppressesLateProgress() {
        var progress = VoiceLiveProgress(startedAt: 100)
        XCTAssertNil(progress.next(now: 110, lastSpeechAt: 100, lastOutputAt: 0,
                                   running: false, receivedReply: false, tools: []))
        XCTAssertNil(progress.next(now: 110, lastSpeechAt: 100, lastOutputAt: 0,
                                   running: true, receivedReply: true, tools: []))
        XCTAssertNil(progress.next(now: 120, lastSpeechAt: 100, lastOutputAt: 0,
                                   running: true, receivedReply: false, tools: []))
    }

    func testDelegationUsesLastUserTurnAndDeduplicatesIDs() {
        var transcript = VoiceLiveTranscript()
        for (type, delta) in [("input", "Résume "), ("input", "mon projet."), ("output", "Je vérifie.")] {
            XCTAssertNil(transcript.receive(["type": .string("session.\(type)_transcript.delta"), "delta": .string(delta), "end_ms": 100]))
        }
        let event: JSONValue = ["type": "session.delegation.created", "delegation": ["id": "first"]]
        XCTAssertEqual(transcript.receive(event), "first")
        XCTAssertNil(transcript.receive(event))
        XCTAssertEqual(transcript.prompt, "Résume mon projet.")
        XCTAssertEqual(transcript.context, "User: Résume mon projet.\nVoice assistant: Je vérifie.")
        let payload = VoiceLiveProtocol.prompt(runtime: "runtime-profile-research", text: transcript.prompt, context: transcript.context)
        XCTAssertEqual(payload["surface"], "voice-live")
        XCTAssertEqual(payload["session_id"], "runtime-profile-research")
        XCTAssertEqual(payload["text"], "Résume mon projet.")
        XCTAssertEqual(payload["voice_context"].string, transcript.context)
        XCTAssertTrue(VoiceLiveProtocol.prompt(runtime: "runtime", text: "hello", context: nil)["surface"].isNull)
    }

    func testContextExpiresAndHistoryIsBoundedWithoutSystemOrToolMessages() {
        var transcript = VoiceLiveTranscript()
        _ = transcript.receive(["type": "session.input_transcript.delta", "delta": "Old private detail", "end_ms": 1])
        _ = transcript.receive(["type": "session.input_transcript.delta", "delta": "New request", "end_ms": 300_002])
        XCTAssertEqual(transcript.prompt, "New request")
        let turns = [(role: "system", text: "secret"), (role: "tool", text: "tool secret")] + (0..<50).map { (role: "user", text: "message \($0)") }
        let history = VoiceLiveProtocol.history(turns).array
        XCTAssertEqual(history.count, 24)
        XCTAssertEqual(history.first?["content"].array.first?["text"].string, "message 26")
        XCTAssertEqual(history.last?["content"].array.first?["text"].string, "message 49")
        let long = VoiceLiveProtocol.history((0..<20).map { _ in (role: "assistant", text: String(repeating: "a", count: 2_000)) }).array
        XCTAssertEqual(long.count, 5)
        XCTAssertEqual(long.first?["content"].array.first?["type"], "output_text")
    }

    func testStreamingDoesNotRepeatClausesAndSurvivesFinalRewrites() {
        var cursor = VoiceLiveReplyCursor()
        XCTAssertEqual(cursor.delta("Bonjour", done: false), "")
        XCTAssertEqual(cursor.delta("Bonjour. Je vérifie", done: false), "Bonjour.")
        XCTAssertEqual(cursor.delta("Bonjour. Je vérifie encore", done: false), "")
        XCTAssertEqual(cursor.delta("Bonjour. Je vérifie encore; puis", done: false), " Je vérifie encore;")
        XCTAssertEqual(cursor.delta("Bonjour. Je vérifie encore; puis je reviens.", done: true), " puis je reviens.")
        XCTAssertEqual(cursor.delta("Bonjour. Je vérifie encore; puis je reviens.", done: true), "")
        XCTAssertEqual(cursor.delta("Une réponse normalisée différente.", done: true), "", "A rewritten final never ends the session")
        var long = VoiceLiveReplyCursor()
        let run = String(repeating: "mot, ", count: 40)
        XCTAssertEqual(long.delta(run + "suite", done: false), run, "Unpunctuated runs are cut at the last comma or space")
    }

    func testDelegationWithCompleteTranscriptIsReadyWithoutWaiting() throws {
        var transcript = VoiceLiveTranscript()
        _ = transcript.receive(["type": "session.input_transcript.delta", "delta": "Quelle heure est-il ?", "start_ms": 0, "end_ms": 900], now: 1)
        _ = transcript.receive(["type": "session.delegation.created", "offset_ms": 900, "delegation": ["id": "now"]], now: 1)
        XCTAssertEqual(try transcript.nextRequest(now: 1.01)?.prompt, "Quelle heure est-il ?")
    }

    func testUntranscribedDelegationIsDroppedNotFatal() throws {
        var transcript = VoiceLiveTranscript()
        _ = transcript.receive(["type": "session.delegation.created", "offset_ms": 500, "delegation": ["id": "silent"]], now: 1)
        XCTAssertNil(try transcript.nextRequest(now: 2))
        XCTAssertNil(try transcript.nextRequest(now: 4.1))
        XCTAssertEqual(transcript.takeDropped(), ["silent"])
        XCTAssertEqual(transcript.takeDropped(), [])
        _ = transcript.receive(["type": "session.input_transcript.delta", "delta": "Encore", "start_ms": 600, "end_ms": 900], now: 5)
        _ = transcript.receive(["type": "session.delegation.created", "offset_ms": 900, "delegation": ["id": "next"]], now: 5)
        XCTAssertEqual(try transcript.nextRequest(now: 5)?.id, "next")
    }

    func testUnicodeCommentaryChunksPreserveContentAndBoundEachAppend() {
        let text = String(repeating: "Bonjour 👨‍👩‍👧‍👦 中文 éà! ", count: 150)
        let chunks = VoiceLiveProtocol.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 480 })
        XCTAssertTrue(VoiceLiveProtocol.chunks("").isEmpty)
        for chunk in chunks {
            let event = VoiceLiveProtocol.append("commentary", delegation: "second", content: chunk)
            XCTAssertEqual(event["type"], "session.commentary.append")
            XCTAssertEqual(event["delegation_id"], "second")
        }
    }
}
