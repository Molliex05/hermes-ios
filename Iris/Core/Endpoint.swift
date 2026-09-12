import Foundation

public struct Endpoint: Codable, Equatable, Sendable {
    public let baseURL: URL

    public init(_ input: String) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: raw), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil else {
            throw RPCFailure("Entrez une adresse complète, par exemple https://hermes.votre-tailnet.ts.net.")
        }
        c.scheme = c.scheme?.lowercased()
        if c.scheme == "http", !Self.isPrivateHost(host) {
            throw RPCFailure("Utilisez HTTPS pour une adresse publique, ou l’adresse privée Tailscale de votre agent.")
        }
        c.path = c.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        guard let url = c.url else { throw RPCFailure("Adresse invalide.") }
        baseURL = url
    }

    public func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path += path.hasPrefix("/") ? path : "/" + path
        c.queryItems = query.isEmpty ? nil : query
        return c.url!
    }

    public func socket(ticket: String? = nil, token: String? = nil) -> URL {
        var c = URLComponents(url: url("/api/ws"), resolvingAgainstBaseURL: false)!
        c.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        if let ticket { c.queryItems = [.init(name: "ticket", value: ticket)] }
        else if let token { c.queryItems = [.init(name: "token", value: token)] }
        return c.url!
    }

    public static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" || h.hasSuffix(".ts.net") || h.hasSuffix(".local") { return true }
        if !h.contains(".") && !h.contains(":") && h.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil { return true }
        if h.hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 100 && (64...127).contains(parts[1]))
    }
}
