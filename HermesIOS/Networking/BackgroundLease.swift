import UIKit

/// Finish a transmission/checkpoint within iOS's finite background allowance.
/// The agent's actual work runs on Hermes, never in a fake background mode.
@MainActor
final class BackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let onExpiration: @MainActor () -> Void

    init(name: String, onExpiration: @escaping @MainActor () -> Void = {}) {
        self.onExpiration = onExpiration
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.onExpiration()
                self.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let previous = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(previous)
    }
}
