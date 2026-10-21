import Foundation

@MainActor
final class HermesSocket {
    var onRequestsChanged: (() -> Void)?
    private(set) var requests = ServerRequests()
    var onEvent: ((JSONValue) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    /// Every outgoing frame is encoded and written off the main actor, strictly in call order.
    private var sendTail: Task<Error?, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private(set) var epoch: String?
    /// Server→client request methods this backend may send (from `client.capabilities`).
    private(set) var serverRequestMethods: Set<String> = []

    func open(http: HermesHTTP) async throws {
        close()
        requests = ServerRequests()
        let request = try await http.socketRequest()
        let ws = http.socketSession.webSocketTask(with: request)
        ws.maximumMessageSize = 16 * 1024 * 1024
        socket = ws
        ws.resume()
        // Receive and decode off the main actor; only decoded frames hop to the main actor.
        reader = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                while !Task.isCancelled {
                    let frames: [JSONValue]
                    switch try await ws.receive() {
                    case .string(let text): frames = Wire.frames(text)
                    case .data(let data): frames = Wire.frames(data)
                    @unknown default: continue
                    }
                    guard let self, await self.deliver(frames, from: ws) else { return }
                }
            } catch {
                await self?.failed(ws, error: error)
            }
        }
        // `gateway.ready` is the first frame on the socket, so this answer always follows it.
        // Declaring server→client requests once per connection is mandatory: without it Hermes
        // withdraws approvals and never sends clarify/sudo/secret prompts to this client.
        // Resolving an actual RPC also verifies both WebSocket legs, not just HTTP health.
        do {
            let capabilities = try await call("client.capabilities", ["server_requests": true], timeout: 30)
            serverRequestMethods = Set(capabilities["server_requests"].array.map(\.string))
        } catch let error as RPCFailure where error.code == -32601 {
            _ = try await call("ping", timeout: 30)
        }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                    guard let self else { return }
                    // Real gateways can stall for 20–25 seconds under load; a short
                    // heartbeat deadline must not abort healthy in-flight history requests.
                    _ = try await self.call("ping", timeout: 45)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.close(); self.onDisconnect?(error); return
                }
            }
        }
    }

    /// A quick liveness check after a network path change; a half-open socket fails it.
    func probe(timeout: Double = 6) async -> Bool {
        guard socket != nil else { return false }
        do { _ = try await call("ping", timeout: timeout); return true } catch { return false }
    }

    private func deliver(_ frames: [JSONValue], from ws: URLSessionWebSocketTask) -> Bool {
        guard socket === ws else { return false }
        for frame in frames where socket === ws { receive(frame) }
        return socket === ws
    }

    private func failed(_ ws: URLSessionWebSocketTask, error: Error) {
        guard socket === ws else { return }
        close()
        onDisconnect?(error)
    }

    func call(_ method: String, _ params: JSONValue = [:], timeout: Double = 40) async throws -> JSONValue {
        guard socket != nil else { throw RPCFailure("Connexion à Hermes en cours…", code: -1) }
        let id = UUID().uuidString
        let frame: JSONValue = ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.resolve(id, result: .failure(RPCFailure("Hermes met trop de temps à répondre.", code: -2)))
                }
                let sent = enqueue(frame)
                Task { [weak self] in if let error = await sent.value { self?.resolve(id, result: .failure(error)) } }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, result: .failure(CancellationError())) }
        }
    }

    @discardableResult private func enqueue(_ frame: JSONValue) -> Task<Error?, Never> {
        let socket = self.socket, previous = sendTail
        let task = Task.detached(priority: .userInitiated) { () -> Error? in
            _ = await previous?.value
            guard let socket else { return RPCFailure("Hermes est déconnecté.") }
            do { try await socket.send(.string(String(decoding: try frame.data(), as: UTF8.self))); return nil }
            catch { return error }
        }
        sendTail = task
        return task
    }

    private func receive(_ frame: JSONValue) {
        let id = frame["id"].string
        if !id.isEmpty, !frame["method"].string.isEmpty {
            if requests.insert(frame) { onRequestsChanged?() }
            else if !ServerRequests.supported.contains(frame["method"].string) {
                // An unsupported question fails fast instead of stalling the agent for its deadline.
                enqueue(["jsonrpc": "2.0", "id": frame["id"], "error": ["code": -32601, "message": "This client does not support this interactive request."]])
            }
        } else if !id.isEmpty {
            if !frame["error"].isNull {
                resolve(id, result: .failure(RPCFailure(responseError: frame["error"])))
            } else {
                for request in frame["result"]["open_requests"].array {
                    if requests.insert(request) { onRequestsChanged?() }
                }
                resolve(id, result: .success(frame["result"]))
            }
        } else if frame["method"].string == "event" {
            let event = frame["params"]
            switch event["type"].string {
            case "gateway.ready": epoch = event["payload"]["replay_epoch"].string
            case "request.cancel": requests.retire(event["payload"]["id"].string); onRequestsChanged?()
            case "message.complete": requests.retire(session: event["session_id"].string); onRequestsChanged?()
            default: break
            }
            onEvent?(event)
        }
    }

    func answerRequest(_ id: String, result: JSONValue) async throws {
        guard requests.frames.contains(where: { $0["id"].string == id }) else { throw RPCFailure("Cette demande a expiré.") }
        do {
            let response = try await call("request.answer", ["id": .string(id), "result": result])
            guard response["status"].string == "ok" else {
                requests.retire(id); onRequestsChanged?(); throw RPCFailure("Cette demande a expiré.")
            }
        } catch let error as RPCFailure where error.code == -32601 {
            // Early bidirectional gateways only accept a standard JSON-RPC response.
            try await sendFrame(["jsonrpc": "2.0", "id": .string(id), "result": result])
        }
        requests.retire(id); onRequestsChanged?()
    }

    func lockAnswer(_ id: String, question: String, answer: String) async throws {
        let response = try await call("clarify.lock", ["request_id": .string(id), "question_id": .string(question), "answer": .string(answer)])
        guard response["status"].string == "ok" else {
            requests.retire(id); onRequestsChanged?(); throw RPCFailure("Cette question a expiré.")
        }
        let remaining = response["remaining"]
        if remaining.isNull || remaining == .array([]) || remaining == .number(0) { requests.retire(id) }
        else { requests.lock(id, question: question, answer: answer) }
        onRequestsChanged?()
    }

    private func sendFrame(_ frame: JSONValue) async throws {
        guard socket != nil else { throw RPCFailure("Hermes est déconnecté.") }
        if let error = await enqueue(frame).value { throw error }
    }

    private func resolve(_ id: String, result: Result<JSONValue, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    func close() {
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        sendTail = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        for id in Array(pending.keys) { resolve(id, result: .failure(RPCFailure("La connexion a été interrompue.", code: -1))) }
    }
}
