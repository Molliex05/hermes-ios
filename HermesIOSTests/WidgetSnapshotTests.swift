import XCTest
@testable import HermesIOSCore

final class WidgetSnapshotTests: XCTestCase {
    // Exactly what the hermes-widgets plugin serves.
    private let server = """
    {"version":1,"currency":"CAD","data_environment":"production","as_of":"2026-10-20","generated_at":"2026-10-20T21:09:20Z",
     "finance":{"month":"2026-10","label":"octobre 2026",
       "current":{"month":"2026-10","estimated_revenue":247.99,"confirmed_revenue":0,"expenses":160.97,"estimated_profit":87.02},
       "previous":{"month":"2026-09","estimated_revenue":275.11,"confirmed_revenue":0,"expenses":28.17,"estimated_profit":246.94},
       "months":[{"month":"2026-09","estimated_revenue":275.11,"confirmed_revenue":0,"expenses":28.17,"estimated_profit":246.94},
                 {"month":"2026-10","estimated_revenue":247.99,"confirmed_revenue":0,"expenses":160.97,"estimated_profit":87.02}]},
     "mrr":{"value":528.12,"active_subscriptions":197,"trialing_subscriptions":25,"month":"2026-09","snapshot_date":"2026-09-09"},
     "projection":null}
    """.data(using: .utf8)!

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testDecodesServerPayload() throws {
        let snapshot = try WidgetSnapshot.decode(server)
        XCTAssertEqual(snapshot.finance.label, "octobre 2026")
        XCTAssertEqual(snapshot.finance.current.estimatedProfit, 87.02, accuracy: 0.001)
        XCTAssertEqual(snapshot.mrr?.activeSubscriptions, 197)
        XCTAssertEqual(snapshot.mrr?.snapshotDate, "2026-09-09")
        XCTAssertNil(snapshot.projection)
        XCTAssertEqual(snapshot.finance.months.count, 2)
        XCTAssertNotNil(snapshot.generatedDate)
    }

    func testDecodesProjectionWhenServerProvidesIt() throws {
        let text = String(data: server, encoding: .utf8)!.replacingOccurrences(of: "\"projection\":null", with: "\"projection\":{\"month_total\":368.49,\"next_month_total\":410.1,\"twelve_month_total\":null,\"months\":[{\"month\":\"2026-10\",\"total\":368.49},{\"month\":\"2026-11\",\"total\":null}]}")
        let projection = try XCTUnwrap(try WidgetSnapshot.decode(Data(text.utf8)).projection)
        XCTAssertEqual(projection.monthTotal, 368.49)
        XCTAssertEqual(projection.nextMonthTotal, 410.1)
        XCTAssertNil(projection.twelveMonthTotal)
        XCTAssertEqual(projection.months?.count, 2)
        XCTAssertNil(projection.months?.last?.total)
    }

    func testProfitTrendAgainstPreviousMonth() throws {
        let snapshot = try WidgetSnapshot.decode(server)
        XCTAssertEqual(snapshot.profitVersusPrevious, -65)
    }

    func testUnknownVersionAndGarbageAreRejected() {
        XCTAssertThrowsError(try WidgetSnapshot.decode(String(data: server, encoding: .utf8)!.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").data(using: .utf8)!))
        XCTAssertThrowsError(try WidgetSnapshot.decode(Data("{}".utf8)))
    }

    func testStoreRoundTripAndBadPayloadKeepsGoodCopy() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(WidgetSnapshotStore.read(from: directory))
        XCTAssertNotNil(WidgetSnapshotStore.write(server, to: directory))
        XCTAssertEqual(WidgetSnapshotStore.read(from: directory)?.mrr?.value, 528.12)
        XCTAssertNil(WidgetSnapshotStore.write(Data("not json".utf8), to: directory))
        XCTAssertEqual(WidgetSnapshotStore.read(from: directory)?.finance.label, "octobre 2026")
        WidgetSnapshotStore.clear(from: directory)
        XCTAssertNil(WidgetSnapshotStore.read(from: directory))
    }

    func testMoneyIsFrenchCanadianDollars() {
        let whole = WidgetMoney.whole(1248.4).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertEqual(whole, "1 248 $")
        XCTAssertTrue(WidgetMoney.exact(87.02).contains("87,02"))
    }
}
