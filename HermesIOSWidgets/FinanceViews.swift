import SwiftUI
import Charts

/// The Noriven finance cards, in plain SwiftUI (no WidgetKit/UIKit) so they can also be rendered to images on a Mac.
enum FinanceLayout { case small, medium, large }

enum FinancePalette {
    static let accent = Color(red: 0.81, green: 0.29, blue: 0.19)
    static let positive = Color(red: 0.24, green: 0.55, blue: 0.36)
    static let expense = Color(red: 0.55, green: 0.57, blue: 0.62)
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.075, green: 0.08, blue: 0.08) : Color(red: 0.973, green: 0.965, blue: 0.947)
    }
}

enum FinanceFormat {
    private static func formatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "fr_CA"); formatter.dateFormat = pattern; return formatter
    }
    private static let months = ["janv", "févr", "mars", "avr", "mai", "juin", "juil", "août", "sept", "oct", "nov", "déc"]
    static func shortMonth(_ id: String) -> String {
        guard id.count >= 7, let number = Int(id.dropFirst(5).prefix(2)), (1...12).contains(number) else { return id }
        return months[number - 1]
    }
    static func axis(_ value: Double) -> String { Int(value).formatted(.number.locale(Locale(identifier: "fr_CA"))) }
    static func initial(_ id: String) -> String { String(shortMonth(id).prefix(1)).uppercased() }
    static func shortDay(_ iso: String) -> String {
        guard let date = formatter("yyyy-MM-dd").date(from: String(iso.prefix(10))) else { return iso }
        return formatter("d MMM").string(from: date).replacingOccurrences(of: ".", with: "")
    }
}

struct FinanceCard: View {
    let snapshot: WidgetSnapshot
    let layout: FinanceLayout

    var body: some View {
        switch layout {
        case .small: SmallFinance(snapshot: snapshot)
        case .medium: MediumFinance(snapshot: snapshot)
        case .large: LargeFinance(snapshot: snapshot)
        }
    }
}

private func profitColor(_ value: Double) -> Color { value >= 0 ? FinancePalette.positive : FinancePalette.accent }

private struct Header: View {
    let title: String
    let trailing: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(FinancePalette.accent).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.bold))
            Spacer(minLength: 4)
            Text(trailing).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct ProfitPill: View {
    let value: Double
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: value >= 0 ? "arrow.up.right" : "arrow.down.right").font(.system(size: 9, weight: .bold))
            Text("Profit").font(.caption2.weight(.medium))
            Text(WidgetMoney.whole(value)).font(.caption.weight(.bold)).privacySensitive()
        }
        .foregroundStyle(profitColor(value))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(profitColor(value).opacity(0.14), in: Capsule())
    }
}

/// The last months of estimated revenue as a soft area; the current month is the highlighted end point.
private struct Sparkline: View {
    let months: [WidgetSnapshot.Month]
    var body: some View {
        let peak = max(months.map(\.estimatedRevenue).max() ?? 1, 1)
        Chart {
            ForEach(Array(months.enumerated()), id: \.offset) { index, month in
                AreaMark(x: .value("Mois", index), y: .value("Revenu", month.estimatedRevenue))
                    .foregroundStyle(LinearGradient(colors: [FinancePalette.accent.opacity(0.30), FinancePalette.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Mois", index), y: .value("Revenu", month.estimatedRevenue))
                    .foregroundStyle(FinancePalette.accent).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round)).interpolationMethod(.monotone)
            }
            if let last = months.indices.last {
                PointMark(x: .value("Mois", last), y: .value("Revenu", months[last].estimatedRevenue))
                    .foregroundStyle(FinancePalette.accent).symbolSize(34)
            }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...(peak * 1.15)).chartXScale(domain: 0...Double(max(months.count - 1, 1)))
        .accessibilityHidden(true)
    }
}

private struct SmallFinance: View {
    let snapshot: WidgetSnapshot
    var body: some View {
        let month = snapshot.finance.current
        VStack(alignment: .leading, spacing: 0) {
            Header(title: "Noriven", trailing: FinanceFormat.shortMonth(snapshot.finance.month))
            Spacer(minLength: 4)
            Text("Revenu estimé").font(.caption2).foregroundStyle(.secondary)
            Text(WidgetMoney.whole(month.estimatedRevenue))
                .font(.system(size: 34, weight: .bold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1).privacySensitive()
            Sparkline(months: snapshot.finance.months).frame(maxHeight: .infinity).padding(.vertical, 5)
            ProfitPill(value: month.estimatedProfit)
        }
    }
}

private struct StatColumn: View {
    let title: String
    let value: String
    var tint: Color = .primary
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.subheadline, design: .rounded).weight(.bold)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
            if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatRow: View {
    let snapshot: WidgetSnapshot
    var body: some View {
        let month = snapshot.finance.current
        HStack(spacing: 0) {
            StatColumn(title: "Dépenses", value: WidgetMoney.whole(month.expenses))
            Divider().frame(height: 26)
            StatColumn(title: "Profit", value: WidgetMoney.whole(month.estimatedProfit), tint: profitColor(month.estimatedProfit)).padding(.leading, 12)
            if let mrr = snapshot.mrr {
                Divider().frame(height: 26)
                StatColumn(title: "MRR", value: WidgetMoney.whole(mrr.value), detail: "\(mrr.activeSubscriptions) abo. · \(FinanceFormat.shortDay(mrr.snapshotDate))").padding(.leading, 12)
            }
        }
    }
}

private struct RevenueBars: View {
    let months: [WidgetSnapshot.Month]
    var showValues = true
    var body: some View {
        let peak = max(months.map(\.estimatedRevenue).max() ?? 1, 1)
        Chart {
            ForEach(Array(months.enumerated()), id: \.offset) { index, month in
                BarMark(x: .value("Mois", FinanceFormat.initial(month.month) + "\u{200B}".repeated(index)), y: .value("Revenu", month.estimatedRevenue), width: .ratio(0.62))
                    .foregroundStyle(index == months.count - 1 ? FinancePalette.accent : FinancePalette.accent.opacity(0.28))
                    .cornerRadius(4)
                    .annotation(position: .top, spacing: 2) {
                        if showValues && (index == months.count - 1 || month.estimatedRevenue == peak) {
                            Text(WidgetMoney.whole(month.estimatedRevenue)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).privacySensitive()
                        }
                    }
            }
        }
        .chartYAxis(.hidden).chartYScale(domain: 0...(peak * 1.3))
        .chartXAxis { AxisMarks { value in AxisValueLabel { if let text = value.as(String.self) { Text(text.replacingOccurrences(of: "\u{200B}", with: "")).font(.system(size: 9)).foregroundStyle(Color.secondary) } } } }
        .accessibilityHidden(true)
    }
}

private extension String { func repeated(_ count: Int) -> String { String(repeating: self, count: count) } }

private struct MediumFinance: View {
    let snapshot: WidgetSnapshot
    var body: some View {
        let month = snapshot.finance.current
        VStack(alignment: .leading, spacing: 8) {
            Header(title: "Noriven · \(snapshot.finance.label)", trailing: "revenus estimés")
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Revenu estimé").font(.caption2).foregroundStyle(.secondary)
                    Text(WidgetMoney.whole(month.estimatedRevenue))
                        .font(.system(size: 38, weight: .bold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1).privacySensitive()
                    Text("Mois dernier : \(WidgetMoney.whole(snapshot.finance.previous.estimatedRevenue))").font(.caption2).foregroundStyle(.secondary).privacySensitive()
                }.frame(maxWidth: .infinity, alignment: .leading)
                RevenueBars(months: snapshot.finance.months).frame(maxWidth: .infinity)
            }
            StatRow(snapshot: snapshot)
        }
    }
}

private struct LargeFinance: View {
    let snapshot: WidgetSnapshot
    var body: some View {
        let month = snapshot.finance.current
        VStack(alignment: .leading, spacing: 12) {
            Header(title: "Noriven · \(snapshot.finance.label)", trailing: "revenus estimés")
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Revenu").font(.caption).foregroundStyle(.secondary)
                    Text(WidgetMoney.whole(month.estimatedRevenue)).font(.system(size: 30, weight: .bold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1).privacySensitive()
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dépenses").font(.caption).foregroundStyle(.secondary)
                    Text(WidgetMoney.whole(month.expenses)).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(FinancePalette.expense).minimumScaleFactor(0.55).lineLimit(1).privacySensitive()
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profit").font(.caption).foregroundStyle(.secondary)
                    Text(WidgetMoney.whole(month.estimatedProfit)).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(profitColor(month.estimatedProfit)).minimumScaleFactor(0.55).lineLimit(1).privacySensitive()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Chart {
                ForEach(Array(snapshot.finance.months.enumerated()), id: \.offset) { _, entry in
                    BarMark(x: .value("Mois", FinanceFormat.shortMonth(entry.month)), y: .value("Montant", entry.estimatedRevenue), width: .ratio(0.8))
                        .position(by: .value("Type", "Revenu")).foregroundStyle(FinancePalette.accent).cornerRadius(3)
                    BarMark(x: .value("Mois", FinanceFormat.shortMonth(entry.month)), y: .value("Montant", entry.expenses), width: .ratio(0.8))
                        .position(by: .value("Type", "Dépenses")).foregroundStyle(FinancePalette.expense.opacity(0.55)).cornerRadius(3)
                }
            }
            .chartForegroundStyleScale(["Revenu": FinancePalette.accent, "Dépenses": FinancePalette.expense.opacity(0.55)])
            .chartLegend(position: .top, alignment: .trailing, spacing: 6)
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18)); AxisValueLabel { if let number = value.as(Double.self) { Text(FinanceFormat.axis(number)).font(.system(size: 9)).foregroundStyle(Color.secondary) } } } }
            .chartXAxis { AxisMarks { value in AxisValueLabel { if let text = value.as(String.self) { Text(text).font(.system(size: 10)).foregroundStyle(Color.secondary) } } } }
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
            HStack(spacing: 10) {
                if let mrr = snapshot.mrr {
                    InfoTile(title: "MRR", value: WidgetMoney.whole(mrr.value), detail: "\(mrr.activeSubscriptions) abonnés · au \(FinanceFormat.shortDay(mrr.snapshotDate))")
                }
                if let projection = snapshot.projection?.monthTotal {
                    InfoTile(title: "Projection du mois", value: WidgetMoney.whole(projection), detail: snapshot.projection?.twelveMonthTotal.map { "12 mois : \(WidgetMoney.whole($0))" })
                } else {
                    InfoTile(title: "Mois dernier", value: WidgetMoney.whole(snapshot.finance.previous.estimatedRevenue), detail: "profit \(WidgetMoney.whole(snapshot.finance.previous.estimatedProfit))")
                }
            }
        }
    }
}

private struct InfoTile: View {
    let title: String
    let value: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).privacySensitive()
            if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).privacySensitive() }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shared by every widget and complication: the app's accent and a background that follows the color scheme.
enum WidgetPalette { static let accent = FinancePalette.accent }

struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { FinancePalette.background(scheme) }
}
