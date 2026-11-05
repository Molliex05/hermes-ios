import Foundation

/// Each agent's picture (a small PNG drawn by the app from its look), kept where the notification extension can read
/// it: an alert then shows who writes, Jarvis or Hermès, as the sender's picture with the app's icon in its corner.
public enum NotificationAvatar {
    private static func blob(_ profile: String) -> SharedBlob { SharedBlob(account: "agent-avatar." + profile) }

    @discardableResult
    public static func store(_ png: Data, for profile: String) -> Bool {
        NotificationEnvelope.valid(profile) && png.count <= 200_000 && blob(profile).write(png)
    }

    public static func image(for profile: String) -> Data? {
        NotificationEnvelope.valid(profile) ? blob(profile).read() : nil
    }
}
