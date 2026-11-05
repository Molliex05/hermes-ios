import XCTest
@testable import HermesIOSCore

final class ScrollGapTests: XCTestCase {
    private func distance(content: Double, offset: Double, container: Double = 800, top: Double = 0, bottom: Double = 0) -> Double {
        ScrollGap.distanceFromEnd(contentHeight: content, insetTop: top, insetBottom: bottom, contentOffset: offset, container: container)
    }

    func testAtTheEndTheDistanceIsZero() {
        XCTAssertEqual(distance(content: 3000, offset: 2200), 0)
        XCTAssertFalse(ScrollGap.isPastEnd(0))
    }

    func testMoreContentBelowIsPositive() {
        XCTAssertEqual(distance(content: 3000, offset: 1000), 1200)
        XCTAssertFalse(ScrollGap.isPastEnd(1200))
    }

    func testScrolledPastTheEndIsNegativeAndDetected() {
        let past = distance(content: 3000, offset: 5200)          // far beyond the end: a blank screen
        XCTAssertEqual(past, -3000)
        XCTAssertTrue(ScrollGap.isPastEnd(past))
        XCTAssertTrue(ScrollGap.isPastEnd(distance(content: 3000, offset: 2300)))
    }

    func testSmallBounceAtTheEndIsTolerated() {
        XCTAssertFalse(ScrollGap.isPastEnd(distance(content: 3000, offset: 2230)))
    }

    func testShortConversationAtTheTopIsNeverPastItsEnd() {
        XCTAssertEqual(distance(content: 300, offset: 0), 0)
        XCTAssertFalse(ScrollGap.isPastEnd(distance(content: 300, offset: 0)))
    }

    func testInsetsAreAccountedFor() {
        // top inset 60: the offset at the very top is -60; the end is reached at content + insets - container - top.
        XCTAssertEqual(distance(content: 3000, offset: -60, top: 60, bottom: 90), 2350)
        XCTAssertEqual(distance(content: 3000, offset: 2290, top: 60, bottom: 90), 0)
    }
}
