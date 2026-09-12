import Foundation

struct SavedConnection: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var endpoint: Endpoint
    var mode: String = "basic"
}

/// Do not forward login bodies or cookies to a redirect target.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class HermesHTTP {
    let connection: SavedConnection
    let session: URLSession
    let socketSession: URLSession
    private let redirects = NoRedirects()
    private var token: String?

    init(_ connection: SavedConnection) {
        self.connection = connection
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 60
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c, delegate: redirects, delegateQueue: nil)
        let ws = URLSessionConfiguration.ephemeral
        ws.timeoutIntervalForRequest = 15
        ws.timeoutIntervalForResource = 7 * 24 * 60 * 60
        ws.urlCache = nil
        socketSession = URLSession(configuration: ws, delegate: redirects, delegateQueue: nil)
        if connection.mode == "token", let data = Keychain.read(connection.id.uuidString) { token = String(data: data, encoding: .utf8) }
        else if let data = Keychain.read(connection.id.uuidString), let cookies = try? JSONDecoder().decode([StoredCookie].self, from: data) {
            cookies.compactMap(\.cookie).forEach { session.configuration.httpCookieStorage?.setCookie($0) }
        }
    }

    func request(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        var request = URLRequest(url: connection.endpoint.url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Hermes-Session-Token") }
        if let body {
            request.httpBody = try body.data()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RPCFailure("Réponse Hermes invalide.") }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw RPCFailure(path == "/auth/password-login" ? "Identifiants Hermes incorrects." : "Votre connexion Hermes a expiré. Reconnectez-vous dans les réglages.", code: 401)
        }
        guard (200...299).contains(response.statusCode) else {
            throw RPCFailure(response.statusCode == 429 ? "Trop de tentatives. Réessayez dans un instant." : "Hermes a répondu HTTP \(response.statusCode). Vérifiez l’adresse du serveur et son état.", code: response.statusCode)
        }
        try persistCookies()
        return data.isEmpty ? .object([:]) : try JSONValue.decode(data)
    }

    func signIn(username: String, password: String) async throws {
        _ = try await request("/auth/password-login", method: "POST", body: ["provider": "basic", "username": .string(username), "password": .string(password)])
    }

    func useToken(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCFailure("Entrez le jeton de session Hermes.") }
        token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.save(Data(token!.utf8), key: connection.id.uuidString)
    }

    func socketRequest() async throws -> URLRequest {
        let url: URL
        if let token { url = connection.endpoint.socket(token: token) }
        else {
            let response = try await request("/api/auth/ws-ticket", method: "POST", body: [:])
            guard !response["ticket"].string.isEmpty else { throw RPCFailure("Hermes n’a pas fourni de ticket WebSocket.") }
            url = connection.endpoint.socket(ticket: response["ticket"].string)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        return request
    }

    private func persistCookies() throws {
        guard connection.mode != "token" else { return }
        let cookies = (session.configuration.httpCookieStorage?.cookies ?? []).map(StoredCookie.init)
        if !cookies.isEmpty { try Keychain.save(JSONEncoder().encode(cookies), key: connection.id.uuidString) }
    }

    func invalidate() { session.invalidateAndCancel(); socketSession.invalidateAndCancel() }
}
