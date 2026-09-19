import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(_ key: String) -> JSONValue { object[key] ?? .null }
    public var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
    public var array: [JSONValue] { if case .array(let v) = self { v } else { [] } }
    public var string: String { if case .string(let v) = self { v } else { "" } }
    public var bool: Bool { if case .bool(let v) = self { v } else { false } }
    public var double: Double { if case .number(let v) = self { v } else { 0 } }
    public var int: Int { Int(double) }
    public var isNull: Bool { self == .null }
    public static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
    public func data() throws -> Data { try JSONEncoder().encode(self) }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

public struct RPCFailure: Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public let reason: String?
    public init(_ message: String, code: Int = 0, reason: String? = nil) { self.message = message; self.code = code; self.reason = reason }
    public init(responseError: JSONValue) {
        self.init(responseError["message"].string, code: responseError["code"].int,
                  reason: responseError["data"]["reason"].isNull ? nil : responseError["data"]["reason"].string)
    }
    public var sessionOwnedElsewhere: Bool {
        if let reason { return reason == "SESSION_NOT_OWNED" }
        return code == 4090 && message.contains("already has a live owner")
    }
    /// Only documented refusals before admission prove that a prompt was not sent.
    /// Internal/server and transport errors can arrive after the turn has started.
    public var rejectsPromptBeforeAdmission: Bool {
        (4000...4999).contains(code) || [401, 403, 5070, 5071, 5072, -32601, -32602].contains(code)
    }
    public var retryableSessionResume: Bool { code == 4007 || code == 4009 }
    public static let ownershipMessage = "Ce fil est encore ouvert dans une autre interface Hermes. Votre message n’a pas été envoyé et votre brouillon est conservé. Fermez ce fil dans l’interface qui le détient, puis réessayez ici. Vous pouvez aussi continuer dans un nouveau fil avec ce brouillon."
    public var errorDescription: String? { message }
}

public enum Wire {
    /// Hermes coalesces several newline-delimited envelopes into one WebSocket message.
    public static func frames(_ text: String) throws -> [JSONValue] {
        try text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try JSONValue.decode(Data($0.utf8)) }
    }
}
