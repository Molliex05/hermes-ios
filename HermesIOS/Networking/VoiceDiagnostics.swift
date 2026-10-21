import Foundation

/// Debug-only traces for hands-on voice work (levels and states, never audio or text). Compiled out of Release.
enum VoiceDiag {
    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        NSLog("HVDBG %@", message())
        #endif
    }
}
