import Foundation

@MainActor
final class HermesSocket {
    var onEvent: ((JSONValue) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private(set) var epoch: String?

    func open(http: HermesHTTP) async throws {
        close()
        let request = try await http.socketRequest()
        let ws = http.socketSession.webSocketTask(with: request)
        ws.maximumMessageSize = 16 * 1024 * 1024
        socket = ws
        ws.resume()
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await ws.receive()
                    guard let self, self.socket === ws else { return }
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: continue
                    }
                    for frame in try Wire.frames(text) { self.receive(frame) }
                }
            } catch {
                guard let self, self.socket === ws, !Task.isCancelled else { return }
                self.close()
                self.onDisconnect?(error)
            }
        }
        // Resolving an actual RPC verifies both WebSocket legs, not just HTTP health.
        _ = try await call("ping", timeout: 30)
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

    func call(_ method: String, _ params: JSONValue = [:], timeout: Double = 40) async throws -> JSONValue {
        guard let socket else { throw RPCFailure("Connexion à Hermes en cours…", code: -1) }
        let id = UUID().uuidString
        let data = try JSONValue.object(["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]).data()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.resolve(id, result: .failure(RPCFailure("Hermes met trop de temps à répondre.", code: -2)))
                }
                Task { [weak self] in
                    do { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
                    catch { self?.resolve(id, result: .failure(error)) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, result: .failure(CancellationError())) }
        }
    }

    private func receive(_ frame: JSONValue) {
        let id = frame["id"].string
        if !id.isEmpty {
            if !frame["error"].isNull {
                resolve(id, result: .failure(RPCFailure(frame["error"]["message"].string, code: frame["error"]["code"].int)))
            } else { resolve(id, result: .success(frame["result"])) }
        } else if frame["method"].string == "event" {
            let event = frame["params"]
            if event["type"].string == "gateway.ready" { epoch = event["payload"]["replay_epoch"].string }
            onEvent?(event)
        }
    }

    private func resolve(_ id: String, result: Result<JSONValue, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    func close() {
        reader?.cancel(); reader = nil
        heartbeat?.cancel(); heartbeat = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        for id in Array(pending.keys) { resolve(id, result: .failure(RPCFailure("La connexion a été interrompue.", code: -1))) }
    }
}
