import UserNotifications

/// Decrypts the end-to-end encrypted preview. No networking, no UI, no logging:
/// on any failure the generic fallback content is delivered unchanged.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        fallback = request.content
        contentHandler(Self.decrypted(request.content))
        self.contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let fallback { contentHandler(fallback) }
        contentHandler = nil
    }

    private static func decrypted(_ original: UNNotificationContent) -> UNNotificationContent {
        guard let data = try? JSONSerialization.data(withJSONObject: original.userInfo),
              let payload = try? JSONValue.decode(data), let envelope = NotificationEnvelope(payload),
              let enc = envelope.enc, let key = NotificationKeyStore.key(for: envelope.connectionID),
              let text = NotificationCrypto.decrypt(enc, key: key, eventID: envelope.eventID),
              let content = original.mutableCopy() as? UNMutableNotificationContent else { return original }
        if !text.agent.isEmpty { content.title = text.agent }
        content.subtitle = text.conversation
        if !text.preview.isEmpty { content.body = text.preview }
        return content
    }
}
