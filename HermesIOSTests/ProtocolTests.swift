import XCTest
@testable import HermesIOSCore

final class ProtocolTests: XCTestCase {
    func testCookiePersistenceKeepsPrivateHTTPUsableAfterRelaunch() throws {
        let source = HTTPCookie(properties: [.name: "hermes_session", .value: "fixture", .domain: "100.64.1.2", .path: "/hermes"])!
        let restored = try JSONDecoder().decode(StoredCookie.self, from: JSONEncoder().encode(StoredCookie(source))).cookie!
        XCTAssertFalse(restored.isSecure)
        XCTAssertEqual(restored.domain, source.domain)
        XCTAssertEqual(restored.path, "/hermes")
        XCTAssertEqual(restored.value, "fixture")
    }

    func testCookiePersistencePreservesSecureFlagForHTTPS() throws {
        let source = HTTPCookie(properties: [.name: "hermes_session", .value: "fixture", .domain: "example.ts.net", .path: "/", .secure: "TRUE"])!
        let restored = try JSONDecoder().decode(StoredCookie.self, from: JSONEncoder().encode(StoredCookie(source))).cookie!
        XCTAssertTrue(restored.isSecure)
    }
    func testCoalescedUnicodeFrames() throws {
        let frames = try Wire.frames("{\"method\":\"event\",\"params\":{\"payload\":{\"text\":\"Salut 👋\\nété\"}}}\n{\"id\":\"2\",\"result\":true}\n")
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["params"]["payload"]["text"].string, "Salut 👋\nété")
        XCTAssertEqual(frames[1]["result"], true)
    }

    func testURLPreservesReverseProxyPrefixAndEscapesTicket() throws {
        let endpoint = try Endpoint("https://hermes.example.com/team/agent///")
        XCTAssertEqual(endpoint.url("/api/status").path, "/team/agent/api/status")
        let c = URLComponents(url: endpoint.socket(ticket: "a+b/&=?"), resolvingAgainstBaseURL: false)!
        XCTAssertEqual(c.scheme, "wss")
        XCTAssertEqual(c.path, "/team/agent/api/ws")
        XCTAssertEqual(c.queryItems?.first?.value, "a+b/&=?")
    }

    func testToolQueriesStayScopedBehindReverseProxy() throws {
        let endpoint = try Endpoint("http://hermes.tailnet.ts.net/mobile")
        let url = endpoint.url("/api/skills/content", query: [
            URLQueryItem(name: "profile", value: "research"),
            URLQueryItem(name: "name", value: "notes & plans?profile=studio")])
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(parts.path, "/mobile/api/skills/content")
        XCTAssertEqual(parts.queryItems?.count, 2)
        XCTAssertEqual(parts.queryItems?.first?.value, "research")
        XCTAssertEqual(parts.queryItems?.last?.value, "notes & plans?profile=studio")
    }

    func testPrivateHTTPAndTailscaleIPv6() throws {
        for host in ["100.64.0.1", "100.127.255.254", "192.168.1.8", "10.0.0.8", "172.16.0.3", "hermes", "mini.tailnet.ts.net", "[fd7a:115c:a1e0::1]"] {
            XCTAssertNoThrow(try Endpoint("http://\(host):9119"))
        }
    }

    func testPublicHTTPAndCredentialsInURLAreRejected() {
        for url in ["http://8.8.8.8", "http://100.63.0.1", "http://100.128.0.1", "https://user:password@example.com", "ftp://localhost", "https://example.com?token=secret", "https://example.com/#secret", "hermes:9119"] {
            XCTAssertThrowsError(try Endpoint(url), url)
        }
    }

    func testDuplicateAndOutOfOrderSequenceCannotDuplicateText() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        transcript.apply(event(2, "message.delta", text: "Bonjour "))
        transcript.apply(event(2, "message.delta", text: "Bonjour "))
        transcript.apply(event(1, "message.delta", text: "wrong"))
        transcript.apply(event(3, "message.delta", text: "Hermes"))
        XCTAssertEqual(transcript.messages.map(\.text), ["Bonjour Hermes"])
        XCTAssertEqual(transcript.lastSequence, 3)
    }

    func testLiveFramesAreHeldUntilReplayCanFillTheGap() {
        var transcript = Transcript(lastSequence: 10)
        var replay = ReplayBuffer()
        replay.held = [event(13, "message.delta", text: "C"), event(12, "message.delta", text: "B")]
        let drained = replay.drain(replayed: [event(11, "message.delta", text: "A"), event(12, "message.delta", text: "B")], after: 10, session: "runtime")
        drained.forEach { transcript.apply($0) }
        XCTAssertEqual(transcript.messages.first?.text, "ABC")
        XCTAssertTrue(replay.held.isEmpty)
    }

    func testProfilesCannotLeakEventsAcrossSessions() {
        var replay = ReplayBuffer()
        replay.held = [["session_id": "other", "seq": 99, "type": "message.delta", "payload": ["text": "private"]]]
        XCTAssertTrue(replay.drain(replayed: [], after: 0, session: "runtime").isEmpty)
    }

    func testSnapshotKeepsBubbleIdentityAndAcknowledgesLostSend() {
        let pending = ChatMessage(id: "local", role: "user", text: "Bonjour", delivery: .uncertain)
        var transcript = Transcript(messages: [pending])
        transcript.hydrate(["messages": [["role": "user", "text": "Bonjour", "row_id": 42], ["role": "assistant", "text": "Salut"]]])
        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertEqual(transcript.messages.first?.id, "local")
        XCTAssertEqual(transcript.messages.first?.delivery, .confirmed)
    }

    func testUnacknowledgedSendSurvivesAnEmptyServerSnapshot() {
        var transcript = Transcript(messages: [.init(id: "pending", role: "user", text: "Keep me", delivery: .sending)])
        transcript.hydrate(["messages": []])
        XCTAssertEqual(transcript.messages.first?.delivery, .uncertain)
        XCTAssertEqual(transcript.messages.first?.text, "Keep me")
    }

    func testInFlightUserDoesNotDuplicateOptimisticMessage() {
        var transcript = Transcript(messages: [.init(id: "pending", role: "user", text: "Bonjour", delivery: .uncertain)])
        transcript.hydrate(["messages": [], "running": true, "inflight": ["user": "Bonjour", "assistant": "Sal"]])
        XCTAssertEqual(transcript.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(transcript.messages.last?.text, "Sal")
    }

    func testAuthoritativeCompletionReplacesPartialText() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.delta", text: "Partial partial"))
        let id = transcript.messages.first?.id
        transcript.apply(event(2, "message.complete", text: "Final"))
        XCTAssertEqual(transcript.messages.map(\.text), ["Final"])
        XCTAssertEqual(transcript.messages.first?.id, id)
        XCTAssertFalse(transcript.running)
    }

    func testInterimMessageStaysSeparateFromFinal() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.delta", text: "Je cherche."))
        transcript.apply(event(2, "message.interim", text: "Je cherche."))
        transcript.apply(event(3, "message.delta", text: "Trouvé"))
        transcript.apply(event(4, "message.complete", text: "Trouvé !"))
        XCTAssertEqual(transcript.messages.map(\.text), ["Je cherche.", "Trouvé !"])
    }

    func testReplayGapRebuildsCurrentTurnWithoutDuplicatingSnapshot() {
        var transcript = Transcript()
        transcript.recover(["messages": [["role": "user", "text": "Hi"]], "running": true,
            "inflight": ["user": "Hi", "assistant": "Hello"]],
            events: [event(8, "message.start"), event(9, "message.delta", text: "Hello"), event(10, "message.delta", text: " world")], latestSequence: 10)
        XCTAssertEqual(transcript.messages.map(\.text), ["Hi", "Hello world"])
        XCTAssertEqual(transcript.lastSequence, 10)
    }

    func testTruncatedStreamOverlapSupportsUnicodeAndRepeatedText() {
        XCTAssertEqual(Transcript.mergeStream(snapshot: "Bonjour à vous", replay: "à vous 👋"), "Bonjour à vous 👋")
        XCTAssertEqual(Transcript.mergeStream(snapshot: "abcabc", replay: "abcabcX"), "abcabcX")
        XCTAssertEqual(Transcript.mergeStream(snapshot: "snapshot", replay: "unrelated"), "snapshot")
        XCTAssertEqual(Transcript.mergeStream(snapshot: "Bonjour", replay: "jour"), "Bonjour")
    }

    func testBackendRestartCanResetSequenceWithSnapshot() {
        var transcript = Transcript(lastSequence: 987)
        transcript.recover(["messages": [["role": "assistant", "text": "Saved"]]], events: [], latestSequence: 0)
        transcript.apply(event(1, "message.delta", text: "New"))
        XCTAssertEqual(transcript.lastSequence, 1)
        XCTAssertEqual(transcript.messages.last?.text, "New")
    }

    func testCanonicalProfileUsesCompressionTip() {
        let agent = AgentProfile(["name": "research", "canonical_session": ["id": "root", "resolved_id": "tip"]])
        XCTAssertEqual(agent.canonicalID, "tip")
    }

    func testHiddenAndToolRowsStayOutOfConversationBubbles() {
        var transcript = Transcript()
        transcript.hydrate(["messages": [["role": "user", "text": "secret scaffold", "display_kind": "hidden"], ["role": "tool", "name": "terminal"], ["role": "assistant", "text": "Visible"]]])
        XCTAssertEqual(transcript.messages.map(\.text), ["Visible"])
    }

    func testSnapshotRestoresPendingApproval() {
        var transcript = Transcript()
        transcript.hydrate(["messages": [], "running": true, "pending_approval": ["request_id": "r", "choices": ["once", "deny"]]])
        XCTAssertEqual(transcript.approval?["request_id"], "r")
        XCTAssertTrue(transcript.running)
    }

    func testNativeCronIdentityAndPausedState() {
        let routine = Routine(["job_id": "job-42", "name": "[bot:research] Briefing", "enabled": false, "schedule": "Every morning"])
        XCTAssertEqual(routine.id, "job-42")
        XCTAssertEqual(routine.name, "Briefing")
        XCTAssertTrue(routine.paused)
    }

    private func event(_ seq: Int, _ type: String, text: String = "") -> JSONValue {
        ["session_id": "runtime", "seq": .number(Double(seq)), "type": .string(type), "payload": ["text": .string(text)]]
    }
}
