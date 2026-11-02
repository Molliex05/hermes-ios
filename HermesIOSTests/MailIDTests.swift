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
        XCTAssertEqual(OutboxDraft.path(profile: "noriven", draftID: noriven), "/api/plugins/hermes-widgets/drafts/noriven/\(noriven)")
        XCTAssertNil(OutboxDraft.path(profile: "noriven", draftID: noriven + "/../x"))
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
