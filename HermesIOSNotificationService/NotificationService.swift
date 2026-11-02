@preconcurrency import Intents
@preconcurrency import UserNotifications

/// Decrypts the end-to-end encrypted preview. No networking, no UI, no logging:
/// on any failure the generic fallback content is delivered unchanged.
/// A decrypted alert is shown as a message from its agent: the agent's picture (drawn by the app, `NotificationAvatar`)
/// with the app's icon in its corner, so Jarvis and Hermès are told apart at a glance.
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: Delivery?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let delivery = Delivery(contentHandler)
        self.delivery = delivery
        fallback = request.content
        let (content, sender) = Self.decrypted(request.content)
        fallback = content                                  // a slow donation must not cost the decrypted preview
        guard let sender else { return delivery.send(content) }
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: nil, conversationIdentifier: content.threadIdentifier.isEmpty ? nil : content.threadIdentifier,
                                         serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { _ in
            // Without the capability or the picture the alert stays as it was, decrypted.
            delivery.send((try? content.updating(from: intent)) ?? content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback { delivery?.send(fallback) }
    }

    private static func decrypted(_ original: UNNotificationContent) -> (UNNotificationContent, INPerson?) {
        guard let data = try? JSONSerialization.data(withJSONObject: original.userInfo),
              let payload = try? JSONValue.decode(data), let envelope = NotificationEnvelope(payload),
              let enc = envelope.enc, let key = NotificationKeyStore.key(for: envelope.connectionID),
              let text = NotificationCrypto.decrypt(enc, key: key, eventID: envelope.eventID),
              let content = original.mutableCopy() as? UNMutableNotificationContent else { return (original, nil) }
        if !text.agent.isEmpty { content.title = text.agent }
        content.subtitle = text.conversation
        if !text.preview.isEmpty { content.body = text.preview }
        guard !text.agent.isEmpty, let picture = NotificationAvatar.image(for: envelope.profile) else { return (content, nil) }
        let id = "hermes:\(envelope.connectionID.uuidString):\(envelope.profile)"
        let sender = INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: nil, displayName: text.agent,
                              image: INImage(imageData: picture), contactIdentifier: nil, customIdentifier: id)
        return (content, sender)
    }
}

/// Hands the content to the system exactly once, from whichever thread finishes first (the donation or the timeout).
private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    init(_ handler: @escaping (UNNotificationContent) -> Void) { self.handler = handler }
    func send(_ content: UNNotificationContent) {
        lock.lock(); let current = handler; handler = nil; lock.unlock()
        current?(content)
    }
}
