import XCTest
@testable import HermesIOS

@MainActor
final class VoiceLiveTransportTests: XCTestCase {
    func testNativeWebRTCExchangeDelegationMuteAndClose() async throws {
        guard ProcessInfo.processInfo.environment["HERMES_IOS_INTEGRATION"] == "1" else { throw XCTSkip("Requires the isolated loopback GPT-Live fixture.") }
        let http = URLSession(configuration: .ephemeral)
        defer { http.invalidateAndCancel() }
        func request(_ path: String, body: JSONValue) async throws -> JSONValue {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:19159" + path)!)
            request.httpMethod = "POST"; request.httpBody = try body.data()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await http.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return try JSONValue.decode(data)
        }
        _ = try await request("/auth/password-login", body: ["provider": "basic", "username": "hermes-ios-test", "password": "hermes-ios-local-fixture"])
        VoiceLiveTransport.useSilentFixtureAudio()
        let transport = VoiceLiveTransport()
        defer { transport.close() }
        var events: [JSONValue] = []
        transport.onEvent = { events.append($0) }
        try await transport.start(history: []) { body in
            XCTAssertTrue(body["sdp"].string.hasSuffix("\r\n"))
            XCTAssertTrue(body["sdp"].string.contains("m=audio"))
            XCTAssertTrue(body["sdp"].string.contains("m=application"))
            return try await request("/api/audio/voice-live/session?profile=research", body: body)
        }
        XCTAssertTrue(transport.started)
        try transport.setMuted(false)
        let deadline = Date().addingTimeInterval(15)
        while !events.contains(where: { $0["type"] == "session.delegation.created" }) {
            try transport.check()
            guard Date() < deadline else { XCTFail("No delegation arrived over the native data channel"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await transport.append("commentary", delegation: "fixture-first", content: "Réponse native reçue.")
        XCTAssertTrue(events.contains { $0["type"] == "session.commentary.appended" })
        while !events.contains(where: { $0["type"] == "session.output_transcript.delta" }) {
            guard Date() < deadline else { XCTFail("No commentary echo arrived"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try transport.setMuted(true)
        transport.close()
        XCTAssertFalse(transport.started)
        XCTAssertThrowsError(try transport.send(["type": "session.input_audio.unmute"]))
        transport.close() // Idempotent teardown.
    }
}
