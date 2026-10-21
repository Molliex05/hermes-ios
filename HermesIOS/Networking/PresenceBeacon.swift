import Foundation

/// Tells the push plugin which conversation Maxime is looking at (or talking to), so the server
/// skips the automatic alert for it. Best effort: failures are silent and never block the UI.
@MainActor
final class PresenceBeacon {
    struct Target: Equatable { let connectionID: UUID; let profile: String; let sessionID: String }

    static let interval: Duration = .seconds(45)
    static let ttl = 120
    private static let path = "/api/plugins/hermes-ios-push/presence"

    private let client: () -> HermesHTTP?
    private let installationID: () -> String
    private var target: Target?
    private var loop: Task<Void, Never>?
    /// The server answered 401/403/404: no plugin or no presence route. Quiet until the next connect.
    private var unavailable = false

    init(client: @escaping () -> HermesHTTP?, installationID: @escaping () -> String) {
        self.client = client; self.installationID = installationID
    }

    /// Call when a connection is (re)established so a plugin installed meanwhile is retried.
    func reset() { unavailable = false }

    /// `nil` stops presence. Setting the same target again does nothing.
    func update(_ new: Target?) {
        guard new != target else { return }
        let old = target
        loop?.cancel(); loop = nil
        target = new
        if let old { Task { await send("DELETE", old) } }
        guard let new else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.send("PUT", new)
                do { try await Task.sleep(for: Self.interval) } catch { return }
            }
        }
    }

    private func body(_ t: Target, ttl: Bool) -> JSONValue {
        var fields: [String: JSONValue] = ["installation_id": .string(installationID()), "connection_id": .string(t.connectionID.uuidString),
                                           "profile": .string(t.profile), "session_id": .string(t.sessionID)]
        if ttl { fields["ttl"] = .number(Double(Self.ttl)) }
        return .object(fields)
    }

    private func send(_ method: String, _ t: Target) async {
        guard !unavailable, let http = client() else { return }
        do { _ = try await http.request(Self.path, method: method, body: body(t, ttl: method == "PUT")) }
        catch let failure as RPCFailure where [401, 403, 404].contains(failure.code) { unavailable = true }
        catch {}
    }
}
