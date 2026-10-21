import SwiftUI
import WidgetKit

struct FinanceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var isPlaceholder = false
}

enum FinanceSample {
    static let snapshot: WidgetSnapshot = {
        func month(_ id: String, _ revenue: Double, _ expenses: Double) -> WidgetSnapshot.Month {
            .init(month: id, estimatedRevenue: revenue, confirmedRevenue: 0, expenses: expenses, estimatedProfit: revenue - expenses)
        }
        let months = [month("2026-05", 620, 200), month("2026-06", 650, 180), month("2026-07", 520, 160), month("2026-08", 470, 300), month("2026-09", 275, 30), month("2026-10", 248, 161)]
        return WidgetSnapshot(version: 1, currency: "CAD", dataEnvironment: "production", asOf: "2026-10-20", generatedAt: nil, stale: nil,
                              finance: .init(month: "2026-10", label: "octobre 2026", current: months[5], previous: months[4], months: months),
                              mrr: .init(value: 528, activeSubscriptions: 197, trialingSubscriptions: 25, month: "2026-09", snapshotDate: "2026-09-09"), projection: nil)
    }()
}

struct FinanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> FinanceEntry { FinanceEntry(date: .now, snapshot: FinanceSample.snapshot, isPlaceholder: true) }
    func getSnapshot(in context: Context, completion: @escaping (FinanceEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)) }
        else { completion(FinanceEntry(date: .now, snapshot: WidgetSnapshotStore.read())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FinanceEntry>) -> Void) {
        let entry = FinanceEntry(date: .now, snapshot: WidgetSnapshotStore.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct FinanceWidgetView: View {
    let entry: FinanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot).redacted(reason: entry.isPlaceholder ? .placeholder : [])
        } else {
            empty
        }
    }

    @ViewBuilder private func content(_ snapshot: WidgetSnapshot) -> some View {
        switch family {
        case .systemMedium: FinanceCard(snapshot: snapshot, layout: .medium)
        case .systemLarge: FinanceCard(snapshot: snapshot, layout: .large)
        case .accessoryRectangular: AccessoryRectangularFinance(snapshot: snapshot)
        case .accessoryInline: Text("Noriven · profit \(WidgetMoney.whole(snapshot.finance.current.estimatedProfit))").privacySensitive()
        case .accessoryCircular: AccessoryCircularFinance(snapshot: snapshot)
        default: FinanceCard(snapshot: snapshot, layout: .small)
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.bar.xaxis").font(.title2).foregroundStyle(WidgetPalette.accent)
            Text("Ouvrez Hermès pour charger vos chiffres").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AccessoryRectangularFinance: View {
    let snapshot: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Noriven · \(FinanceFormat.shortMonth(snapshot.finance.month))").font(.caption.weight(.semibold))
            Text("Revenu \(WidgetMoney.whole(snapshot.finance.current.estimatedRevenue))").privacySensitive()
            Text("Profit \(WidgetMoney.whole(snapshot.finance.current.estimatedProfit))").privacySensitive()
        }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AccessoryCircularFinance: View {
    let snapshot: WidgetSnapshot
    var body: some View {
        let profit = snapshot.finance.current.estimatedProfit
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: profit >= 0 ? "arrow.up.right" : "arrow.down.right").font(.caption2.weight(.bold))
                Text(WidgetMoney.whole(profit).replacingOccurrences(of: " $", with: "$")).font(.caption.weight(.bold)).minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
            }
        }
    }
}
