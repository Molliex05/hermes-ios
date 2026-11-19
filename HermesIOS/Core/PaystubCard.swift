import Foundation

/// A payslip as Jarvis checked it against the calendar: the week it pays, the hours and amounts that matter, whether it
/// balances, the older weeks it adjusts, and the PDF behind it (fetched by date from the server, never by path).
extension ChatCard {
    enum Verdict: String, Equatable { case balance, gap, check }

    struct PayLine: Equatable, Identifiable {
        let id: Int
        /// « Heures régulières », the paid figure, what the calendar says (may be empty), and whether they differ.
        let label: String, paid: String, calendar: String
        let gap: Bool
    }

    struct Paystub: Equatable {
        /// The pay date, `AAAA-MM-JJ`: names the PDF on the server.
        let payDate: String
        let week: String
        let verdict: Verdict
        let lines: [PayLine]
        let net: String, gross: String
        let adjustments: [String]
        let note: String

        var day: Date? { ChatCard.isoDay(payDate) }
    }

    static func isoDay(_ raw: String) -> Date? {
        guard raw.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return date
    }

    static func parsePaystub(_ json: JSONValue) -> ChatCard? {
        let payDate = firstString(json, "date", "date_paie", "pay_date").trimmingCharacters(in: .whitespaces)
        guard isoDay(payDate) != nil else { return nil }
        let lines = list(firstNonNull(json, "lignes", "lines", "items")).enumerated().compactMap { index, value -> PayLine? in
            let label = clean(firstString(value, "label", "libelle", "libellé", "titre"), 40)
            let paid = clean(display(firstNonNull(value, "valeur", "paye", "payé", "value", "paid")), 24)
            guard !label.isEmpty, !paid.isEmpty else { return nil }
            let gap: Bool = if case .bool(let flag) = firstNonNull(value, "ecart", "écart", "gap") { flag } else { false }
            return PayLine(id: index, label: label, paid: paid, calendar: clean(display(firstNonNull(value, "agenda", "calendar", "prevu", "prévu")), 24), gap: gap)
        }
        let adjustments = list(firstNonNull(json, "ajustements", "adjustments")).map { clean(display($0), 120) }.filter { !$0.isEmpty }
        let raw = firstString(json, "statut", "status", "verdict").lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let verdict: Verdict = switch raw {
        case "balance", "ok", "tout balance", "equilibre": .balance
        case "ecart", "gap", "probleme", "erreur", "a revoir": .gap
        default: lines.contains(where: \.gap) ? .gap : .check
        }
        return .paystub(Paystub(payDate: payDate, week: clean(firstString(json, "semaine", "week", "periode", "période"), 60), verdict: verdict,
                                lines: Array(lines.prefix(8)), net: clean(display(json["net"]), 24), gross: clean(display(json["brut"].isNull ? json["gross"] : json["brut"]), 24),
                                adjustments: Array(adjustments.prefix(4)), note: clean(json["note"].string, 200)))
    }
}

extension ChatCard.Paystub {
    /// Server route that returns this payslip's PDF (base64 in JSON) for the conversation's agent.
    static func path(profile: String, payDate: String) -> String? {
        guard profile.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,63}/) != nil, ChatCard.isoDay(payDate) != nil else { return nil }
        return "/api/plugins/hermes-paie/talon/\(profile)/\(payDate)"
    }

    /// The PDF out of the server's answer; anything that is not a PDF is refused.
    static func pdf(from answer: JSONValue, payDate: String) -> Data? {
        guard answer["date"].string == payDate, let data = Data(base64Encoded: answer["pdf"].string), data.starts(with: Data("%PDF-".utf8)) else { return nil }
        return data
    }
}
