import CryptoKit
import Foundation

/// The clear-text `hermes` object of a push (v0.1 and v0.2). Only identifiers; the text is in `enc`.
public struct NotificationEnvelope: Equatable, Sendable {
    public enum Kind: String, Sendable { case turn, tool }
    public let connectionID: UUID
    public let profile: String
    /// Absent for `ios_notify` with `open_conversation=false`.
    public let sessionID: String?
    public let eventID: String
    public let kind: Kind
    public let enc: String?

    public init?(_ payload: JSONValue) {
        let value = payload["hermes"]
        guard value["version"].int == 1,
              let connection = UUID(uuidString: value["connection_id"].string),
              Self.valid(value["profile"].string), Self.valid(value["event_id"].string) else { return nil }
        let session = value["session_id"].string
        guard session.isEmpty || Self.valid(session) else { return nil }
        connectionID = connection; profile = value["profile"].string; eventID = value["event_id"].string
        sessionID = session.isEmpty ? nil : session
        kind = Kind(rawValue: value["kind"].string) ?? .turn // v0.1 pushes carry no kind
        let encoded = value["enc"].string
        enc = encoded.isEmpty ? nil : encoded
    }

    /// Same value as the server's `notification_payload`: SHA-256 hex of "connection:profile[:session]".
    public var threadID: String { Self.threadID(connection: connectionID, profile: profile, session: sessionID) }

    public static func threadID(connection: UUID, profile: String, session: String?) -> String {
        var seed = "\(connection.uuidString):\(profile)"
        if let session, !session.isEmpty { seed += ":" + session }
        return SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 200 && value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }
}

/// The key is sent to a server only over a channel an eavesdropper on the path cannot read.
public enum NotificationKeyTransport {
    public static func allowsKey(over url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let raw = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".ts.net") { return true }
        if host.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1]!)
    }
}
