import SwiftUI
import WidgetKit

/// Hermès's widget: Noriven's desk, not a second day planner. The state first (how many things to fix, to watch), then the
/// lines by urgency with their reason, then the figures the agent publishes (`widget_bloc` metrics) and the one thing to do.
/// No weather: that is Jarvis's. Every size uses the full width; nothing is cut in two halves.
extension BoardWidgetView {
    // MARK: Data

    /// The agent's own lines, by urgency. (The calendar's events are the day's business, not the desk's.)
    var deskRows: [BoardRow] { BoardDesk.ranked(entry.upcomingRows) { $0.item.tone } }
    var desk: BoardDesk { BoardDesk(deskRows.map(\.item)) }
    private var liveBlocks: [WidgetBlock] { entry.blocks.filter { !$0.isExpired(at: entry.date) } }
    var deskMetrics: [WidgetBlock.Metric] { liveBlocks.first { $0.kind == .metrics }?.metrics ?? [] }
    var deskMetricsTitle: String { liveBlocks.first { $0.kind == .metrics }?.title ?? "" }
    /// The agent's note of the day (a `note` block), else its « À retenir ».
    var deskNote: (title: String, text: String)? {
        if let block = liveBlocks.first(where: { $0.kind == .note && !$0.text.isEmpty }) { return (block.title, block.text) }
        return entry.note.isEmpty ? nil : ("À retenir", entry.note)
    }
    private var deskTitle: String {
        let title = entry.live?.title ?? ""
        return title.isEmpty || entry.fromCalendar ? "Noriven" : title
    }

    func levelColor(_ level: BoardDesk.Level) -> Color {
        BoardTone.color(level == .fix ? "negative" : level == .watch ? "warning" : "positive", entry.palette, dark: dark)
    }

    // MARK: Pieces

    /// « 2 » large in the state's colour, « à régler » beside it.
    private func deskHeadline(_ size: Font) -> some View {
        let headline = desk.headline
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(headline.figure).font(size).monospacedDigit().lineLimit(1)
            Text(headline.label).font(.subheadline.weight(.bold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(levelColor(desk.level))
        .accessibilityElement(children: .combine)
    }

    /// The desk's mark and title over the widget, in the agent's colour.
    private func deskHeader(tile: CGFloat) -> some View {
        HStack(spacing: 7) {
            Tile(symbol: "briefcase.fill", color: accent, size: tile)
            Text(deskTitle).font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.75)
        }
    }

    /// A count in its colour: « ● 2 à régler ».
    private func pill(_ count: Int, _ label: String, _ level: BoardDesk.Level) -> some View {
        HStack(spacing: 4) {
            Circle().fill(levelColor(level)).frame(width: 6, height: 6)
            Text("\(count) \(label)").font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(levelColor(level).opacity(0.14), in: Capsule())
    }

    @ViewBuilder private var pills: some View {
        if desk.toFix > 0 || desk.toWatch > 0 {
            HStack(spacing: 5) {
                if desk.toFix > 0 { pill(desk.toFix, "à régler", .fix) }
                if desk.toWatch > 0 { pill(desk.toWatch, "à surveiller", .watch) }
            }
        } else {
            pill(0, "alerte", .fine)
        }
    }

    /// A line of the desk: its urgency as a bar, the title, and the reason under it.
    private func deskRow(_ row: BoardRow, detail: Bool = true) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Capsule().fill(levelColor(BoardDesk.Level(tone: row.item.tone))).frame(width: 3.5).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.item.text).font(.caption.weight(.semibold)).lineLimit(1)
                if detail, !row.item.detail.isEmpty { Text(row.item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The agent's figures side by side: the value in bold, its label under it.
    private func metricsStrip(_ metrics: [WidgetBlock.Metric]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                if index > 0 { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 24).padding(.horizontal, 8) }
                VStack(alignment: .leading, spacing: 0) {
                    Text(metric.value).font(.subheadline.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(metric.tone.isEmpty ? Color.primary : BoardTone.color(metric.tone, entry.palette, dark: dark))
                    Text(metric.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Small

    /// The state in large type, what it adds up to, and the most urgent line.
    var deskSmall: some View {
        VStack(alignment: .leading, spacing: 0) {
            deskHeader(tile: 24)
            Spacer(minLength: 2)
            deskHeadline(.system(.largeTitle, design: .rounded).weight(.bold))
            if !desk.subline.isEmpty { Text(desk.subline).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 4)
            if let top = deskRows.first, desk.level != .fine {
                Text(top.item.text).font(.footnote.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            } else if let metric = deskMetrics.first {
                VStack(alignment: .leading, spacing: 0) {
                    Text(metric.value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(metric.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let note = deskNote {
                Text(note.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Medium

    /// Header and counts across the top, the urgent lines across the width, the figures (else the note) along the bottom.
    var deskMedium: some View {
        let metrics = Array(deskMetrics.prefix(3))
        let count = bigText ? (metrics.isEmpty ? 2 : 1) : (metrics.isEmpty ? 3 : 2)
        let rows = Array(deskRows.prefix(count))
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                deskHeader(tile: 22)
                Spacer(minLength: 4)
                pills
            }
            if rows.isEmpty {
                HStack(spacing: 8) {
                    deskHeadline(.title2.weight(.bold))
                    if !desk.subline.isEmpty { Text(desk.subline).font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in link(row) { deskRow(row) } }
                }
            }
            Spacer(minLength: 0)
            if !metrics.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                metricsStrip(metrics)
            } else if let note = deskNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "scope").font(.caption2.weight(.bold)).foregroundStyle(accent).accessibilityHidden(true)
                    Text(note.text).font(.caption2.weight(.semibold)).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Large

    /// The desk in full: the state and the date, every urgent line with its reason, the figures as tiles, the note, the actions.
    var deskLarge: some View {
        let metrics = Array(deskMetrics.prefix(4))
        let count = bigText ? 3 : (metrics.isEmpty ? 6 : 4)
        let rows = Array(deskRows.prefix(count))
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    deskHeader(tile: 26)
                    deskHeadline(.system(.title, design: .rounded).weight(.bold))
                    Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide)).environment(\.locale, Self.french)
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 6) {
                    pills
                    seenButton(rows)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(rows) { row in link(row) { deskRow(row) } }
                if rows.isEmpty { Text("Rien d’urgent pour Noriven.").font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if !metrics.isEmpty {
                card {
                    VStack(alignment: .leading, spacing: 4) {
                        if !deskMetricsTitle.isEmpty {
                            Text(deskMetricsTitle).font(.caption2.weight(.bold)).textCase(.uppercase).foregroundStyle(accent).lineLimit(1)
                        }
                        metricsStrip(metrics)
                    }
                }
            }
            if let note = deskNote { focusBox(note.title.isEmpty ? note.text : "\(note.title) · \(note.text)", compact: bigText || !metrics.isEmpty) }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
