import XCTest
@testable import HermesIOSCore

final class HydrateTests: XCTestCase {
    private func payload(_ rows: [(role: String, text: String, row: Int?)]) -> JSONValue {
        .object(["messages": .array(rows.map { row in
            var fields: [String: JSONValue] = ["role": .string(row.role), "text": .string(row.text)]
            if let id = row.row { fields["row_id"] = .number(Double(id)) }
            return .object(fields)
        })])
    }

    func testIdentitiesSurviveAndDuplicatesMatchInOrder() {
        var transcript = Transcript(messages: [
            .init(id: "a", role: "user", text: "Bonjour"), .init(id: "b", role: "assistant", text: "Salut"),
            .init(id: "c", role: "user", text: "Bonjour"), .init(id: "d", role: "assistant", text: "Re-salut")], lastSequence: 0)
        transcript.hydrate(payload([("user", "Bonjour", nil), ("assistant", "Salut", nil), ("user", "Bonjour", nil), ("assistant", "Re-salut", nil), ("user", "Nouveau", nil)]))
        XCTAssertEqual(transcript.messages.map(\.id).prefix(4), ["a", "b", "c", "d"])
        XCTAssertEqual(transcript.messages.count, 5)
        XCTAssertFalse(["a", "b", "c", "d"].contains(transcript.messages[4].id))
    }

    func testStableRowIdMatchesEvenWhenTextChanged() {
        var transcript = Transcript(messages: [.init(id: "row-7", role: "assistant", text: "brouillon")], lastSequence: 0)
        transcript.hydrate(payload([("assistant", "version finale", 7)]))
        XCTAssertEqual(transcript.messages.first?.id, "row-7")
        XCTAssertEqual(transcript.messages.first?.text, "version finale")
    }

    func testLargeHistoryHydratesQuickly() {
        let rows = (0..<2000).map { (role: $0 % 2 == 0 ? "user" : "assistant", text: "Message numéro \($0)", row: Optional($0)) }
        var transcript = Transcript(messages: rows.enumerated().map { .init(id: "row-\($0.offset)", role: $0.element.role, text: $0.element.text) }, lastSequence: 0)
        let start = Date()
        transcript.hydrate(payload(rows))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertEqual(transcript.messages.count, 2000)
        XCTAssertEqual(transcript.messages[1999].id, "row-1999")
    }
}
