import SwiftUI
import WidgetKit

/// One block the agent composed the widget with (`WidgetBlock`), drawn like the chat's cards but small: figures, rings, a
/// curve, a short list, a note. `small` is the whole small widget, `compact` half a medium one, `large` a band of the large one.
struct BoardBlockView: View {
    enum Style { case small, compact, large }
    let block: WidgetBlock
    let palette: AgentLook.Palette
    let style: Style
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var accent: Color { dark ? palette.light : palette.main }
    private func tint(_ tone: String) -> Color { BoardTone.color(tone, palette, dark: dark) }
    private static let french = Locale(identifier: "fr_CA")

    var body: some View {
        VStack(alignment: .leading, spacing: style == .large ? 6 : 5) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if !block.icon.isEmpty, UIImage(systemName: block.icon) != nil { return block.icon }
        switch block.kind {
        case .metrics: return "number"
        case .progress: return "circle.dashed"
        case .chart: return "chart.xyaxis.line"
        case .list: return "list.bullet"
        default: return "scope"
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).accessibilityHidden(true)
            Text(block.title.isEmpty ? (block.kind == .note ? "À retenir" : "Aperçu") : block.title)
                .font(.system(size: 10, weight: .bold)).textCase(.uppercase).lineLimit(1)
            Spacer(minLength: 0)
        }.foregroundStyle(accent)
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .metrics: metrics
        case .progress: progress
        case .chart: chart
        case .list: list
        case .note:
            Text(block.text).font(style == .large ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                .lineLimit(style == .small ? 6 : 3).fixedSize(horizontal: false, vertical: true)
        case .meteo, .affiche: EmptyView()
        }
    }

    // MARK: Figures

    private func figure(_ metric: WidgetBlock.Metric, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metric.value).font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.55).foregroundStyle(metric.tone.isEmpty ? Color.primary : tint(metric.tone))
            HStack(spacing: 4) {
                Text(metric.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if !metric.delta.isEmpty { Text(metric.delta).font(.system(size: 9, weight: .bold)).foregroundStyle(tint(metric.tone)).lineLimit(1) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var metrics: some View {
        let items = block.metrics
        if style == .large {
            HStack(alignment: .top, spacing: 8) { ForEach(Array(items.enumerated()), id: \.offset) { _, metric in figure(metric, size: 19) } }
        } else if items.count == 1 {
            figure(items[0], size: style == .small ? 30 : 24)
        } else {
            let pairs = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: style == .small ? 8 : 5) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    GridRow { ForEach(Array(pair.enumerated()), id: \.offset) { _, metric in figure(metric, size: style == .small ? 17 : 15) } }
                }
            }
        }
    }

    // MARK: Rings

    private func amount(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1)).locale(Self.french)) }

    @ViewBuilder private var progress: some View {
        if style == .compact {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(block.rings.prefix(3).enumerated()), id: \.offset) { _, ring in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(ring.label).font(.caption2.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 2)
                            Text("\(amount(ring.value))/\(amount(ring.goal))\(ring.unit.isEmpty ? "" : " \(ring.unit)")")
                                .font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        }
                        Bar(fraction: ring.fraction, color: accent)
                    }
                }
            }
        } else {
            let size: CGFloat = style == .small && block.rings.count == 1 ? 64 : 40
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(block.rings.prefix(3).enumerated()), id: \.offset) { _, ring in
                    VStack(spacing: 3) {
                        ZStack {
                            Circle().stroke(accent.opacity(0.18), lineWidth: size * 0.12)
                            Circle().trim(from: 0, to: max(0.02, ring.fraction))
                                .stroke(accent, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round)).rotationEffect(.degrees(-90))
                            Text("\(Int((ring.fraction * 100).rounded())) %").font(.system(size: size * 0.24, weight: .bold, design: .rounded)).monospacedDigit()
                                .minimumScaleFactor(0.6)
                        }.frame(width: size, height: size)
                        Text(ring.label).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        if style == .large || block.rings.count == 1 {
                            Text("\(amount(ring.value))/\(amount(ring.goal))\(ring.unit.isEmpty ? "" : " \(ring.unit)")")
                                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Curve

    @ViewBuilder private var chart: some View {
        if !block.value.isEmpty || !block.delta.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !block.value.isEmpty {
                    Text(block.value).font(.system(size: style == .compact ? 17 : 21, weight: .bold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                if !block.delta.isEmpty { Text(block.delta).font(.caption2.weight(.bold)).foregroundStyle(tint(block.tone.isEmpty ? "neutral" : block.tone)).lineLimit(1) }
            }
        }
        Spark(values: block.points.map(\.value), bars: block.bars, color: block.tone.isEmpty ? accent : tint(block.tone))
            .frame(height: style == .large ? 38 : style == .small ? 46 : 32)
        if style != .compact, let first = block.points.first?.label, let last = block.points.last?.label, !first.isEmpty || !last.isEmpty {
            HStack { Text(first); Spacer(); Text(last) }.font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: style == .large ? 5 : 4) {
            ForEach(Array(block.rows.prefix(3).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 7) {
                    if style != .compact {
                        Tile(symbol: !row.icon.isEmpty && UIImage(systemName: row.icon) != nil ? row.icon : "circle.fill", color: tint(row.tone), size: 20)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.title).font(.caption.weight(.semibold)).lineLimit(1)
                        if style == .large, !row.subtitle.isEmpty { Text(row.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if !row.value.isEmpty {
                        Text(row.value).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
                            .foregroundStyle(row.tone.isEmpty ? Color.primary : tint(row.tone))
                    }
                }
            }
            if block.rows.count > 3 {
                Text("+ \(block.rows.count - 3) autre\(block.rows.count - 3 > 1 ? "s" : "")").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

/// A thin progress line.
private struct Bar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color).frame(width: max(4, proxy.size.width * fraction))
            }
        }.frame(height: 5).accessibilityHidden(true)
    }
}

/// A curve (or bars) of a few points, scaled to its box; bars start from zero when every value is positive.
private struct Spark: View {
    let values: [Double]
    let bars: Bool
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let low = bars ? min(0, values.min() ?? 0) : values.min() ?? 0
            let span = max((values.max() ?? 0) - low, 1e-9)
            let height = proxy.size.height
            if bars {
                HStack(alignment: .bottom, spacing: values.count > 12 ? 2 : 4) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color.opacity(index == values.count - 1 ? 1 : 0.45))
                            .frame(height: max(2, height * (value - low) / span))
                    }
                }.frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                let step = proxy.size.width / Double(max(1, values.count - 1))
                let points = values.enumerated().map { CGPoint(x: Double($0.offset) * step, y: height - 3 - (height - 6) * ($0.element - low) / span) }
                ZStack {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height)); points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: proxy.size.width, y: height)); path.closeSubpath()
                    }.fill(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    Path { path in path.addLines(points) }.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let last = points.last { Circle().fill(color).frame(width: 6, height: 6).position(last) }
                }
            }
        }.accessibilityHidden(true)
    }
}
