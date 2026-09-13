import Foundation

/// Share concurrent read-only refreshes for the same socket/profile. A dismissed
/// sheet does not cancel a refresh also needed by the connection coordinator.
@MainActor
final class HistoryRequests {
    private var pending: [String: Task<JSONValue, Error>] = [:]

    func load(scope: String, fetch: @escaping @MainActor () async throws -> JSONValue) async throws -> JSONValue {
        if let request = pending[scope] { return try await request.value }
        let request = Task { try await fetch() }
        pending[scope] = request
        defer { pending[scope] = nil }
        return try await request.value
    }
}
