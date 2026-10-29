import Foundation

/// Measures how far a chat list sits from its real end, from the scroll view's own numbers (content size, offset, insets).
/// A positive distance means more content below; a clearly negative one means the list was scrolled past its end and
/// shows a blank band (a keyboard closing or a wrong row-height estimate can leave it there). A short conversation that
/// does not fill the screen is never past its end.
enum ScrollGap {
    static func distanceFromEnd(contentHeight: Double, insetTop: Double, insetBottom: Double, contentOffset: Double, container: Double) -> Double {
        let farthest = max(0, contentHeight + insetTop + insetBottom - container)     // the largest offset the content allows
        return farthest - (contentOffset + insetTop)
    }

    static func isPastEnd(_ distance: Double, tolerance: Double = 40) -> Bool { distance < -tolerance }
}
