import XCTest
@testable import HermesIOSCore

final class RoutineScheduleTests: XCTestCase {
    func testSimpleSchedulesKeepTheirWallClockTime() throws {
        for expression in ["0 8 * * *", "45 23 * * 1-5", "15 0 * * 5", "7 * * * *"] {
            let value = try XCTUnwrap(RoutineSchedule(expression))
            XCTAssertEqual(value.expression, expression)
        }
        XCTAssertEqual(RoutineSchedule("0 8 * * *")?.summary, "Tous les jours à 8 h")
        XCTAssertEqual(RoutineSchedule("30 9 * * 1-5")?.summary, "Du lundi au vendredi à 9 h 30")
        XCTAssertEqual(RoutineSchedule("0 17 * * 5")?.summary, "Le vendredi à 17 h")
        XCTAssertEqual(RoutineSchedule("0 12 * * 7")?.expression, "0 12 * * 0")
    }

    func testComplexAndOneShotSchedulesRemainCustom() {
        for expression in ["every 4h", "in 30m", "2026-10-01T08:00:00-04:00", "*/15 8-17 * * 1-5", "0 8 1 * *", "0 8 * JAN MON", "0 8 * * * 30", "61 8 * * *", "0 24 * * *"] {
            XCTAssertNil(RoutineSchedule(expression), expression)
        }
    }

    func testCanonicalScheduleIsUsedInsteadOfDisplayText() {
        XCTAssertEqual(RoutineSchedule.expression(from: ["schedule": ["kind": "cron", "expr": "0 8 * * *", "display": "every day at 8am"]]), "0 8 * * *")
        XCTAssertEqual(RoutineSchedule.expression(from: ["schedule": ["kind": "interval", "minutes": 240, "display": "every 4h"]]), "every 240m")
        XCTAssertEqual(RoutineSchedule.expression(from: ["schedule": ["kind": "once", "run_at": "2026-10-01T08:00:00-04:00", "display": "once in 30m"]]), "2026-10-01T08:00:00-04:00")
        XCTAssertEqual(RoutineSchedule.expression(from: ["schedule": "in 30m"]), "in 30m")
    }

    func testNextRunUsesServerOffsetAndRejectsUnqualifiedLocalTime() throws {
        let east = try XCTUnwrap(RoutineSchedule.nextRun(from: ["next_run_at": "2026-10-01T08:00:00-04:00"]))
        let utc = try XCTUnwrap(RoutineSchedule.nextRun(from: ["next_run_at": "2026-10-01T12:00:00.000000Z"]))
        XCTAssertEqual(east, utc)
        XCTAssertNil(RoutineSchedule.nextRun(from: ["next_run_at": "2026-10-01T08:00:00"]))
        XCTAssertNil(RoutineSchedule.nextRun(from: [:]))
    }

    func testRunNavigationRequiresNativeStoredSessionIdentity() throws {
        XCTAssertNil(RoutineSchedule.runConversation(["job_id": "daily", "started_at": 42], profile: "research"))
        XCTAssertNil(RoutineSchedule.runConversation(["id": "run", "profile": "other"], profile: "research"))
        let result = try XCTUnwrap(RoutineSchedule.runConversation(["id": "cron_daily_42", "profile": "research", "title": "Briefing"], profile: "research"))
        XCTAssertEqual(result.id, "cron_daily_42")
        XCTAssertEqual(result.profile, "research")
        XCTAssertEqual(result.title, "Briefing")
    }
}
