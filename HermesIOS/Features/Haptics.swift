import UIKit

/// Small, quiet feedback: a tap when a message leaves, a soft one when the answer is complete.
@MainActor
enum Haptics {
    static func send() { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7) }
    static func done() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6) }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
}
