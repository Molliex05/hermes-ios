import XCTest
@testable import HermesIOSCore

final class ScrollGapTests: XCTestCase {
    func testAtTheEndIsNotAGap() {
        XCTAssertFalse(ScrollGap.isBlank(contentTop: -1200, endMarker: 780, viewport: 800))
    }

    func testBlankBandUnderLongContentIsAGap() {
        XCTAssertTrue(ScrollGap.isBlank(contentTop: -1200, endMarker: 520, viewport: 800))
    }

    func testShortConversationAlignedToTheTopIsNeverAGap() {
        XCTAssertFalse(ScrollGap.isBlank(contentTop: 14, endMarker: 300, viewport: 800))
    }

    func testSmallBounceAndRoundingAreTolerated() {
        XCTAssertFalse(ScrollGap.isBlank(contentTop: -400, endMarker: 745, viewport: 800))
        XCTAssertFalse(ScrollGap.isBlank(contentTop: -400, endMarker: 760, viewport: 800))
        XCTAssertTrue(ScrollGap.isBlank(contentTop: -400, endMarker: 725, viewport: 800))
    }

    func testUnknownViewportIsIgnored() {
        XCTAssertFalse(ScrollGap.isBlank(contentTop: -400, endMarker: 0, viewport: 0))
    }
}
