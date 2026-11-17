import CoreLocation
import Foundation

/// Roughly where the car is, for spoken turns at the wheel: the town, from one coarse fix. Only asked for during a call
/// that goes out through the car, never stored on disk and never sent outside such a call. Permission is « while using
/// the app », asked the first time a driving call starts with the app in front; refused, slow or unavailable (a call
/// started from Siri with the iPhone locked), the turn simply goes without it.
@MainActor final class DrivingLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = DrivingLocation()

    /// The last town found, kept 15 minutes: a car moves, but a town does not change every turn.
    private(set) var town: String?
    private var foundAt = Date.distantPast
    private var refreshing = false
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// The town if it is fresh, without waiting: a spoken turn never waits on the GPS.
    var current: String? { Date().timeIntervalSince(foundAt) < 15 * 60 ? town : nil }

    /// Looks for the town in the background (at most one search at a time, at most every two minutes).
    func refresh() {
        guard !refreshing, Date().timeIntervalSince(foundAt) > 120 else { return }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: refreshing = true; manager.requestLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { refresh() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { refreshing = false; return }
        Task { await name(location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        refreshing = false
    }

    private func name(_ location: CLLocation) async {
        defer { refreshing = false }
        let placemark = try? await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "fr_CA")).first
        guard let found = placemark?.locality ?? placemark?.subAdministrativeArea, !found.isEmpty else { return }
        town = found; foundAt = Date()
    }
}
