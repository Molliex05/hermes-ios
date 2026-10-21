import Foundation

/// Detects a chat list scrolled past its own end: a blank band under the last message while the content is taller than
/// the screen (a keyboard closing or a late row-height estimate can leave it there). A short conversation sits at the
/// top by design and is never a gap.
enum ScrollGap {
    /// - Parameters, all in the scroll view's coordinate space:
    ///   - contentTop: where the content starts (negative once scrolled).
    ///   - endMarker: the bottom of the last row; at the true end it sits `bottomInset` above the viewport's bottom.
    static func isBlank(contentTop: Double, endMarker: Double, viewport: Double,
                        bottomInset: Double = 20, tolerance: Double = 40) -> Bool {
        viewport > 0 && contentTop < -tolerance && endMarker < viewport - bottomInset - tolerance
    }
}
