import XCTest
@testable import HermesIOSCore

final class NotificationCryptoTests: XCTestCase {
    private struct Vector {
        let key: Data, nonce: Data, eventID: String, plaintext: Data, enc: String
    }

    private func vector() throws -> Vector {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("HermesIOSTests/Fixtures/notification-vector.json")
        let json = try JSONValue.decode(Data(contentsOf: url))
        return Vector(key: Data(base64Encoded: json["key_b64"].string)!, nonce: Data(base64Encoded: json["nonce_b64"].string)!,
                      eventID: json["event_id"].string, plaintext: Data(json["plaintext_json"].string.utf8), enc: json["enc_b64"].string)
    }

    func testDecryptsSharedVector() throws {
        let v = try vector()
        let content = NotificationCrypto.decrypt(v.enc, key: v.key, eventID: v.eventID)
        XCTAssertEqual(content, NotificationContent(agent: "Hermès", conversation: "Rapport SEO", preview: "Le rapport est prêt."))
    }

    func testEncryptMatchesVectorByteForByte() throws {
        let v = try vector()
        XCTAssertEqual(NotificationCrypto.encrypt(v.plaintext, key: v.key, eventID: v.eventID, nonce: v.nonce), v.enc)
    }

    func testRandomNonceRoundTrip() throws {
        let v = try vector()
        let a = NotificationCrypto.encrypt(v.plaintext, key: v.key, eventID: v.eventID)
        let b = NotificationCrypto.encrypt(v.plaintext, key: v.key, eventID: v.eventID)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(NotificationCrypto.decrypt(a!, key: v.key, eventID: v.eventID)?.preview, "Le rapport est prêt.")
    }

    func testFailuresReturnNil() throws {
        let v = try vector()
        var wrongKey = v.key; wrongKey[0] ^= 1
        XCTAssertNil(NotificationCrypto.decrypt(v.enc, key: wrongKey, eventID: v.eventID))
        XCTAssertNil(NotificationCrypto.decrypt(v.enc, key: v.key, eventID: "11111111-2222-3333-4444-555555555556"))
        XCTAssertNil(NotificationCrypto.decrypt(v.enc, key: v.key, eventID: ""))
        XCTAssertNil(NotificationCrypto.decrypt(v.enc, key: v.key.prefix(16), eventID: v.eventID))
        let bytes = Data(base64Encoded: v.enc)!
        XCTAssertNil(NotificationCrypto.decrypt(bytes.dropLast().base64EncodedString(), key: v.key, eventID: v.eventID))
        XCTAssertNil(NotificationCrypto.decrypt(bytes.prefix(20).base64EncodedString(), key: v.key, eventID: v.eventID))
        XCTAssertNil(NotificationCrypto.decrypt(bytes.prefix(5).base64EncodedString(), key: v.key, eventID: v.eventID))
        var flipped = bytes; flipped[20] ^= 0xff
        XCTAssertNil(NotificationCrypto.decrypt(flipped.base64EncodedString(), key: v.key, eventID: v.eventID))
        for bad in ["", "!!!not-base64!!!", "AAAA", String(repeating: "A", count: 20_000)] {
            XCTAssertNil(NotificationCrypto.decrypt(bad, key: v.key, eventID: v.eventID))
        }
        XCTAssertNil(NotificationCrypto.encrypt(v.plaintext, key: v.key.prefix(10), eventID: v.eventID))
        XCTAssertNil(NotificationCrypto.encrypt(v.plaintext, key: v.key, eventID: v.eventID, nonce: Data([1, 2, 3])))
    }

    func testNonJSONPlaintextIsRejected() throws {
        let v = try vector()
        let enc = NotificationCrypto.encrypt(Data("pas du json".utf8), key: v.key, eventID: v.eventID)!
        XCTAssertNil(NotificationCrypto.decrypt(enc, key: v.key, eventID: v.eventID))
        let empty = NotificationCrypto.encrypt(Data("{}".utf8), key: v.key, eventID: v.eventID)!
        XCTAssertNil(NotificationCrypto.decrypt(empty, key: v.key, eventID: v.eventID))
    }

    func testGeneratedKeysAre32RandomBytes() {
        let a = NotificationKeyStore.generateKey(), b = NotificationKeyStore.generateKey()
        XCTAssertEqual(a?.count, 32); XCTAssertNotEqual(a, b)
    }

    // MARK: Envelope, thread id, tap targets

    private let connection = "0F6F1A5C-6B0E-4D2B-9C55-1A2B3C4D5E6F"

    func testThreadIDMatchesServerHash() {
        let id = UUID(uuidString: connection)!
        XCTAssertEqual(NotificationEnvelope.threadID(connection: id, profile: "noriven", session: "sess_1"),
                       "eadd51b0175a803fed194eec666d84e71ba9ebabfada6e0de5a4f1eb9f899793")
        XCTAssertEqual(NotificationEnvelope.threadID(connection: id, profile: "noriven", session: nil),
                       "78643ec8ebbf08a7c4273b3f0d5f98d0355209a035c400eb0416524f1b267f06")
    }

    func testV01PayloadStillWorks() {
        let payload: JSONValue = ["hermes": ["version": 1, "event_id": "e1", "connection_id": .string(connection),
                                            "profile": "noriven", "session_id": "sess_1"]]
        XCTAssertNotNil(NotificationTarget(payload))
        let envelope = NotificationEnvelope(payload)
        XCTAssertEqual(envelope?.kind, .turn)
        XCTAssertEqual(envelope?.sessionID, "sess_1")
        XCTAssertNil(envelope?.enc)
    }

    func testV02PayloadKindAndMissingSession() {
        let tool: JSONValue = ["hermes": ["version": 1, "event_id": "e2", "connection_id": .string(connection),
                                         "profile": "noriven", "kind": "tool", "enc": "abc"]]
        let envelope = NotificationEnvelope(tool)
        XCTAssertEqual(envelope?.kind, .tool)
        XCTAssertNil(envelope?.sessionID)
        XCTAssertEqual(envelope?.enc, "abc")
        XCTAssertNil(NotificationTarget(tool), "no session: the tap just opens the app")
        let unknown: JSONValue = ["hermes": ["version": 1, "event_id": "e3", "connection_id": .string(connection),
                                            "profile": "noriven", "session_id": "s", "kind": "weird"]]
        XCTAssertEqual(NotificationEnvelope(unknown)?.kind, .turn)
        let badSession: JSONValue = ["hermes": ["version": 1, "event_id": "e3", "connection_id": .string(connection),
                                               "profile": "noriven", "session_id": "../x"]]
        XCTAssertNil(NotificationEnvelope(badSession))
        XCTAssertNil(NotificationEnvelope(["aps": [:]]))
    }

    func testKeyTransportPolicy() {
        let allowed = ["https://hermes.example.com", "http://localhost:9119", "http://127.0.0.1:9119", "http://[::1]:9119",
                       "http://100.64.0.1:9119", "http://100.127.255.254", "http://[fd7a:115c:a1e0::1]:9119", "http://mac.tail1234.ts.net:9119"]
        let refused = ["http://192.168.1.10:9119", "http://10.0.0.5", "http://100.128.0.1", "http://100.63.0.1", "http://mac.local:9119",
                       "http://example.com", "http://[fd7b::1]", "ftp://localhost", "http://100.64.0.1.evil.com"]
        for s in allowed { XCTAssertTrue(NotificationKeyTransport.allowsKey(over: URL(string: s)!), s) }
        for s in refused { XCTAssertFalse(NotificationKeyTransport.allowsKey(over: URL(string: s)!), s) }
    }
}
