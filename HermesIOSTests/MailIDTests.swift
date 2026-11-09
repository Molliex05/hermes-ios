import XCTest
@testable import HermesIOSCore

final class MailIDTests: XCTestCase {
    private let noriven = "m1.WyJtc2ciLCJwb2xhcmlzOjEyMyJd." + String(repeating: "a", count: 22)

    func testGmailAndNorivenIdsAreAcceptedAndNothingElse() {
        XCTAssertTrue(MailID.validMessage("18f2a9c0d1e2")); XCTAssertTrue(MailID.validDraft("r5784066649391460414"))
        XCTAssertTrue(MailID.validMessage(noriven)); XCTAssertTrue(MailID.validDraft(noriven)); XCTAssertTrue(MailID.isNoriven(noriven))
        for bad in ["../admin", "m1.abc.short", noriven + "/send", "m1.a b." + String(repeating: "a", count: 22), "abc"] {
            XCTAssertFalse(MailID.validMessage(bad), bad)
        }
        XCTAssertFalse(MailID.isNoriven("r5784066649391460414"))
        XCTAssertTrue(MailID.isNorivenMessage("n-k2m7xq7a")); XCTAssertTrue(MailID.validMessage("n-k2m7xq7a"))
        XCTAssertFalse(MailID.isNoriven("n-k2m7xq7a"), "a draft is never a short reference")
        XCTAssertFalse(MailID.isNorivenMessage("18f2a9c0d1e2"))
        XCTAssertEqual(OutboxDraft.path(profile: "noriven", draftID: noriven), "/api/plugins/hermes-widgets/drafts/noriven/\(noriven)")
        XCTAssertNil(OutboxDraft.path(profile: "noriven", draftID: noriven + "/../x"))
    }

    func testOnlyAGmailMessageOfThatIdReadsAsAWholeBody() {
        XCTAssertEqual(MailBody.path(profile: "personnel", messageID: "18f2a9c0d1e2"), "/api/plugins/hermes-widgets/messages/personnel/18f2a9c0d1e2")
        XCTAssertEqual(MailBody.path(profile: "noriven", messageID: noriven), "/api/plugins/hermes-widgets/messages/noriven/\(noriven)")
        XCTAssertNil(MailBody.path(profile: "personnel", messageID: "../admin"))
        XCTAssertNil(MailBody.path(profile: "../x", messageID: "18f2a9c0d1e2"))
        let read = MailBody(.object(["id": .string("18f2a9c0d1e2"), "texte": .string("  Bonjour\n"), "tronque": .bool(true)]), messageID: "18f2a9c0d1e2")
        XCTAssertEqual(read?.text, "Bonjour"); XCTAssertEqual(read?.truncated, true)
        XCTAssertNil(MailBody(.object(["id": .string("autre123"), "texte": .string("x")]), messageID: "18f2a9c0d1e2"))
    }

    func testTheSignedTextIsTheContractsExactBytes() {
        let text = String(decoding: SendApproval.message(draftID: noriven, fingerprint: "f0", signedAt: 1793578632, nonce: "AAAA"), as: UTF8.self)
        XCTAssertEqual(text, "noriven-email-send-v1\n\(noriven)\nf0\n1793578632\nAAAA")
    }

    func testNorivenCardsKeepTheirIdsButOfferNoGmailLink() throws {
        let reply = "Voici.\n\n```ui\n{\"type\":\"courriel\",\"id\":\"\(noriven)\",\"de\":\"Julie <julie@example.com>\",\"objet\":\"Facture\"}\n```"
        guard case .card(let json, _) = ChatMarkdown.parse(reply).last, case .email(let message)? = ChatCard.parse(json) else { return XCTFail("expected an email card") }
        XCTAssertEqual(message.email.messageID, noriven)
        XCTAssertNil(message.email.gmailURL)
        let draft = "```ui\n{\"type\":\"draft\",\"id\":\"\(noriven)\",\"to\":\"julie@example.com\",\"subject\":\"Facture\",\"body\":\"Bonjour\"}\n```"
        guard case .card(let djson, _) = ChatMarkdown.parse(draft).last, case .draft(let d)? = ChatCard.parse(djson) else { return XCTFail("expected a draft card") }
        XCTAssertEqual(d.draftID, noriven)
        let outbox = try XCTUnwrap(OutboxDraft(.object(["id": .string(noriven), "fingerprint": .string("f0"), "mailbox": .string("contact@noriven.com"), "to": .string("a@b.c")])))
        XCTAssertTrue(outbox.needsDeviceApproval); XCTAssertEqual(outbox.mailbox, "contact@noriven.com")
    }
}

final class NorivenFingerprintTests: XCTestCase {
    private let id = "m1.WyJkcmYiLCJwb2xhcmlzOjEiXQ." + String(repeating: "s", count: 22)

    private func payload(fingerprint: String, subject: String = "Été — facture", bcc: [String] = ["moi@noriven.com"]) -> JSONValue {
        .object(["id": .string(id), "mailbox": .string("contact@noriven.com"), "from": .string("contact@noriven.com"),
                 "to": .array([.string("Julie Été <julie@example.com>"), .string("bob@example.org")]), "cc": .array([]), "bcc": .array(bcc.map { .string($0) }),
                 "subject": .string(subject), "body": .string("Bonjour,\n\nCi-joint.\n\nMaxime"), "in_reply_to": .string("<abc@x.org>"),
                 "attachments": .array([.object(["name": .string("facture.pdf"), "type": .string("application/pdf"), "size": .number(12345), "sha256": .string(String(repeating: "a", count: 64))])]),
                 "fingerprint": .string(fingerprint)])
    }

    /// Vectors computed with noriven-web's own `draftFingerprint`.
    func testMatchesNorivenWebByteForByte() throws {
        let reference = "b989b51f0598a15383f1a9db7c430b4c53ccde0bc724232e2a6393407129ca6e"
        let draft = try XCTUnwrap(OutboxDraft(payload(fingerprint: reference)))
        XCTAssertTrue(draft.fingerprintMatches)
        XCTAssertEqual(draft.to, "Julie Été <julie@example.com>, bob@example.org")
        XCTAssertEqual(OutboxDraft.norivenFingerprint(id: id, from: "contact@noriven.com", to: ["a@b.co"], cc: [], bcc: [], subject: "", body: "",
                                                      inReplyTo: "", attachments: []), "2804bd0f7681c32cbd9320599f79eeb72c645fa14464c42bcbf81fd43d5bbab8")
    }

    func testAShownDraftThatIsNotTheSignedOneIsCaught() throws {
        let reference = "b989b51f0598a15383f1a9db7c430b4c53ccde0bc724232e2a6393407129ca6e"
        XCTAssertFalse(try XCTUnwrap(OutboxDraft(payload(fingerprint: reference, subject: "Autre chose"))).fingerprintMatches)
        XCTAssertFalse(try XCTUnwrap(OutboxDraft(payload(fingerprint: reference, bcc: []))).fingerprintMatches, "a hidden Bcc changes everything")
        var flattened = payload(fingerprint: reference).object
        flattened["to"] = .string("Julie Été <julie@example.com>, bob@example.org")             // a relay that flattens the lists
        XCTAssertFalse(try XCTUnwrap(OutboxDraft(.object(flattened))).fingerprintMatches)
        var truncated = payload(fingerprint: reference).object
        truncated["truncated"] = .bool(true)
        XCTAssertFalse(try XCTUnwrap(OutboxDraft(.object(truncated))).fingerprintMatches)
        let gmail = try XCTUnwrap(OutboxDraft(.object(["id": .string("r123"), "fingerprint": .string("x"), "to": .string("a@b.c")])))
        XCTAssertTrue(gmail.fingerprintMatches, "Gmail drafts keep their server-side check")
    }
}
