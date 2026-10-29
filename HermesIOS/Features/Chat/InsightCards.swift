import Charts
import MapKit
import SwiftUI

/// Cards for what the agents read from Noriven, Noryv and the agenda: a chart, goals, a list of rows, a day, a workout
/// and a run on a map. Same surfaces and type as `RichCards`.

// MARK: - Shared pieces

/// Series, goals and calendars: the accent first, then calm companions that read in light and dark.
enum CardPalette {
    static let colors: [Color] = [AppTheme.accent, Color(red: 0.2, green: 0.62, blue: 0.42), Color(red: 0.24, green: 0.48, blue: 0.86),
                                  Color(red: 0.92, green: 0.6, blue: 0.16), Color(red: 0.55, green: 0.38, blue: 0.82), Color(red: 0.12, green: 0.6, blue: 0.68)]
    static func color(_ index: Int) -> Color { colors[index % colors.count] }
    /// Green and orange for text and figures: the system ones are too pale on white; dark mode keeps them.
    static let positive = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0.12, green: 0.52, blue: 0.26, alpha: 1) })
    static let warning = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.72, green: 0.38, blue: 0.0, alpha: 1) })
    /// The same name always gets the same colour, so a calendar keeps its colour from one reply to the next.
    static func color(for name: String) -> Color {
        guard !name.isEmpty else { return colors[0] }
        return colors[name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % colors.count]
    }
}

/// « 3 900 $ », « 1 850 kcal »: a figure with its unit.
func cardFigure(_ value: Double, unit: String) -> String {
    let number = value.formatted(.number.precision(.fractionLength(0...1)))
    return unit.isEmpty ? number : "\(number) \(unit)"
}

private struct TrendLabel: View {
    let delta: String
    let trend: ChatCard.Trend
    var body: some View {
        Label(delta, systemImage: trend == .up ? "arrow.up.right" : trend == .down ? "arrow.down.right" : "minus")
            .font(.subheadline.weight(.semibold)).labelStyle(.titleAndIcon)
            .foregroundStyle(trend == .up ? CardPalette.positive : trend == .down ? AppTheme.accent : .secondary)
    }
}

/// A map region around coordinates, with room for what is drawn on top of them.
private func framing(_ coordinates: [CLLocationCoordinate2D], padding: Double) -> MapCameraPosition {
    let lats = coordinates.map(\.latitude), lons = coordinates.map(\.longitude)
    guard let south = lats.min(), let north = lats.max(), let west = lons.min(), let east = lons.max() else { return .automatic }
    let center = CLLocationCoordinate2D(latitude: (north + south) / 2, longitude: (east + west) / 2)
    return .region(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: min(max((north - south) * padding, 0.004), 170),
                                                                            longitudeDelta: min(max((east - west) * padding, 0.004), 350))))
}

// MARK: - Chart (MRR, revenue, visits, clicks, weight, training volume)

struct ChartCard: View {
    let chart: ChatCard.Chart
    @State private var pinned: String?
    @State private var scrub: String?
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selected: String? { scrub ?? pinned }
    private var focus: ChatCard.Point? { selected.flatMap { id in chart.points.first { String($0.id) == id } } }
    private var headline: String {
        if let focus { return cardFigure(focus.value, unit: chart.unit) }
        return chart.value.isEmpty ? cardFigure(chart.points.last?.value ?? 0, unit: chart.unit) : chart.value
    }
    /// Line charts follow the data closely; bars start at zero.
    private var domain: ClosedRange<Double> {
        let values = chart.points.map(\.value) + (chart.goal.map { [$0] } ?? [])
        let low = values.min() ?? 0, high = values.max() ?? 1
        if chart.bars { return min(0, low)...max(high * 1.08, 1) }
        let pad = max((high - low) * 0.18, abs(high) * 0.02, 0.5)
        return (low - pad)...(high + pad)
    }
    /// At most about six labels under the axis, the last one always shown.
    private var axisIDs: [String] {
        let step = max(1, Int((Double(chart.points.count) / 6).rounded(.up)))
        return chart.points.enumerated().filter { $0.offset % step == 0 || $0.offset == chart.points.count - 1 }.map { String($0.element.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: chart.title, symbol: chart.bars ? "chart.bar.fill" : "chart.xyaxis.line")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headline).font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                    .contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.6)
                if let focus {
                    Text(focus.label).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                } else if !chart.delta.isEmpty {
                    TrendLabel(delta: chart.delta, trend: chart.trend)
                }
            }
            .animation(.snappy(duration: 0.2), value: selected)
            plot.frame(height: 170)
        }
        .padding(16).cardSurface()
        .onAppear { if reduceMotion { grown = true } else { withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.05)) { grown = true } } }
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityIdentifier("card-chart")
    }

    private var plot: some View {
        Chart {
            ForEach(chart.points) { point in
                let x = PlottableValue.value("Période", String(point.id))
                if chart.bars {
                    BarMark(x: x, y: .value("Valeur", grown ? point.value : 0), width: .ratio(0.62))
                        .foregroundStyle(AppTheme.accent.opacity(focus == nil ? (point.id == chart.points.last?.id ? 1 : 0.45) : (point.id == focus?.id ? 1 : 0.3)))
                        .cornerRadius(5)
                } else {
                    AreaMark(x: x, yStart: .value("Base", domain.lowerBound), yEnd: .value("Valeur", point.value))
                        .foregroundStyle(LinearGradient(colors: [AppTheme.accent.opacity(grown ? 0.26 : 0), AppTheme.accent.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: x, y: .value("Valeur", point.value))
                        .foregroundStyle(AppTheme.accent).lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let goal = chart.goal {
                RuleMark(y: .value("Objectif", goal))
                    .foregroundStyle(Color.secondary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Objectif \(cardFigure(goal, unit: chart.unit))").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
            }
            if let point = focus ?? (chart.bars ? nil : chart.points.last) {
                if focus != nil { RuleMark(x: .value("Période", String(point.id))).foregroundStyle(Color.secondary.opacity(0.35)) }
                if !chart.bars {
                    PointMark(x: .value("Période", String(point.id)), y: .value("Valeur", point.value))
                        .foregroundStyle(AppTheme.accent).symbolSize(80)
                        .annotation(position: .overlay) { Circle().fill(.white).frame(width: 4, height: 4) }
                }
            }
        }
        .chartYScale(domain: domain)
        // Not chartXSelection: its drag takes the conversation's scroll, and a long press belongs to the message's menu.
        // A tap pins a point; a sideways slide runs along the curve; an upward or downward swipe still scrolls.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(ChartTap { location in
                        let id = category(at: location, proxy: proxy, geometry: geometry)
                        pinned = pinned == id ? nil : id
                    })
                    .gesture(SidewaysScrub { location in
                        scrub = location.flatMap { category(at: $0, proxy: proxy, geometry: geometry) }
                    })
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(AppTheme.line)
                AxisValueLabel { if let number = value.as(Double.self) { Text(number, format: .number.notation(.compactName)) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisIDs) { value in
                AxisValueLabel {
                    if let id = value.as(String.self), let point = chart.points.first(where: { String($0.id) == id }) { Text(point.label) }
                }
            }
        }
        .accessibilityLabel(chart.title.isEmpty ? "Graphique" : chart.title)
        .accessibilityValue(chart.points.map { "\($0.label) \(cardFigure($0.value, unit: chart.unit))" }.joined(separator: ", "))
    }

    private func category(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> String? {
        guard let plot = proxy.plotFrame else { return nil }
        return proxy.value(atX: location.x - geometry[plot].origin.x, as: String.self)
    }
}

/// A tap on a chart, from UIKit: SwiftUI's own tap waits behind the message's long press and never fires.
private struct ChartTap: UIGestureRecognizerRepresentable {
    let tapped: (CGPoint) -> Void
    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer { UITapGestureRecognizer() }
    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { tapped(context.converter.localLocation) }
    }
}

/// A finger sliding sideways along a chart. It only starts on a mostly horizontal move, so the conversation keeps
/// scrolling under a vertical swipe. Reports nil when the finger lifts.
private struct SidewaysScrub: UIGestureRecognizerRepresentable {
    let moved: (CGPoint?) -> Void
    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began, .changed: moved(context.converter.localLocation)
        default: moved(nil)
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}

// MARK: - Goals (calories and macros, sessions of the week)

struct ProgressCard: View {
    let title: String
    let goals: [ChatCard.Goal]
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(text: title, symbol: "target")
            if goals.count <= 3 {
                HStack(spacing: 20) {
                    ZStack {
                        ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in ring(goal, index: index) }
                    }
                    .frame(width: 116, height: 116)
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in legend(goal, color: CardPalette.color(index)) }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(goals.enumerated()), id: \.element.id) { index, goal in bar(goal, color: CardPalette.color(index)) }
                }
            }
        }
        .padding(16).cardSurface()
        .onAppear { if reduceMotion { filled = true } else { withAnimation(.spring(response: 1.0, dampingFraction: 0.85).delay(0.1)) { filled = true } } }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-progress")
    }

    private func ring(_ goal: ChatCard.Goal, index: Int) -> some View {
        let color = CardPalette.color(index), width: CGFloat = 13
        return ZStack {
            Circle().inset(by: width / 2).stroke(color.opacity(0.16), lineWidth: width)
            Circle().inset(by: width / 2).trim(from: 0, to: filled ? min(goal.progress, 1) : 0)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .padding(CGFloat(index) * (width + 2))
    }

    private func legend(_ goal: ChatCard.Goal, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(goal.label).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(cardFigure(goal.value, unit: "")).font(.system(.headline, design: .rounded)).monospacedDigit()
                    Text("/ \(cardFigure(goal.goal, unit: goal.unit))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func bar(_ goal: ChatCard.Goal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.label).font(.subheadline.weight(.medium))
                Spacer()
                Text("\(cardFigure(goal.value, unit: "")) / \(cardFigure(goal.goal, unit: goal.unit))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { geometry in
                Capsule().fill(color.opacity(0.16)).overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: max(8, geometry.size.width * (filled ? min(goal.progress, 1) : 0)))
                }
            }.frame(height: 8)
        }
    }
}

// MARK: - Rows (expenses, revenue, sorted emails, search queries, pages)

struct ListCard: View {
    let title: String
    let rows: [ChatCard.Row]
    let total: ChatCard.Stat?
    @State private var expanded = false
    private var folds: Bool { rows.count > 6 }
    private var visible: [ChatCard.Row] { folds && !expanded ? Array(rows.prefix(5)) : rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: title, symbol: "list.bullet")
            VStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 60) }
                    ListRow(row: row)
                }
                if folds {
                    Divider()
                    Button { Haptics.select(); withAnimation(.snappy(duration: 0.3)) { expanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Text(expanded ? "Réduire" : "Voir les \(rows.count - 5) autres")
                            Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 11).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if let total {
                    HStack(alignment: .firstTextBaseline) {
                        Text(total.label).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(total.value).font(.system(.headline, design: .rounded)).monospacedDigit()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(AppTheme.line.opacity(0.6), in: UnevenRoundedRectangle(bottomLeadingRadius: CardStyle.radius, bottomTrailingRadius: CardStyle.radius, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
            .cardSurface()
        }
        .accessibilityIdentifier("card-list")
    }
}

private struct ListRow: View {
    let row: ChatCard.Row
    @Environment(\.openURL) private var openURL
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    @State private var sent = false
    private var replies: Bool { row.url == nil && !row.reply.isEmpty && reply != nil && interactive }

    var body: some View {
        if row.url != nil || replies {
            Button(action: act) { content }.buttonStyle(PressableStyle()).disabled(sent)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 12) {
            RowIcon(name: row.icon, title: row.title, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !row.badge.isEmpty {
                        Text(row.badge).font(.caption2.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundStyle(tint).background(tint.opacity(0.12), in: Capsule())
                    }
                }
                if !row.subtitle.isEmpty { Text(row.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
            }
            Spacer(minLength: 8)
            if !row.value.isEmpty { Text(row.value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(valueColor).lineLimit(1) }
            if row.url != nil || replies {
                Image(systemName: sent ? "checkmark" : row.url != nil ? "arrow.up.right" : "chevron.right")
                    .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch row.tone { case .positive: CardPalette.positive; case .warning: CardPalette.warning; case .negative, .neutral: AppTheme.accent }
    }
    private var valueColor: Color {
        switch row.tone { case .positive: CardPalette.positive; case .negative: AppTheme.accent; case .warning: CardPalette.warning; case .neutral: .primary }
    }
    private func act() {
        if let url = row.url { Haptics.select(); openURL(url) }
        else if let reply, !sent, reply.send(row.reply) { Haptics.send(); sent = true }
    }
}

private struct RowIcon: View {
    let name: String, title: String, tint: Color
    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.13))
            if !name.isEmpty, UIImage(systemName: name) != nil {
                Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
            } else {
                Text(String(title.prefix(1)).uppercased()).font(.system(.subheadline, design: .rounded).weight(.bold)).foregroundStyle(tint)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }
}

// MARK: - A day or a week of the agenda (shifts included)

struct AgendaCard: View {
    let title: String
    let slots: [ChatCard.Slot]


    var body: some View {
        // Worked out once per render (each reads every slot's date): several days get a heading at each new day.
        let days = slots.map { ChatCard.day($0.start) }
        let several = Set(days.compactMap { $0 }).count > 1
        let free = ChatCard.freeTime(slots)
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: title, symbol: "calendar")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    if several, let day = days[index], index == 0 || day != days[index - 1], let date = EventCard.date(slot.start) {
                        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)).capitalized)
                            .font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                            .padding(.horizontal, 14).padding(.top, index > 0 ? 12 : 4).padding(.bottom, 2)
                    }
                    if let gap = free[slot.id], gap >= 60 { FreeTime(minutes: gap) }
                    AgendaRow(slot: slot)
                }
            }
            .padding(.vertical, 6)
            .cardSurface()
        }
        .accessibilityIdentifier("card-agenda")
    }
}

private struct AgendaRow: View {
    let slot: ChatCard.Slot
    @Environment(\.calendarEvent) private var calendarEvent
    private var color: Color { CardPalette.color(for: slot.calendar) }
    private var now: Bool {
        guard let start = EventCard.date(slot.start), let end = EventCard.date(slot.end), slot.start.count > 10 else { return false }
        return (start...max(start, end)).contains(.now)
    }

    var body: some View {
        if let date = EventCard.date(slot.start) {
            Button { openInCalendar(CalendarEventRequest(title: slot.title, start: date), using: calendarEvent) } label: { content }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Ouvre l’événement dans Calendrier")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.clock(slot.start)).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                if !slot.end.isEmpty, ChatCard.minutes(slot.end) != nil {
                    Text(Self.clock(slot.end)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 52, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 4).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(slot.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                    if now {
                        Text("Maintenant").font(.caption2.weight(.bold)).foregroundStyle(.primary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.25), in: Capsule())
                    }
                }
                if !slot.location.isEmpty {
                    Label(slot.location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !slot.calendar.isEmpty { Text(slot.calendar).font(.caption.weight(.medium)).foregroundStyle(color) }
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(now ? color.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// « 07:00 » for a time, « Journée » for a whole day.
    static func clock(_ raw: String) -> String {
        guard let minutes = ChatCard.minutes(raw) else { return raw.count == 10 ? "Journée" : raw }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

private struct FreeTime: View {
    let minutes: Int
    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 52, height: 1)
            Capsule().fill(AppTheme.line).frame(width: 4, height: 14)
            Label("Libre · \(Self.duration(minutes))", systemImage: "cup.and.saucer")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 3)
    }
    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", rest))"
    }
}

// MARK: - Workout (Noryv)

struct WorkoutCard: View {
    let workout: ChatCard.Workout
    private var completion: (done: Int, total: Int)? {
        let flags = workout.exercises.compactMap(\.done)
        return flags.isEmpty ? nil : (flags.filter { $0 }.count, workout.exercises.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "dumbbell.fill").font(.title3).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(LinearGradient(colors: [AppTheme.accent, AppTheme.accent.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(workout.title.isEmpty ? "Séance" : workout.title).font(.headline)
                    if !workout.subtitle.isEmpty { Text(workout.subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if let completion {
                    ZStack {
                        Circle().stroke(Color.green.opacity(0.18), lineWidth: 4)
                        Circle().trim(from: 0, to: Double(completion.done) / Double(max(completion.total, 1)))
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text("\(completion.done)/\(completion.total)").font(.caption2.weight(.bold)).monospacedDigit()
                    }
                    .frame(width: 40, height: 40)
                }
            }
            if !workout.stats.isEmpty {
                HStack(spacing: 8) {
                    ForEach(workout.stats) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.value).font(.system(.headline, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                            Text(stat.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(AppTheme.line.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            if !workout.exercises.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(workout.exercises.enumerated()), id: \.element.id) { index, exercise in
                        if index > 0 { Divider().padding(.leading, 36) }
                        ExerciseRow(number: index + 1, exercise: exercise)
                    }
                }
            }
        }
        .padding(16).cardSurface()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-workout")
    }
}

private struct ExerciseRow: View {
    let number: Int
    let exercise: ChatCard.Exercise
    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch exercise.done {
                case true?: Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                case false?: Image(systemName: "circle").font(.title3).foregroundStyle(.tertiary)
                case nil:
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(AppTheme.accent)
                        .frame(width: 22, height: 22).background(AppTheme.accent.opacity(0.12), in: Circle())
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise.name).font(.subheadline.weight(.medium)).foregroundStyle(exercise.done == false ? Color.secondary : Color.primary)
                if !exercise.note.isEmpty {
                    Label(exercise.note, systemImage: Self.noteSymbol(exercise.note)).font(.caption2.weight(.semibold))
                        .foregroundStyle(CardPalette.warning).labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if !exercise.sets.isEmpty { Text(exercise.sets).font(.subheadline.weight(.semibold)).monospacedDigit() }
                if !exercise.weight.isEmpty { Text(exercise.weight).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
        .padding(.vertical, 8)
    }
    static func noteSymbol(_ note: String) -> String {
        let n = note.lowercased()
        let words = n.split(whereSeparator: { !$0.isLetter })
        return n.contains("record") || n.contains("meilleur") || words.contains("pr") ? "trophy.fill" : "sparkle"
    }
}

// MARK: - A run on the map (Noryv cardio)

struct RouteCard: View {
    let route: ChatCard.Route
    @State private var expanded = false
    private var coordinates: [CLLocationCoordinate2D] { route.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: route.title, symbol: "figure.run")
            VStack(spacing: 0) {
                Button { Haptics.select(); expanded = true } label: {
                    RouteMap(points: coordinates, interactive: false).frame(height: 190)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption.weight(.bold))
                                .padding(8).background(.thinMaterial, in: Circle()).padding(10)
                        }
                }.buttonStyle(.plain).accessibilityLabel("Agrandir le parcours")
                if !route.stats.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(route.stats) { stat in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stat.value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                                Text(stat.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(14)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
            .cardSurface()
        }
        .sheet(isPresented: $expanded) {
            NavigationStack {
                RouteMap(points: coordinates, interactive: true).ignoresSafeArea(edges: .bottom)
                    .navigationTitle(route.title.isEmpty ? "Parcours" : route.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { AppToolbarItem(placement: .confirmationAction) { AppCloseButton { expanded = false } } }
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .accessibilityIdentifier("card-route")
    }
}

private struct RouteMap: View {
    let points: [CLLocationCoordinate2D]
    let interactive: Bool
    var body: some View {
        Map(initialPosition: framing(points, padding: 1.6), interactionModes: interactive ? .all : []) {
            MapPolyline(coordinates: points)
                .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let start = points.first {
                Annotation("Départ", coordinate: start, anchor: .center) {
                    Circle().fill(Color.green).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 2)
                }.annotationTitles(.hidden)
            }
            if let end = points.last, !loop {
                Annotation("Arrivée", coordinate: end, anchor: .center) {
                    Image(systemName: "flag.checkered").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(AppTheme.accent, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2)).shadow(radius: 2)
                }.annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }

    /// A run that ends where it started shows one marker, not a flag hidden under the start.
    private var loop: Bool {
        guard let start = points.first, let end = points.last else { return true }
        return CLLocation(latitude: start.latitude, longitude: start.longitude).distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude)) < 80
    }
}

// MARK: - State of a server or a service (Noriven ops tools)

struct StatusCard: View {
    let status: ChatCard.Status
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.title3).foregroundStyle(Self.color(status.state))
                    .frame(width: 44, height: 44)
                    .background(Self.color(status.state).opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title.isEmpty ? "Serveur" : status.title).font(.headline).lineLimit(1)
                    if !status.subtitle.isEmpty { Text(status.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Self.color(status.state))
                        .symbolEffect(.pulse, options: .repeating, isActive: status.state == .ok && !reduceMotion)
                    Text(Self.label(status.state)).font(.caption.weight(.semibold)).foregroundStyle(Self.color(status.state))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Self.color(status.state).opacity(0.12), in: Capsule())
            }
            if !status.gauges.isEmpty {
                HStack(spacing: 8) {
                    ForEach(status.gauges) { gauge in GaugeRing(gauge: gauge, filled: filled).frame(maxWidth: .infinity) }
                }
            }
            if !status.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(status.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 20) }
                        HStack(spacing: 10) {
                            Circle().fill(Self.color(item.state)).frame(width: 9, height: 9)
                            Text(item.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(item.detail.isEmpty ? Self.label(item.state) : item.detail).font(.caption)
                                .foregroundStyle(item.state == .ok ? Color.secondary : Self.color(item.state)).lineLimit(1)
                        }
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(16).cardSurface()
        .onAppear {
            guard !reduceMotion else { filled = true; return }
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) { filled = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("card-status")
    }

    static func color(_ state: ChatCard.Health) -> Color {
        switch state { case .ok: .green; case .warning: .orange; case .down: .red; case .unknown: .secondary }
    }
    static func label(_ state: ChatCard.Health) -> String {
        switch state { case .ok: "En ligne"; case .warning: "À surveiller"; case .down: "En panne"; case .unknown: "Inconnu" }
    }
}

/// CPU, memory or disk as a small ring: green while there is room, orange past 70 %, red past 90 %.
private struct GaugeRing: View {
    let gauge: ChatCard.Gauge
    let filled: Bool
    private var color: Color { gauge.fraction >= 0.9 ? .red : gauge.fraction >= 0.7 ? .orange : .green }
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.16), lineWidth: 7)
                Circle().trim(from: 0, to: filled ? max(gauge.fraction, 0.01) : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                Text("\(Int((gauge.fraction * 100).rounded())) %").font(.system(.caption, design: .rounded).weight(.bold)).monospacedDigit()
            }
            .frame(width: 62, height: 62)
            Text(gauge.label).font(.caption.weight(.medium))
            if gauge.unit != "%" {
                Text("\(cardFigure(gauge.value, unit: "")) / \(cardFigure(gauge.maximum, unit: gauge.unit))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}

// MARK: - News (hermes-nouvelles)

struct NewsCard: View {
    let title: String
    let articles: [ChatCard.Article]
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(text: title, symbol: "newspaper")
            VStack(spacing: 0) {
                if let lead = articles.first {
                    Button { open(lead) } label: {
                        ZStack(alignment: .bottomLeading) {
                            Color.clear.frame(height: 190).frame(maxWidth: .infinity)
                                .overlay { CardImage(image: lead.image, page: lead.url) }.clipped()
                            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(lead.title).font(.headline).foregroundStyle(.white).lineLimit(3).multilineTextAlignment(.leading)
                                ArticleByline(article: lead).foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(14)
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
                ForEach(articles.dropFirst()) { article in
                    Divider().padding(.leading, 84)
                    ArticleRow(article: article)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
            .cardSurface()
        }
        .accessibilityIdentifier("card-news")
    }

    private func open(_ article: ChatCard.Article) {
        guard let url = article.url else { return }
        Haptics.select(); openURL(url)
    }
}

/// « Radio-Canada · il y a 2 h »
private struct ArticleByline: View {
    let article: ChatCard.Article
    var body: some View {
        Text([article.source, article.time].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption.weight(.medium)).lineLimit(1)
    }
}

/// One article: a picture (the page's own when the feed has none), its title, source and age. Opens in the in-app browser.
struct ArticleRow: View {
    let article: ChatCard.Article
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { if let url = article.url { Haptics.select(); openURL(url) } } label: {
            HStack(spacing: 12) {
                CardImage(image: article.image, page: article.url).frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(article.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    ArticleByline(article: article).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Morning summary

struct BriefCard: View {
    let brief: ChatCard.Brief
    @Environment(\.colorScheme) private var scheme

    /// Sunrise in the morning, daylight at noon, dusk at night: the card follows the hour it is read.
    private var sky: [Color] {
        let hour = Calendar.current.component(.hour, from: .now), dark = scheme == .dark
        switch hour {
        case 5..<11: return dark ? [Color(red: 0.55, green: 0.27, blue: 0.22), Color(red: 0.32, green: 0.18, blue: 0.3)]
                                 : [Color(red: 0.84, green: 0.4, blue: 0.27), Color(red: 0.66, green: 0.25, blue: 0.36)]
        case 11..<17: return dark ? [Color(red: 0.13, green: 0.3, blue: 0.5), Color(red: 0.08, green: 0.17, blue: 0.33)]
                                  : [Color(red: 0.2, green: 0.45, blue: 0.78), Color(red: 0.13, green: 0.32, blue: 0.64)]
        default: return dark ? [Color(red: 0.2, green: 0.17, blue: 0.4), Color(red: 0.1, green: 0.08, blue: 0.22)]
                             : [Color(red: 0.42, green: 0.36, blue: 0.75), Color(red: 0.25, green: 0.2, blue: 0.5)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(brief.greeting.isEmpty ? "Bonjour" : brief.greeting).font(.system(.title2, design: .rounded).weight(.bold))
                    if !brief.date.isEmpty { Text(brief.date).font(.subheadline.weight(.medium)).opacity(0.85) }
                }
                Spacer(minLength: 8)
                if let weather = brief.weather {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: ChatCard.weatherSymbol(weather.condition)).symbolRenderingMode(.multicolor).font(.title2)
                            if let temperature = weather.temperature { Text("\(Int(temperature.rounded()))°").font(.system(.title, design: .rounded).weight(.semibold)) }
                        }
                        if let high = weather.high, let low = weather.low {
                            Text("↑\(Int(high.rounded()))°  ↓\(Int(low.rounded()))°").font(.caption.weight(.semibold)).opacity(0.85)
                        } else if !weather.condition.isEmpty {
                            Text(weather.condition).font(.caption.weight(.medium)).opacity(0.85).lineLimit(1)
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: sky, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: UnevenRoundedRectangle(topLeadingRadius: CardStyle.radius, topTrailingRadius: CardStyle.radius, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(brief.sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { Divider().padding(.leading, 52) }
                    BriefSectionView(section: section, day: ChatCard.spokenDay(brief.date))
                }
                if !brief.focus.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "scope").font(.subheadline.weight(.bold)).foregroundStyle(AppTheme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("À retenir").font(.caption.weight(.bold)).foregroundStyle(AppTheme.accent).textCase(.uppercase)
                            Text(brief.focus).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(AppTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(12)
                }
            }
            .padding(.vertical, 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: CardStyle.radius, style: .continuous))
        .cardSurface()
        .accessibilityIdentifier("card-brief")
    }
}

private struct BriefSectionView: View {
    let section: ChatCard.BriefSection
    /// The day the summary is about (its date line); today when it does not say.
    let day: Date?
    @Environment(\.openURL) private var openURL
    @Environment(\.chatReply) private var reply
    @Environment(\.cardsInteractive) private var interactive
    @Environment(\.calendarEvent) private var calendarEvent
    @State private var sent: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(section.kind)).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Self.color(section.kind), in: Circle())
                Text(section.title.isEmpty ? Self.title(section.kind) : section.title).font(.subheadline.weight(.bold))
            }
            VStack(alignment: .leading, spacing: 6) {
                if !section.text.isEmpty {
                    Text(section.text).font(.subheadline).foregroundStyle(Color.primary.opacity(0.88)).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(section.lines) { line in lineView(line) }
            }
            .padding(.leading, 38)
            if !section.articles.isEmpty {
                VStack(spacing: 0) { ForEach(section.articles) { ArticleRow(article: $0) } }
                    .padding(.horizontal, -14).padding(.leading, 38).padding(.vertical, -6)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    @ViewBuilder private func lineView(_ line: ChatCard.BriefLine) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !line.time.isEmpty { Text(line.time).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Self.color(section.kind)) }
            Text(line.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if !line.detail.isEmpty { Text(line.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if line.url != nil || (!line.reply.isEmpty && reply != nil && interactive) || (section.kind == .agenda && ChatCard.minutes(line.time) != nil) {
                Image(systemName: sent.contains(line.id) ? "checkmark" : "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        if let url = line.url {
            Button { Haptics.select(); openURL(url) } label: { row.contentShape(Rectangle()) }.buttonStyle(PressableStyle())
        } else if !line.reply.isEmpty, let reply, interactive {
            // The agent's own follow-up for this line comes first.
            Button {
                guard !sent.contains(line.id), reply.send(line.reply) else { return }
                Haptics.send(); sent.insert(line.id)
            } label: { row.contentShape(Rectangle()) }.buttonStyle(PressableStyle()).disabled(sent.contains(line.id))
        } else if section.kind == .agenda, let minutes = ChatCard.minutes(line.time),
                  let start = Calendar.current.date(bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: day ?? .now) {
            // An agenda line opens its event, on the day the summary is about.
            Button { openInCalendar(CalendarEventRequest(title: line.text, start: start), using: calendarEvent) } label: { row.contentShape(Rectangle()) }
                .buttonStyle(PressableStyle()).accessibilityHint("Ouvre l’événement dans Calendrier")
        } else {
            row
        }
    }

    static func symbol(_ kind: ChatCard.BriefKind) -> String {
        switch kind {
        case .agenda: "calendar"; case .training: "dumbbell.fill"; case .nutrition: "fork.knife"; case .email: "envelope.fill"
        case .news: "newspaper.fill"; case .health: "heart.fill"; case .money: "dollarsign"; case .tasks: "checklist"
        case .weather: "cloud.sun.fill"; case .note: "sparkles"
        }
    }
    static func color(_ kind: ChatCard.BriefKind) -> Color {
        switch kind {
        case .agenda: CardPalette.colors[2]; case .training: AppTheme.accent; case .nutrition: CardPalette.colors[1]
        case .email: CardPalette.colors[3]; case .news: CardPalette.colors[4]; case .health: .pink; case .money: CardPalette.colors[1]
        case .tasks: CardPalette.colors[5]; case .weather: CardPalette.colors[2]; case .note: .gray
        }
    }
    static func title(_ kind: ChatCard.BriefKind) -> String {
        switch kind {
        case .agenda: "Aujourd’hui"; case .training: "Entraînement"; case .nutrition: "Nourriture"; case .email: "Courriels"
        case .news: "Nouvelles"; case .health: "Santé"; case .money: "Finances"; case .tasks: "À faire"; case .weather: "Météo"; case .note: "À noter"
        }
    }
}
