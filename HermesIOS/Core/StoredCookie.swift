import Foundation

struct StoredCookie: Codable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var expires: Date?
    init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain
        path = cookie.path; secure = cookie.isSecure; expires = cookie.expiresDate
    }
    var cookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        // Foundation treats the presence of .secure as true, including the string "FALSE".
        // Omitting it is essential for a saved HTTP-over-Tailscale session to survive relaunch.
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}
