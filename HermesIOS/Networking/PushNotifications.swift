import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor @Observable
final class PushNotifications {
    static let shared = PushNotifications()
    private static let path = "/api/plugins/hermes-ios-push"
    var pendingTarget: NotificationTarget?
    var statuses: [UUID: String] = [:]
    var busy = Set<UUID>()
    var authorized = false
    var enabled: Set<UUID>
    private var deviceToken: String?
    private var connections: [SavedConnection] = []
    private var syncing = false
    private var resync = false
    private let defaults = UserDefaults.standard
    private let installationID: String

    private init() {
        enabled = Set((UserDefaults.standard.stringArray(forKey: "push.enabled") ?? []).compactMap(UUID.init(uuidString:)))
        installationID = UserDefaults.standard.string(forKey: "push.installation") ?? UUID().uuidString
        UserDefaults.standard.set(installationID, forKey: "push.installation")
        if let data = UserDefaults.standard.data(forKey: "push.target") {
            pendingTarget = try? JSONDecoder().decode(NotificationTarget.self, from: data)
        }
    }

    func configure(_ saved: [SavedConnection]) async {
        connections = saved
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorized = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        if !authorized {
            for id in enabled { statuses[id] = "Autorisez les notifications dans les réglages de l’iPhone." }
        }
        if authorized && !enabled.isEmpty { UIApplication.shared.registerForRemoteNotifications() }
        if deviceToken != nil { await synchronize() }
    }

    #if DEBUG
    func authorizeFixtureIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("--notification-fixture-permission"),
              connections.first?.endpoint.baseURL.host == "127.0.0.1" else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    #endif

    func receiveToken(_ data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        Task { await synchronize() }
    }

    func registrationFailed() {
        for id in enabled { statuses[id] = "L’enregistrement auprès d’Apple a échoué. Réessayez." }
    }

    func open(_ target: NotificationTarget) {
        pendingTarget = target
        defaults.set(try? JSONEncoder().encode(target), forKey: "push.target")
    }

    func opened(_ target: NotificationTarget) {
        guard pendingTarget == target else { return }
        pendingTarget = nil; defaults.removeObject(forKey: "push.target")
    }

    func setEnabled(_ value: Bool, for connection: SavedConnection) async {
        guard !busy.contains(connection.id) else { return }
        busy.insert(connection.id)
        defer { busy.remove(connection.id) }
        let http = HermesHTTP(connection)
        defer { http.invalidate() }
        do {
            if value {
                let status = try await http.request(Self.path + "/status")
                guard status["ready"].bool else { throw RPCFailure("Les notifications Apple restent à configurer sur ce serveur Hermes.") }
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                authorized = granted
                guard granted else { throw RPCFailure("Autorisez les notifications dans les réglages de l’iPhone.") }
                enabled.insert(connection.id); save()
                statuses[connection.id] = "Connexion aux notifications Apple…"
                UIApplication.shared.registerForRemoteNotifications()
                if deviceToken != nil { await synchronize() }
            } else {
                // Revoke on the server first: a local switch alone cannot stop APNs.
                _ = try await http.request(Self.path + "/devices/" + installationID + "/" + connection.id.uuidString, method: "DELETE")
                enabled.remove(connection.id); save(); statuses[connection.id] = "Désactivées"
                await synchronize() // A registration already in flight must observe the new preference.
            }
        } catch {
            statuses[connection.id] = (error as? RPCFailure)?.code == 404
                ? "Installez l’extension Hermès iOS Push sur ce serveur."
                : error.localizedDescription
        }
    }

    private func save() { defaults.set(enabled.map(\.uuidString), forKey: "push.enabled") }

    private func synchronize() async {
        guard !syncing else { resync = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            resync = false
            guard let deviceToken else { return }
            for connection in connections {
                let http = HermesHTTP(connection)
                defer { http.invalidate() }
                do {
                    if enabled.contains(connection.id) && authorized {
                        #if targetEnvironment(simulator)
                        let environment = "sandbox"
                        #else
                        // Development signing still uses the APNs sandbox in Release builds.
                        let environment = Self.apnsEnvironment
                        #endif
                        let result = try await http.request(Self.path + "/devices", method: "PUT", body: [
                            "installation_id": .string(installationID), "connection_id": .string(connection.id.uuidString),
                            "token": .string(deviceToken), "environment": .string(environment)
                        ])
                        guard result["registered"].bool else { throw RPCFailure("Le serveur n’a pas confirmé l’inscription aux notifications.") }
                        if enabled.contains(connection.id) { statuses[connection.id] = "Activées · réponses et messages programmés" }
                        else { resync = true }
                    } else {
                        _ = try await http.request(Self.path + "/devices/" + installationID + "/" + connection.id.uuidString, method: "DELETE")
                    }
                } catch {
                    if enabled.contains(connection.id) { statuses[connection.id] = "Enregistrement à reprendre : " + error.localizedDescription }
                }
            }
        } while resync
    }

    private static var apnsEnvironment: String {
        // Read our signed provisioning profile, not the Debug/Release configuration:
        // a Release app installed from Xcode still uses the development APNs service.
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8)),
           let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any],
           let environment = entitlements["aps-environment"] as? String {
            return environment == "production" ? "production" : "sandbox"
        }
        return "production" // App Store apps have no embedded development profile.
    }
}

final class NotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.receiveToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.registrationFailed()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let data = try? JSONSerialization.data(withJSONObject: response.notification.request.content.userInfo),
           let json = try? JSONValue.decode(data), let target = NotificationTarget(json) {
            Task { @MainActor in PushNotifications.shared.open(target) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
