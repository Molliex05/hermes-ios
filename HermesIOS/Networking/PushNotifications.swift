import Foundation
import Observation
import UIKit
@preconcurrency import UserNotifications

@MainActor @Observable
final class PushNotifications {
    static let shared = PushNotifications()
    private static let path = "/api/plugins/hermes-ios-push"
    var pendingTarget: NotificationTarget?
    /// Text typed in the notification's « Répondre » field; kept in memory only, bound to the target it answers.
    private var pendingReply: (target: String, text: String)?
    /// Category the server puts on every alert that targets a conversation (see `notification_payload`).
    nonisolated static let replyCategory = "hermes.reply", replyAction = "hermes.reply.text"
    /// Buttons that answer in one touch: what each one says to the agent (nil: just dismiss, nothing is sent).
    nonisolated static let detailsAction = "hermes.reply.details", laterAction = "hermes.reply.later", acknowledgeAction = "hermes.reply.ok"
    nonisolated static let canned: [String: String] = [detailsAction: "Donne-moi plus de détails.", laterAction: "Rappelle-moi ça dans une heure."]
    var statuses: [UUID: String] = [:]
    var busy = Set<UUID>()
    var authorized = false
    var enabled: Set<UUID>
    private var deviceToken: String?
    private var connections: [SavedConnection] = []
    private var syncing = false
    private var resync = false
    private let defaults = UserDefaults.standard
    let installationID: String
    /// Set by AppModel: whether a banner for this notification must stay silent (chat on screen, voice call).
    var suppressesPresentation: (@MainActor (NotificationEnvelope) -> Bool)?

    private init() {
        enabled = Set((UserDefaults.standard.stringArray(forKey: "push.enabled") ?? []).compactMap(UUID.init(uuidString:)))
        installationID = UserDefaults.standard.string(forKey: "push.installation") ?? UUID().uuidString
        UserDefaults.standard.set(installationID, forKey: "push.installation")
        if let data = UserDefaults.standard.data(forKey: "push.target") {
            pendingTarget = try? JSONDecoder().decode(NotificationTarget.self, from: data)
        }
    }

    /// The « Répondre » action opens the app on the conversation and sends what was typed (`.foreground`: the whole
    /// app and its connection are alive, unlike a background launch).
    private func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Répondre", options: [.foreground],
                                                  textInputButtonTitle: "Envoyer", textInputPlaceholder: "Votre réponse")
        // The one-touch answers open the app too: the conversation must be alive to receive them. « Compris » only clears the alert.
        let details = UNNotificationAction(identifier: Self.detailsAction, title: "Détailler", options: [.foreground])
        let later = UNNotificationAction(identifier: Self.laterAction, title: "Plus tard", options: [.foreground])
        let acknowledge = UNNotificationAction(identifier: Self.acknowledgeAction, title: "Compris", options: [])
        let category = UNNotificationCategory(identifier: Self.replyCategory, actions: [reply, details, later, acknowledge], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func configure(_ saved: [SavedConnection]) async {
        registerCategories()
        connections = saved
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorized = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        if !authorized {
            for id in enabled { statuses[id] = "Autorisez les notifications dans les réglages de l’iPhone." }
        }
        if authorized && !enabled.isEmpty { UIApplication.shared.registerForRemoteNotifications() }
        // Registering rotates the encryption key and costs one request per connection: only when something changed,
        // or after a long while (so a server that lost the registration gets it back).
        let signature = "\(deviceToken ?? "")|\(authorized)|\(enabled.map(\.uuidString).sorted())|\(saved.map { $0.id.uuidString }.sorted())"
        if signature == lastSyncSignature, Date.now.timeIntervalSince(lastSyncAt) < 6 * 3600 { return }
        if deviceToken != nil { await synchronize(); lastSyncSignature = signature; lastSyncAt = .now }
    }
    private var lastSyncSignature = ""
    private var lastSyncAt = Date.distantPast

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

    func open(_ target: NotificationTarget, reply: String? = nil) {
        pendingTarget = target
        let text = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pendingReply = text.isEmpty ? nil : (target.id, String(text.prefix(4_000)))
        defaults.set(try? JSONEncoder().encode(target), forKey: "push.target")
    }

    /// The reply typed on this notification, handed over once.
    func takeReply(for target: NotificationTarget) -> String? {
        guard let pending = pendingReply, pending.target == target.id else { return nil }
        pendingReply = nil
        return pending.text
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
                NotificationKeyStore.remove(for: connection.id)
                await synchronize() // A registration already in flight must observe the new preference.
            }
        } catch {
            statuses[connection.id] = (error as? RPCFailure)?.code == 404
                ? "Installez l’extension Hermès iOS Push sur ce serveur."
                : error.localizedDescription
        }
    }

    /// Removes the delivered banners of one conversation thread (the same hash the server sends as `thread-id`).
    func clearDelivered(connection: UUID, profile: String, session: String) {
        let thread = NotificationEnvelope.threadID(connection: connection, profile: profile, session: session)
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications().filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
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
                        var body: [String: JSONValue] = [
                            "installation_id": .string(installationID), "connection_id": .string(connection.id.uuidString),
                            "token": .string(deviceToken), "environment": .string(environment)
                        ]
                        // A fresh key at every registration; sent only over a channel that protects it.
                        let secure = NotificationKeyTransport.allowsKey(over: connection.endpoint.baseURL)
                        let key = secure ? NotificationKeyStore.generateKey() : nil
                        if let key { body["key"] = .string(key.base64EncodedString()) }
                        let result = try await http.request(Self.path + "/devices", method: "PUT", body: .object(body))
                        guard result["registered"].bool else { throw RPCFailure("Le serveur n’a pas confirmé l’inscription aux notifications.") }
                        // The server now holds the new key: keep the same one on this side. If the keychain
                        // refuses it, the next registration rotates again and pushes stay generic until then.
                        let stored = key.map { NotificationKeyStore.store($0, for: connection.id) } ?? false
                        if !stored { NotificationKeyStore.remove(for: connection.id) }
                        if enabled.contains(connection.id) {
                            statuses[connection.id] = !secure
                                ? "Activées · aperçu chiffré indisponible : cette adresse n’est pas sécurisée (HTTPS ou Tailscale requis)."
                                : stored ? "Activées · réponses et messages programmés" : "Activées · aperçu chiffré indisponible sur cet iPhone."
                        } else { resync = true }
                    } else {
                        _ = try await http.request(Self.path + "/devices/" + installationID + "/" + connection.id.uuidString, method: "DELETE")
                        NotificationKeyStore.remove(for: connection.id)
                    }
                } catch {
                    if enabled.contains(connection.id) { statuses[connection.id] = "Enregistrement à reprendre : " + error.localizedDescription }
                }
            }
        } while resync
    }

    static var apnsEnvironment: String {
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

    /// The server's hourly silent push: refresh the widgets' figures, no UI and no alert.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard (userInfo["hermes"] as? [String: Any])?["kind"] as? String == "widgets" else { return .noData }
        return await WidgetRefresh.runInBackground() ? .newData : .failed
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.receiveToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.registrationFailed()
    }

    /// Completion-handler form on purpose: the system finishes it with UIKit state-restoration work that asserts the main
    /// thread. An async override ran off the main thread and crashed the app on every tap, so the handler is called
    /// from the main actor.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let payload = try? JSONSerialization.data(withJSONObject: response.notification.request.content.userInfo)
        // « Répondre » carries the typed text, « Détailler » and « Plus tard » a ready sentence; a plain tap just opens the
        // conversation, and « Compris » does nothing more than clear the alert.
        let action = response.actionIdentifier
        let reply = action == PushNotifications.replyAction ? (response as? UNTextInputNotificationResponse)?.userText : PushNotifications.canned[action]
        let done = CompletionBox(completionHandler)
        if action == PushNotifications.acknowledgeAction { Task { @MainActor in done.call() }; return }
        Task { @MainActor in
            if let payload, let json = try? JSONValue.decode(payload), let target = NotificationTarget(json) {
                PushNotifications.shared.open(target, reply: reply)
            }
            done.call()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let envelope = (try? JSONSerialization.data(withJSONObject: notification.request.content.userInfo))
            .flatMap { try? JSONValue.decode($0) }.flatMap { NotificationEnvelope($0) }
        // An agent's deliberate ios_notify (kind tool) always shows; automatic turn alerts are
        // silenced when the conversation is on screen or a voice call is running.
        let silent = await MainActor.run { envelope.map { $0.kind != .tool && (PushNotifications.shared.suppressesPresentation?($0) ?? false) } ?? false }
        return silent ? [] : [.banner, .sound, .list]
    }
}

/// Hands a system completion handler to the main actor (it is not `Sendable`, but is called exactly once).
private final class CompletionBox: @unchecked Sendable {
    private var handler: (() -> Void)?
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler?(); handler = nil }
}
