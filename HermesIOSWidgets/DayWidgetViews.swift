import SwiftUI
import WidgetKit

/// Jarvis's widget: Maxime's day. The date and the weather in one line, the day as a strip (each event a span, a mark for
/// now), what comes next in large type with its countdown, then one line for the week's payslip (the `paie` block Jarvis
/// publishes once he has checked it), else another of his blocks, else his « À retenir ». Full width, never two halves.
extension BoardWidgetView {
    // MARK: Data

    private var liveDayBlocks: [WidgetBlock] { entry.blocks.filter { !$0.isExpired(at: entry.date) && !$0.isPlacement } }
    /// The payslip's verdict, when Jarvis has published it (slot `paie`).
    var payBlock: WidgetBlock? { liveDayBlocks.first { $0.slot == "paie" } }
    /// What the bottom line shows: the payslip first, else Jarvis's first block of content.
    private var dayBlock: WidgetBlock? { payBlock ?? liveDayBlocks.sorted { $0.order < $1.order }.first }

    private var stripSpans: [DayStrip.Span] {
        let events = entry.rows.compactMap { row in row.when.map { DayStrip.Event(start: $0, end: row.item.until, tone: row.item.tone) } }
        return DayStrip.spans(events, on: entry.date)
    }

    // MARK: Pieces

    /// The day from 6 h to 23 h: the hours gone shaded, each event in its colour, a mark for now.
    func dayStrip(labels: Bool) -> some View {
        let now = DayStrip.position(entry.date, on: entry.date) ?? 0
        let spans = stripSpans
        return VStack(spacing: 2) {
            GeometryReader { box in
                let width = box.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.primary.opacity(0.1)).frame(width: max(0, width * now))
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        Capsule().fill(BoardTone.color(span.tone, entry.palette, dark: dark))
                            .frame(width: max(5, width * (span.to - span.from)))
                            .offset(x: width * span.from)
                    }
                    Capsule().fill(Color.primary).frame(width: 2.5, height: box.size.height + 5)
                        .offset(x: min(width - 2.5, max(0, width * now - 1.25)))
                }
            }
            .frame(height: 7)
            if labels {
                HStack {
                    ForEach(["6 h", "12 h", "18 h", "23 h"], id: \.self) { label in
                        Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                        if label != "23 h" { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A block in one line: its tile in its tone, its title, and what it says (« Paie du 19 · Tout balance »).
    func blockLine(_ block: WidgetBlock) -> some View {
        let tone = block.tone.isEmpty ? (block.metrics.first { !$0.tone.isEmpty }?.tone ?? "") : block.tone
        let color = tone.isEmpty ? accent : BoardTone.color(tone, entry.palette, dark: dark)
        let symbol = !block.icon.isEmpty ? block.icon : block.slot == "paie" ? "dollarsign.circle.fill" : "square.grid.2x2.fill"
        let says = block.kind == .note ? block.text
            : block.metrics.map { "\($0.label) \($0.value)" }.joined(separator: " · ")
        return HStack(spacing: 8) {
            Tile(symbol: symbol, color: color, size: 24)
            VStack(alignment: .leading, spacing: 0) {
                if !block.title.isEmpty { Text(block.title).font(.caption.weight(.bold)).lineLimit(1) }
                if !says.isEmpty { Text(says).font(.caption2.weight(.medium)).foregroundStyle(block.title.isEmpty ? .primary : .secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// « SAMEDI 21 NOVEMBRE » on the left, the weather now and the day's high and low on the right.
    private var dayHeader: some View {
        HStack(alignment: .center, spacing: 6) {
            dateCaps()
            Spacer(minLength: 6)
            if entry.weather != nil {
                HStack(spacing: 3) {
                    wx(entry.weatherSymbol, 14)
                    Text(degrees(entry.temperature)).font(.subheadline.weight(.bold)).monospacedDigit()
                    let range = highLow(entry.today)
                    if !range.isEmpty { Text(range).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                .fixedSize()
            }
        }
    }

    // MARK: Medium

    var dayMedium: some View {
        let hero = entry.upcomingRows.isEmpty ? nil : entry.hero
        let after = hero.flatMap { next(after: $0).first }
        return VStack(alignment: .leading, spacing: 7) {
            dayHeader
            dayStrip(labels: false).padding(.bottom, 5)   // room between the strip and the line under it
            if let hero {
                link(hero) {
                    HStack(alignment: .center, spacing: 10) {
                        Tile(symbol: BoardTone.symbol(hero.item), color: color(hero), size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(hero.item.text).font(.headline).lineLimit(1)
                            HStack(spacing: 6) {
                                sub(hero)
                                if !hero.item.detail.isEmpty, hero.phase == .now || hero.phase == .next {
                                    Text(hero.item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 4)
                        if !hero.item.time.isEmpty {
                            Text(hero.item.time).font(.system(.title2, design: .rounded).weight(.bold)).monospacedDigit()
                                .foregroundStyle(color(hero)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                }
                if let after, !bigText {
                    Text("Ensuite · \(after.item.time.isEmpty ? "" : "\(after.item.time) ")\(after.item.text)")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 44)
                }
            } else {
                HStack(spacing: 10) {
                    Tile(symbol: entry.dayDone ? "checkmark" : entry.greetingSymbol, color: accent, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.dayDone ? "Journée terminée" : entry.freeDay ? "Rien à l’agenda" : entry.greeting).font(.headline).lineLimit(1)
                        if entry.weather != nil, let weather = entry.weather { Text(weather.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
            if let block = dayBlock {
                blockLine(block)
            } else if !entry.note.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "scope").font(.caption2.weight(.bold)).foregroundStyle(accent).accessibilityHidden(true)
                    Text(entry.note).font(.caption2.weight(.semibold)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
