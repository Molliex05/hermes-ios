import Foundation

/// A notification only selects a saved connection and native stored session.
/// It never supplies a server URL, credentials, commands or a prompt to send.
public struct NotificationTarget: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let connectionID: UUID
    public let profile: String
    public let sessionID: String

    public init?(_ payload: JSONValue) {
        let value = payload["hermes"]
        guard value["version"].int == 1,
              let connection = UUID(uuidString: value["connection_id"].string),
              Self.valid(value["profile"].string), Self.valid(value["session_id"].string),
              Self.valid(value["event_id"].string) else { return nil }
        id = value["event_id"].string; connectionID = connection
        profile = value["profile"].string; sessionID = value["session_id"].string
    }

    private static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}
