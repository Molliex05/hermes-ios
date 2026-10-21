import Foundation

extension JSONValue {
    func at(_ path: String) -> JSONValue {
        path.split(separator: ".").reduce(self) { $0[String($1)] }
    }
    static func patch(_ path: String, value: JSONValue) -> JSONValue {
        path.split(separator: ".").reversed().reduce(value) { .object([String($1): $0]) }
    }
    var displayText: String {
        switch self {
        case .string(let value): value
        case .bool(let value): value ? "Oui" : "Non"
        case .number(let value): value == value.rounded() ? String(format: "%.0f", value) : String(value)
        case .null: ""
        default: (try? String(decoding: data(), as: UTF8.self)) ?? ""
        }
    }
}
