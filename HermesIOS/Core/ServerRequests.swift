import Foundation

/// In-memory only: request parameters may contain private context. Never cache answers.
struct ServerRequests: Sendable {
    static let supported: Set<String> = ["approval", "clarify", "sudo", "secret", "vault.code", "vault.unlock_prompt"]
    private(set) var frames: [JSONValue] = []
    private var retired = Set<String>()

    @discardableResult mutating func insert(_ frame: JSONValue) -> Bool {
        let id = frame["id"].string
        guard !id.isEmpty, Self.supported.contains(frame["method"].string), !retired.contains(id) else { return false }
        if let index = frames.firstIndex(where: { $0["id"].string == id }) {
            // Reconnect snapshots can add accepted answers to a still-open batch.
            var updated = frame.object
            var params = frame["params"].object
            params["answers"] = .object(frame["params"]["answers"].object.merging(frames[index]["params"]["answers"].object) { _, accepted in accepted })
            updated["params"] = .object(params); frames[index] = .object(updated)
        } else { frames.append(frame) }
        return true
    }

    mutating func retire(_ id: String) {
        guard !id.isEmpty else { return }
        retired.insert(id); frames.removeAll { $0["id"].string == id }
    }

    mutating func retire(session: String) {
        for id in frames.filter({ $0["params"]["session_id"].string == session }).map({ $0["id"].string }) { retire(id) }
    }

    mutating func lock(_ id: String, question: String, answer: String) {
        guard let index = frames.firstIndex(where: { $0["id"].string == id }) else { return }
        var frame = frames[index].object, params = frames[index]["params"].object
        var answers = params["answers"]?.object ?? [:]; answers[question] = .string(answer)
        params["answers"] = .object(answers); frame["params"] = .object(params); frames[index] = .object(frame)
    }

    func payload(session: String, methods: Set<String>) -> JSONValue? {
        guard let frame = frames.first(where: { $0["params"]["session_id"].string == session && methods.contains($0["method"].string) }) else { return nil }
        var params = frame["params"].object
        params["rpc_id"] = frame["id"]; params["rpc_method"] = frame["method"]
        params["event_type"] = .string(frame["method"].string + ".request")
        return .object(params)
    }
}
