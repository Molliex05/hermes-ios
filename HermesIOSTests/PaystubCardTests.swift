import XCTest
@testable import HermesIOSCore

final class PaystubCardTests: XCTestCase {
    private let card = """
    {"type":"paie","date":"2026-11-19","semaine":"du 1er au 7 novembre","statut":"écart",
     "lignes":[{"label":"Heures régulières","valeur":"36,0 h","agenda":"40,0 h","ecart":true},{"label":"Temps supplémentaire","valeur":"2,5 h"},{"label":"","valeur":"x"}],
     "net":"1 234,56 $","brut":"1 800,00 $","ajustements":["Semaine 43 : +3 h de prime de soir"],"note":"Il manque le quart du 4 novembre."}
    """

    func testReadsAPayslipCard() throws {
        guard case .paystub(let stub)? = ChatCard.parse(card) else { return XCTFail("not a payslip card") }
        XCTAssertEqual(stub.payDate, "2026-11-19"); XCTAssertNotNil(stub.day)
        XCTAssertEqual(stub.verdict, .gap)
        XCTAssertEqual(stub.lines.map(\.label), ["Heures régulières", "Temps supplémentaire"], "a line without a label is dropped")
        XCTAssertTrue(stub.lines[0].gap); XCTAssertEqual(stub.lines[0].calendar, "40,0 h"); XCTAssertFalse(stub.lines[1].gap)
        XCTAssertEqual(stub.net, "1 234,56 $"); XCTAssertEqual(stub.gross, "1 800,00 $")
        XCTAssertEqual(stub.adjustments.count, 1)
    }

    func testTheVerdict() {
        func verdict(_ status: String, gap: Bool = false) -> ChatCard.Verdict? {
            let json = #"{"type":"talon","date":"2026-11-19","statut":"\#(status)","lignes":[{"label":"Heures","valeur":"40 h","ecart":\#(gap)}]}"#
            guard case .paystub(let stub)? = ChatCard.parse(json) else { return nil }
            return stub.verdict
        }
        XCTAssertEqual(verdict("balance"), .balance)
        XCTAssertEqual(verdict("Tout balance"), .balance)
        XCTAssertEqual(verdict("à revoir"), .gap)
        XCTAssertEqual(verdict("", gap: true), .gap, "a line marked as a gap makes the card a gap")
        XCTAssertEqual(verdict(""), .check, "no verdict given: to check, never « balance » by default")
    }

    func testThePayDateMustBeARealDay() {
        XCTAssertNil(ChatCard.parse(#"{"type":"paie","date":"2026-02-30","net":"1 $"}"#))
        XCTAssertNil(ChatCard.parse(#"{"type":"paie","date":"../../etc","net":"1 $"}"#))
        XCTAssertNil(ChatCard.parse(#"{"type":"paie","net":"1 $"}"#))
    }

    func testThePDFIsAskedByProfileAndDateOnly() {
        XCTAssertEqual(ChatCard.Paystub.path(profile: "personnel", payDate: "2026-11-19"), "/api/plugins/hermes-paie/talon/personnel/2026-11-19")
        XCTAssertNil(ChatCard.Paystub.path(profile: "../noriven", payDate: "2026-11-19"))
        XCTAssertNil(ChatCard.Paystub.path(profile: "personnel", payDate: "2026-11-19/../x"))
    }

    func testOnlyAPDFComesBack() {
        let pdf = Data("%PDF-1.7 talon".utf8).base64EncodedString()
        XCTAssertNotNil(ChatCard.Paystub.pdf(from: .object(["date": "2026-11-19", "pdf": .string(pdf)]), payDate: "2026-11-19"))
        XCTAssertNil(ChatCard.Paystub.pdf(from: .object(["date": "2026-11-12", "pdf": .string(pdf)]), payDate: "2026-11-19"), "another payslip")
        XCTAssertNil(ChatCard.Paystub.pdf(from: .object(["date": "2026-11-19", "pdf": .string(Data("<html>".utf8).base64EncodedString())]), payDate: "2026-11-19"))
    }

    func testReadsAsTextAndAsAGlance() {
        guard let parsed = ChatCard.parse(card) else { return XCTFail() }
        XCTAssertTrue(ChatCard.summary(card).joined(separator: "\n").contains("Heures régulières · 36,0 h · agenda 40,0 h"))
        XCTAssertEqual(CardGlance(parsed)?.value, "1 234,56 $")
    }
}
