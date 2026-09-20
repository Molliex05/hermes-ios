import XCTest
@testable import HermesIOSCore

final class ProtocolTests: XCTestCase {
    func testMarkdownBlocksAndNestedLists() {
        XCTAssertEqual(ChatMarkdown.parse("## Titre\n\nTexte **fort**\n\n3. Trois\n  - Enfant\n- [x] Fait\n> Citation\n---"), [
            .heading(2, "Titre"), .paragraph("Texte **fort**"),
            .item(depth: 0, marker: "3.", text: "Trois", checked: nil),
            .item(depth: 1, marker: "•", text: "Enfant", checked: nil),
            .item(depth: 0, marker: "•", text: "Fait", checked: true), .quote("Citation"), .rule])
    }

    func testStreamingCodeFencePreservesIndentationAndInlineBackticks() {
        XCTAssertEqual(ChatMarkdown.parse("Du `code` ici.\n\n```swift\n  let x = 1\n"), [
            .paragraph("Du `code` ici."), .code(language: "swift", text: "  let x = 1\n")])
        XCTAssertEqual(ChatMarkdown.parse("````md\n```swift\n````\nAprès"), [
            .code(language: "md", text: "```swift"), .paragraph("Après")])
        XCTAssertEqual(ChatMarkdown.parse("~~~~\n a\n~~~~"), [.code(language: "", text: " a")])
    }

    func testMarkdownTableEscapingAndIncompleteRows() {
        XCTAssertEqual(ChatMarkdown.cells("| ``a`|b`` | c |"), ["``a`|b``", "c"])
        XCTAssertEqual(ChatMarkdown.parse("| Nom | Valeur |\n| --- | :---: |\n| `a|b` | **oui** |\n| Suite |"), [
            .table([["Nom", "Valeur"], ["`a|b`", "**oui**"], ["Suite", ""]])])
        XCTAssertEqual(ChatMarkdown.cells("| a\\|b | c |"), ["a\\|b", "c"])
    }

    func testStreamingParagraphKeepsUnicodeAndBlankLines() {
        XCTAssertEqual(ChatMarkdown.parse("Été 👋\nligne 2\n\nFin"), [.paragraph("Été 👋\nligne 2"), .paragraph("Fin")])
        XCTAssertEqual(ChatMarkdown.parse(""), [])
    }

    func testEmptyDeltasDoNotHideThinking() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        transcript.apply(event(2, "message.delta", text: ""))
        XCTAssertEqual(transcript.activity, "Réfléchit…")
        XCTAssertTrue(transcript.messages.isEmpty)
    }

    func testInterruptedCompletionKeepsVisiblePartialAnswer() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.delta", text: "Déjà reçu"))
        transcript.apply(["seq": 2, "type": "message.complete", "payload": ["status": "interrupted", "text": ""]])
        XCTAssertEqual(transcript.messages.first?.text, "Déjà reçu")
        XCTAssertFalse(transcript.messages.first?.streaming ?? true)
        XCTAssertFalse(transcript.running)
    }

    func testErrorEndsBubbleBeforeTheNextStream() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.delta", text: "Ancienne réponse"))
        transcript.apply(["seq": 2, "type": "error", "payload": ["message": "Provider unavailable"]])
        transcript.apply(event(3, "message.start"))
        transcript.apply(event(4, "message.delta", text: "Nouvelle réponse"))
        XCTAssertEqual(transcript.messages.map(\.text), ["Ancienne réponse", "Nouvelle réponse"])
        XCTAssertNil(transcript.failure)
    }

    func testProfileHistoryMigratesAndKeepsSeparateLists() throws {
        let local = Conversation(["id": "local"], profile: "default")
        let bot = Conversation(["id": "bot"], profile: "noriven")
        var index = ConversationIndex(legacy: [local, bot])
        index.update([], profile: "default")
        XCTAssertTrue(index["default"].isEmpty)
        XCTAssertEqual(index["noriven"].map(\.id), ["bot"])
        let restored = try JSONDecoder().decode(ConversationIndex.self, from: JSONEncoder().encode(index))
        XCTAssertEqual(restored["noriven"].map(\.id), ["bot"])
        XCTAssertTrue(restored["unknown"].isEmpty)
    }

    func testProfileHistoryRejectsRowsFromAnotherProfile() {
        var index = ConversationIndex()
        index.update([Conversation(["id": "private"], profile: "noriven")], profile: "default")
        XCTAssertTrue(index["default"].isEmpty)
    }

    func testWaitingIndicatorRespectsActivityAndUserRequests() {
        var transcript = Transcript()
        transcript.apply(event(1, "message.start"))
        let later = transcript.lastActivityAt.addingTimeInterval(16)
        XCTAssertFalse(transcript.isWaitingForResponse(at: transcript.lastActivityAt))
        XCTAssertTrue(transcript.isWaitingForResponse(at: later))
        transcript.approval = ["request_id": "approve"]
        XCTAssertFalse(transcript.isWaitingForResponse(at: later))
        transcript.approval = nil
        transcript.apply(event(2, "tool.start"))
        XCTAssertFalse(transcript.isWaitingForResponse(at: later))
        transcript.apply(event(3, "message.complete", text: "Done"))
        XCTAssertFalse(transcript.isWaitingForResponse(at: later))
    }

    @MainActor
    func testHistorySharesConcurrentReadsAndSurvivesDismissal() async throws {
        let requests = HistoryRequests()
        var fetches = 0
        var entered = 0
        var gate: CheckedContinuation<JSONValue, Error>?
        let fetch: @MainActor () async throws -> JSONValue = {
            fetches += 1
            return try await withCheckedThrowingContinuation { gate = $0 }
        }
        let first = Task { entered += 1; return try await requests.load(scope: "connection-a/default", fetch: fetch) }
        let second = Task { entered += 1; return try await requests.load(scope: "connection-a/default", fetch: fetch) }
        while entered < 2 || gate == nil { await Task.yield() }
        first.cancel()
        gate?.resume(returning: ["sessions": []])
        let result = try await second.value
        _ = try await first.value
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(result, ["sessions": []])
    }

    @MainActor
    func testFailedHistoryReadCanRetryAndOtherProfilesStayIndependent() async throws {
        let requests = HistoryRequests()
        do {
            _ = try await requests.load(scope: "connection-a/default") { throw RPCFailure("Server busy", code: 5006) }
            XCTFail("Failure should propagate")
        } catch let failure as RPCFailure { XCTAssertEqual(failure.code, 5006) }
        let retry = try await requests.load(scope: "connection-a/default") { ["sessions": [["id": "default-session"]]] }
        let other = try await requests.load(scope: "connection-a/research") { ["sessions": [["id": "research-session"]]] }
        XCTAssertEqual(retry["sessions"].array.first?["id"].string, "default-session")
        XCTAssertEqual(other["sessions"].array.first?["id"].string, "research-session")
    }

    @MainActor
    func testStandardVoiceDoesNotRequireOptionalHTTPDiscoveryRoutes() async throws {
        var calls: [String] = []
        let api = NativeVoiceAPI { path, body, rpc in
            calls.append(path)
            if path == "config.get", rpc {
                XCTAssertEqual(body["key"].string, "full")
                return ["config": ["voice": ["silence_threshold": 350, "silence_duration": .number(1.5), "stop_phrases": ["terminer"]]]]
            }
            if path == "/api/audio/transcribe", !rpc { return ["transcript": " Bonjour "] }
            if path == "/api/audio/speak", !rpc { return ["data_url": "data:audio/wav;base64,fixture"] }
            throw RPCFailure("Not found", code: 404)
        }
        let preferences = try await api.preferences()
        XCTAssertFalse(preferences.isGPTLive)
        XCTAssertEqual(preferences.threshold, 350)
        XCTAssertEqual(preferences.silenceDuration, 1.5)
        XCTAssertEqual(preferences.stopPhrases, ["terminer"])
        let text = try await api.transcribe(Data([1]), mimeType: "audio/mp4")
        XCTAssertEqual(text, "Bonjour")
        _ = try await api.speech("Réponse")
        XCTAssertEqual(calls, ["config.get", "/api/audio/transcribe", "/api/audio/speak"])
    }

    func testNativeVoiceModeAliasesAndExplicitlyDisabledStopPhrases() {
        for mode in ["gpt-live", "GPT_LIVE", "gptlive", "live"] {
            XCTAssertTrue(VoicePreferences(["voice_chat_mode": .string(mode)]).isGPTLive)
        }
        XCTAssertFalse(VoicePreferences([:]).isGPTLive)
        XCTAssertEqual(VoicePreferences(["stop_phrases": []]).stopPhrases, [])
    }

    @MainActor
    func testMissingRequiredAudioAPIHasActionableErrorWithoutMaskingAuth() async throws {
        let missing = NativeVoiceAPI { _, _, _ in throw RPCFailure("Not found", code: 404) }
        do {
            _ = try await missing.transcribe(Data([1]), mimeType: "audio/mp4")
            XCTFail("Missing audio must fail explicitly")
        } catch let error as RPCFailure {
            XCTAssertEqual(error.code, 404)
            XCTAssertTrue(error.localizedDescription.contains("transcription depuis l’iPhone"))
        }
        let unauthorized = NativeVoiceAPI { _, _, _ in throw RPCFailure("Reconnectez-vous", code: 401) }
        do {
            _ = try await unauthorized.speech("Hello")
            XCTFail("Authentication errors must propagate")
        } catch let error as RPCFailure {
            XCTAssertEqual(error.code, 401)
            XCTAssertEqual(error.localizedDescription, "Reconnectez-vous")
        }
    }

    func testVoiceEndpointWaitsForSpeechThenConfiguredSilence() {
        var detector = VoiceActivity(threshold: 200, silenceDuration: 1)
        for _ in 0..<40 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
        XCTAssertFalse(detector.hasSpeech)
        for _ in 0..<8 { XCTAssertFalse(detector.sample(decibels: -20, interval: 0.05)) }
        XCTAssertTrue(detector.hasSpeech)
        for _ in 0..<19 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
        XCTAssertTrue(detector.sample(decibels: -90, interval: 0.05))
    }
    func testVoiceStopPhraseMustBeTheWholeUtterance() {
        XCTAssertTrue(VoiceActivity.isStop("Stop !", phrases: ["stop"]))
        XCTAssertTrue(VoiceActivity.isStop("Termine la conversation.", phrases: ["termine la conversation"]))
        XCTAssertFalse(VoiceActivity.isStop("Stop le serveur Docker", phrases: ["stop"]))
        XCTAssertFalse(VoiceActivity.isStop("stop", phrases: []))
        XCTAssertFalse(VoiceActivity.isStop("...", phrases: [""]))
    }
    func testShortClickDoesNotCountAsVoice() {
        var detector = VoiceActivity(threshold: 200, silenceDuration: 1)
        XCTAssertFalse(detector.sample(decibels: -10, interval: 0.05))
        for _ in 0..<40 { XCTAssertFalse(detector.sample(decibels: -90, interval: 0.05)) }
    }

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

extension ProtocolTests {
    func testModernRequestsAreSessionScopedAndCanceledSnapshotCannotResurrect() {
        var inbox = ServerRequests()
        let request: JSONValue = ["id": "srq-a", "method": "approval", "params": ["session_id": "a", "choices": ["once", "deny"]]]
        XCTAssertTrue(inbox.insert(request))
        XCTAssertTrue(inbox.insert(request)); XCTAssertEqual(inbox.frames.count, 1)
        XCTAssertNil(inbox.payload(session: "b", methods: ["approval"]))
        XCTAssertEqual(inbox.payload(session: "a", methods: ["approval"])?["rpc_id"], "srq-a")
        inbox.retire("srq-a")
        XCTAssertFalse(inbox.insert(request)); XCTAssertTrue(inbox.frames.isEmpty)
        XCTAssertFalse(inbox.insert(["id": "unknown", "method": "preview.act"]))
    }

    func testLockedBatchAnswerSurvivesStaleSnapshot() {
        var inbox = ServerRequests()
        let request: JSONValue = ["id": "srq-q", "method": "clarify", "params": ["session_id": "a", "questions": [["qid": "one", "question": "A?"]]]]
        inbox.insert(request); inbox.lock("srq-q", question: "one", answer: "Yes")
        inbox.insert(request)
        XCTAssertEqual(inbox.payload(session: "a", methods: ["clarify"])?["answers"]["one"], "Yes")
    }

    func testRecoveryDoesNotResurrectExpiredControlCards() {
        var transcript = Transcript()
        transcript.recover(["messages": [], "running": true], events: [
            ["seq": 1, "type": "approval.request", "payload": ["request_id": "old"]],
            ["seq": 2, "type": "approval.expire", "payload": ["request_id": "old"]],
            ["seq": 3, "type": "clarify.request", "payload": ["request_id": "question"]],
            ["seq": 4, "type": "clarify.expire", "payload": ["request_id": "question"]]
        ], latestSequence: 4)
        XCTAssertNil(transcript.approval); XCTAssertNil(transcript.clarification)
        transcript.apply(["seq": 5, "type": "approval.request", "payload": ["request_id": "new"]])
        transcript.apply(["seq": 6, "type": "approval.expire", "payload": ["request_id": "old"]])
        XCTAssertEqual(transcript.approval?["request_id"], "new")
    }

    func testCompletionClearsSensitivePrompt() {
        var transcript = Transcript()
        transcript.apply(["type": "secret.request", "payload": ["request_id": "s"]])
        transcript.apply(["type": "message.complete", "payload": ["text": "Finished"]])
        XCTAssertNil(transcript.credential)
    }
    func testVoiceCursorNeverReplaysOnFinalSnapshot() throws {
        var cursor = VoiceTextCursor()
        XCTAssertEqual(try cursor.delta("Bonjour 👋. "), "Bonjour 👋. ")
        XCTAssertEqual(try cursor.delta("Bonjour 👋. Suite. "), "Suite. ")
        XCTAssertEqual(try cursor.delta("Bonjour 👋. Suite."), "")
        XCTAssertThrowsError(try cursor.delta("Une autre réponse."))
    }
    func testVoiceSocketKeepsProfileAndProxyPrefix() throws {
        let endpoint = try Endpoint("https://agent.ts.net/hermes")
        let url = endpoint.socket(ticket: "a&b", path: "/api/audio/speak-stream", query: [.init(name: "profile", value: "research")])
        XCTAssertEqual(url.path, "/hermes/api/audio/speak-stream")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "profile" }?.value, "research")
        XCTAssertEqual(query.first { $0.name == "ticket" }?.value, "a&b")
    }
    func testConfigurationPatchAndBotPresentation() {
        let patch = JSONValue.patch("approvals.mode", value: "manual")
        XCTAssertEqual(patch.at("approvals.mode"), "manual")
        XCTAssertTrue(patch.at("approvals.other").isNull)
        let bot = AgentProfile(["name": "research", "display_name": "Old", "ui_meta": ["hermes-bots": ["title": "Recherche", "pinned": true, "hidden": true]]])
        XCTAssertEqual(bot.title, "Recherche"); XCTAssertEqual(bot.pinned, true); XCTAssertEqual(bot.hidden, true)
    }

    func testSlashParsingPreservesArgumentsAndIgnoresFilePaths() {
        XCTAssertEqual(SlashInput("/compact  garder les décisions")?.name, "compact")
        XCTAssertEqual(SlashInput("/compact  garder les décisions")?.argument, "garder les décisions")
        XCTAssertNil(SlashInput("/Users/maxime/fichier.md"))
        XCTAssertNil(SlashInput("Un texte /compact"))
    }
    func testCompletedSessionRetiresOnlyItsOpenRequests() {
        var store = ServerRequests()
        let frame: JSONValue = ["id": "srq-1", "method": "secret", "params": ["session_id": "one"]]
        store.insert(frame)
        store.insert(["id": "srq-2", "method": "approval", "params": ["session_id": "two"]])
        store.retire(session: "one")
        XCTAssertFalse(store.insert(frame))
        XCTAssertEqual(store.frames.count, 1)
        XCTAssertEqual(store.frames[0]["id"], "srq-2")
    }

    func testOwnershipRefusalKeepsMachineReadableReason() {
        let failure = RPCFailure(responseError: ["code": 4090, "message": "Localized server text", "data": ["reason": "SESSION_NOT_OWNED"]])
        XCTAssertTrue(failure.sessionOwnedElsewhere)
        XCTAssertEqual(failure.reason, "SESSION_NOT_OWNED")
        XCTAssertTrue(RPCFailure("Session abc already has a live owner (desktop)", code: 4090).sessionOwnedElsewhere)
        XCTAssertFalse(RPCFailure("Session limit", code: 4090, reason: "MAX_CONCURRENT_SESSIONS").sessionOwnedElsewhere)
        XCTAssertFalse(RPCFailure("already has a live owner", code: 4090, reason: "SESSION_COORDINATION_UNAVAILABLE").sessionOwnedElsewhere)
        XCTAssertFalse(RPCFailure("Network timeout", code: -2).sessionOwnedElsewhere)
    }

    func testAcceptedTurnCannotBecomeUnsentAfterLateFailure() {
        for error in [RPCFailure("connection lost", code: -1), RPCFailure("late server error", code: 5000), RPCFailure("late refusal", code: 4090)] {
            var transcript = Transcript(messages: [.init(id: "sent", role: "user", text: "Work", delivery: .confirmed)])
            transcript.running = true
            XCTAssertEqual(transcript.submissionFailed(id: "sent", error: error), .confirmed)
            XCTAssertTrue(transcript.running)
        }
    }

    func testLostAcknowledgementPreservesTurnUntilNativeResume() {
        for error in [RPCFailure("timeout", code: -2), RPCFailure("internal", code: 5000), CancellationError()] as [Error] {
            var transcript = Transcript(messages: [.init(id: "sent", role: "user", text: "Work", delivery: .sending)])
            transcript.running = true
            XCTAssertEqual(transcript.submissionFailed(id: "sent", error: error), .uncertain)
            XCTAssertTrue(transcript.running)
            transcript.hydrate(["running": false, "messages": [["role": "user", "text": "Work"], ["role": "assistant", "text": "Done"]]])
            XCTAssertEqual(transcript.messages.count, 2)
            XCTAssertEqual(transcript.messages.first?.id, "sent")
            XCTAssertEqual(transcript.messages.first?.delivery, .confirmed)
            XCTAssertFalse(transcript.running)
        }
    }

    func testNativeRefusalRemainsDistinctFromConnectionLoss() {
        var transcript = Transcript(messages: [.init(id: "sent", role: "user", text: "Work", delivery: .sending)])
        transcript.running = true
        XCTAssertEqual(transcript.submissionFailed(id: "sent", error: RPCFailure("owned", code: 4090)), .failed)
        XCTAssertFalse(transcript.running)
        XCTAssertTrue(RPCFailure("settling", code: 4009).retryableSessionResume)
        XCTAssertTrue(RPCFailure("retry resume", code: 4007).retryableSessionResume)
        XCTAssertFalse(RPCFailure("owned", code: 4090).retryableSessionResume)
    }

    func testToolEventsRestoreExecutionWithoutAcknowledgingUnrelatedPrompt() {
        var transcript = Transcript(messages: [.init(id: "pending", role: "user", text: "Work", delivery: .uncertain)])
        transcript.apply(["seq": 1, "type": "tool.start", "payload": ["name": "terminal"]])
        XCTAssertTrue(transcript.running)
        XCTAssertEqual(transcript.messages.first?.delivery, .uncertain)
        transcript.apply(["seq": 2, "type": "message.complete", "payload": ["text": "Done"]])
        XCTAssertFalse(transcript.running)
        XCTAssertEqual(transcript.messages.first?.delivery, .uncertain)
    }

    func testNotificationSelectsOnlyAnExplicitNativeConversation() {
        let connection = UUID()
        let payload: JSONValue = ["aps": ["alert": "Message"], "hermes": [
            "version": 1, "event_id": "event-42", "connection_id": .string(connection.uuidString),
            "profile": "research", "session_id": "20260920_bot_123"]]
        let target = NotificationTarget(payload)
        XCTAssertEqual(target?.connectionID, connection)
        XCTAssertEqual(target?.profile, "research")
        XCTAssertEqual(target?.sessionID, "20260920_bot_123")
        var fields = payload["hermes"].object
        fields["session_id"] = "../../private"
        XCTAssertNil(NotificationTarget(["hermes": .object(fields)]))
        fields["session_id"] = "https://attacker.example"
        XCTAssertNil(NotificationTarget(["hermes": .object(fields)]))
        fields["session_id"] = "valid"; fields["connection_id"] = "unknown"
        XCTAssertNil(NotificationTarget(["hermes": .object(fields)]))
        XCTAssertNil(NotificationTarget(["url": "https://attacker.example", "session_id": "valid"]))
    }

}
