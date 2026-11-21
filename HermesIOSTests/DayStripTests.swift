import XCTest
@testable import HermesIOSCore

final class DayStripTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto")!
        return calendar
    }
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testTheStripRunsFromSixToEleven() {
        XCTAssertEqual(DayStrip.position(at(21, 6), on: at(21, 12), calendar: calendar), 0)
        XCTAssertEqual(DayStrip.position(at(21, 23), on: at(21, 12), calendar: calendar), 1)
        XCTAssertEqual(DayStrip.position(at(21, 14, 30), on: at(21, 12), calendar: calendar)!, 0.5, accuracy: 0.001)
        XCTAssertEqual(DayStrip.position(at(21, 3), on: at(21, 12), calendar: calendar), 0, "before 6 h sits at the start")
        XCTAssertNil(DayStrip.position(at(22, 9), on: at(21, 12), calendar: calendar), "another day")
    }

    func testEventsAreClippedToTheDay() {
        let spans = DayStrip.spans([
            .init(start: at(20, 22), end: at(21, 7), tone: "neutral"),        // last night's shift ends at 7 h
            .init(start: at(21, 10, 30), end: nil),                            // an hour by default
            .init(start: at(21, 22), end: at(22, 6)),                          // tonight's shift, cut at 23 h
            .init(start: at(21, 1), end: at(21, 4))], on: at(21, 12), calendar: calendar)
        XCTAssertEqual(spans.count, 3, "an event wholly before 6 h is left out")
        XCTAssertEqual(spans[0].from, 0); XCTAssertEqual(spans[0].to, 1 / 17, accuracy: 0.001)
        XCTAssertEqual(spans[1].from, 4.5 / 17, accuracy: 0.001); XCTAssertEqual(spans[1].to, 5.5 / 17, accuracy: 0.001)
        XCTAssertEqual(spans[2].to, 1)
    }
}
