import Foundation

/// The compact, read-only picture of Noriven's figures served by the `hermes-widgets` server plugin.
/// Shared by the app (which downloads it) and the widgets (which only read the saved copy).
/// Amounts are CAD; nothing here is a credential.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Month: Codable, Equatable, Sendable {
        public var month: String
        public var estimatedRevenue: Double
        public var confirmedRevenue: Double
        public var expenses: Double
        public var estimatedProfit: Double
    }
    public struct Finance: Codable, Equatable, Sendable {
        public var month: String
        public var label: String
        public var current: Month
        public var previous: Month
        public var months: [Month]
    }
    public struct MRR: Codable, Equatable, Sendable {
        public var value: Double
        public var activeSubscriptions: Int
        public var trialingSubscriptions: Int
        public var month: String
        public var snapshotDate: String
    }
    /// The Finance projection (net, CAD); absent until Noriven's `analytics_get_finance_projection` is deployed.
    public struct Projection: Codable, Equatable, Sendable {
        public struct Point: Codable, Equatable, Sendable {
            public var month: String
            public var total: Double?
        }
        public var monthTotal: Double?
        public var nextMonthTotal: Double?
        public var twelveMonthTotal: Double?
        public var months: [Point]?
    }

    public var version: Int
    public var currency: String
    public var dataEnvironment: String
    public var asOf: String
    public var generatedAt: String?
    public var stale: Bool?
    public var finance: Finance
    public var mrr: MRR?
    public var projection: Projection?

    public static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(WidgetSnapshot.self, from: data)
        guard value.version == 1 else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported snapshot version")) }
        return value
    }

    public var generatedDate: Date? {
        guard let generatedAt else { return nil }
        return ISO8601DateFormatter().date(from: generatedAt)
    }

    /// Monthly profit change against the previous full month, as a signed percentage; nil when it means nothing.
    public var profitVersusPrevious: Int? {
        let before = finance.previous.estimatedProfit
        guard before != 0 else { return nil }
        return Int(((finance.current.estimatedProfit - before) / abs(before) * 100).rounded())
    }
}

public enum WidgetMoney {
    /// « 1 248 $ » (CAD, fr-CA). Whole dollars keep small widgets readable.
    public static func whole(_ value: Double) -> String {
        value.formatted(.currency(code: "CAD").locale(Locale(identifier: "fr_CA")).precision(.fractionLength(0)))
    }
    public static func exact(_ value: Double) -> String {
        value.formatted(.currency(code: "CAD").locale(Locale(identifier: "fr_CA")).precision(.fractionLength(2)))
    }
}
