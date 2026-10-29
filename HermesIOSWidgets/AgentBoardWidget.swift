import AppIntents
import SwiftUI
import WidgetKit

/// The agent's own board: what it judged worth showing right now (the next appointment, a shift, one thing to keep in
/// mind). It decides when to update it and never notifies for it; the widget only draws what the app last saved. Drawn
/// like the chat's cards: symbol tiles, the next thing in large type with a countdown, a timeline, a « À retenir » box.
struct AgentBoardWidget: Widget {
    static let kind = "AgentBoardWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectAgentIntent.self, provider: BoardProvider()) { entry in
            BoardWidgetView(entry: entry)
                .widgetURL(entry.openURL)
                .containerBackground(for: .widget) { BoardBackground(profile: entry.profile) }
        }
        .configurationDisplayName("À l’affiche")
        .description("Ce que votre agent juge utile de vous montrer maintenant.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

/// Which agent the widget shows: long-press the widget, then « Modifier le widget ».
struct SelectAgentIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agent"
    static let description = IntentDescription("Choisissez l’agent dont le widget affiche le tableau.")
    @Parameter(title: "Agent") var agent: AgentEntity?
}

// MARK: - Data

/// « 13:45 », « 9h », « 9 h 30 » → that time on the given day.
enum BoardTime {
    static func date(_ text: String, on day: Date) -> Date? {
        guard let match = text.firstMatch(of: /(\d{1,2})\s*[:hH]\s*(\d{2})?/), let hour = Int(match.1), hour < 24 else { return nil }
        let minute = match.2.flatMap { Int($0) } ?? 0
        guard minute < 60 else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
    /// A moment this recent still counts as « maintenant ».
    static let nowWindow: TimeInterval = 15 * 60
}

struct BoardRow: Identifiable {
    enum Phase { case past, now, next, later }
    /// Position in the board: two lines can share a time and a title (a daily stand-up), so the text is no identity.
    let index: Int
    let item: AgentBoard.Item
    let when: Date?
    var phase: Phase
    var id: Int { index }
}

struct BoardEntry: TimelineEntry {
    let date: Date
    let profile: String
    let agentTitle: String
    /// nil: this agent has not published anything.
    let board: AgentBoard?
    /// The calendar's next events, read by the server with no model; nil when this agent has no Google.
    var agenda: AgentBoard?
    var isPlaceholder = false

    /// Every line is over (and nothing is left to keep in mind): the day is done, not « 06:45 Quart de jour » at nine at night.
    private func isDone(_ board: AgentBoard) -> Bool {
        guard !board.items.isEmpty, board.focus.isEmpty else { return false }
        return board.items.allSatisfy { item in
            guard let start = item.at ?? BoardTime.date(item.time, on: date) else { return false }
            return item.until.map { $0 <= date } ?? (start < date.addingTimeInterval(-BoardTime.nowWindow))
        }
    }
    private func current(_ board: AgentBoard?) -> AgentBoard? { board.flatMap { $0.isEmpty || $0.isExpired(at: date) || isDone($0) ? nil : $0 } }
    private var agentBoard: AgentBoard? { current(board) }
    private var calendarBoard: AgentBoard? { current(agenda) }
    var dayDone: Bool { live == nil && [board, agenda].contains { $0.map { !$0.isEmpty && !$0.isExpired(at: date) && isDone($0) } ?? false } }
    /// What to draw: the agent's own lines, else the calendar's next events, else an agent's lone note, else nothing.
    var live: AgentBoard? { agentBoard.flatMap { $0.items.isEmpty ? nil : $0 } ?? calendarBoard ?? agentBoard }
    /// The agent's « À retenir », kept in view whatever supplies the lines (its own, or the calendar's).
    var note: String { agentBoard?.focus ?? "" }
    /// Lines still to come or under way, in order.
    var upcomingRows: [BoardRow] { rows.filter { $0.phase != .past } }
    var fromCalendar: Bool { agentBoard == nil && calendarBoard != nil }
    /// The calendar answered and holds nothing: a free day, which is worth saying.
    var freeDay: Bool { live == nil && !dayDone && (agenda.map { !$0.isExpired(at: date) } ?? false) }
    var palette: AgentLook.Palette { AgentLook.standard(for: profile).palette }
    private var hour: Int { Calendar.current.component(.hour, from: date) }

    var greeting: String { hour < 5 || hour >= 18 ? "Bonsoir" : hour < 12 ? "Bonjour" : "Bon après-midi" }
    var greetingSymbol: String { hour < 5 || hour >= 20 ? "moon.stars.fill" : hour < 11 ? "sunrise.fill" : hour < 18 ? "sun.max.fill" : "sunset.fill" }

    // What is known with no server at all, so the widget is never blank: where the day stands (6 h to 23 h), the week, the weekend.
    private var clock: Double { Double(hour) + Double(Calendar.current.component(.minute, from: date)) / 60 }
    var dayProgress: Double { min(1, max(0, (clock - 6) / 17)) }
    /// The end of the day while it lasts, for a countdown that runs by itself.
    var dayEnd: Date? { clock >= 6 ? Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: date).flatMap { $0 > date ? $0 : nil } : nil }

    // The weather of the place (nil when the server has none or it is stale), read for the hour this entry stands for.
    var weather: WeatherReport?
    private var sameHour: WeatherReport.Hour? { weather?.hours.first { Calendar.current.isDate($0.at, equalTo: date, toGranularity: .hour) } }
    var temperature: Int? { sameHour?.temp ?? weather?.temp }
    var weatherSymbol: String { sameHour?.symbol ?? weather?.symbol ?? "cloud.fill" }
    /// This hour and the ones after it.
    var comingHours: [WeatherReport.Hour] {
        let start = Calendar.current.dateInterval(of: .hour, for: date)?.start ?? date
        return (weather?.hours ?? []).filter { $0.at >= start }
    }
    var today: WeatherReport.Day? { weather?.days.first { Calendar.current.isDate($0.date, inSameDayAs: date) } }
    var nextDays: [WeatherReport.Day] { (weather?.days ?? []).filter { $0.date > date && !Calendar.current.isDate($0.date, inSameDayAs: date) } }

    /// The lines in the agent's order, each placed in time: done, happening now, the next one, or untimed.
    var rows: [BoardRow] {
        var rows = (live?.items ?? []).enumerated().map { index, item -> BoardRow in
            let when = item.at ?? BoardTime.date(item.time, on: date)
            var phase = BoardRow.Phase.later
            if let when {
                // With an end (a calendar event) it is « now » until then; without, for a quarter of an hour.
                let over = item.until.map { $0 <= date } ?? (when < date.addingTimeInterval(-BoardTime.nowWindow))
                phase = over ? .past : when <= date ? .now : .later
            }
            return BoardRow(index: index, item: item, when: when, phase: phase)
        }
        // The next one is the earliest still to come, whatever order the agent wrote them in.
        let coming = rows.indices.filter { rows[$0].phase == .later && rows[$0].when != nil }
        if !rows.contains(where: { $0.phase == .now }), let first = coming.min(by: { (rows[$0].when ?? .distantFuture) < (rows[$1].when ?? .distantFuture) }) { rows[first].phase = .next }
        return rows
    }
    /// The thing to put forward: what is happening, the next timed line, else the first one.
    var hero: BoardRow? {
        let rows = rows
        return rows.first { $0.phase == .now } ?? rows.first { $0.phase == .next } ?? rows.first { $0.phase != .past } ?? rows.first
    }

    /// A tap opens that agent's chat with the sentence it suggests waiting in the composer (never sent by itself).
    var openURL: URL? {
        if let ask = agentBoard?.ask ?? live?.ask, !ask.isEmpty { return BoardLinks.url("ask", profile: profile, text: ask) }
        return BoardLinks.url("open", profile: profile)
    }
}

enum BoardLinks {
    static func url(_ host: String, profile: String, text: String? = nil) -> URL? {
        var parts = URLComponents(); parts.scheme = "hermesios"; parts.host = host
        var query: [URLQueryItem] = []
        if !profile.isEmpty { query.append(URLQueryItem(name: "profile", value: profile)) }
        if let text { query.append(URLQueryItem(name: "text", value: text)) }
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url
    }
}

// MARK: - Provider

struct BoardProvider: AppIntentTimelineProvider {
    /// A believable day built from now, so the gallery preview always shows a next event and a countdown.
    private static func sample(now: Date = .now) -> AgentBoard {
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"
        func item(_ text: String, _ detail: String, _ icon: String, in hours: Double) -> AgentBoard.Item {
            let at = now.addingTimeInterval(hours * 3600)
            return .init(text: text, detail: detail, time: clock.string(from: at), icon: icon, at: at)
        }
        return AgentBoard(title: "Aujourd’hui", items: [item("Barbier", "Don Barbero", "scissors", in: 0.75), item("Souper chez Julie", "", "fork.knife", in: 4),
                                                        item("Appel du dentiste", "", "cross.case", in: 6)],
                          focus: "Une chose : le souper de ce soir.", expiresAt: now.addingTimeInterval(8 * 3600))
    }

    func placeholder(in context: Context) -> BoardEntry {
        BoardEntry(date: .now, profile: "personnel", agentTitle: "Jarvis", board: Self.sample())
    }

    func snapshot(for configuration: SelectAgentIntent, in context: Context) async -> BoardEntry {
        context.isPreview ? placeholder(in: context) : Saved().entry(configuration, at: .now)
    }

    func timeline(for configuration: SelectAgentIntent, in context: Context) async -> Timeline<BoardEntry> {
        let saved = Saved()                                   // read once: every entry is built from the same data
        let first = saved.entry(configuration, at: .now)
        // The widget moves on by itself: a new « next » when a time passes, « maintenant » then done, the calm state at an
        // expiry, and the greeting at each part of the day.
        var moments: [Date] = []
        for item in (first.board?.items ?? []) + (first.agenda?.items ?? []) {
            if let start = item.at ?? BoardTime.date(item.time, on: .now) {
                if start > .now { moments.append(start) }
                let over = item.until ?? start.addingTimeInterval(BoardTime.nowWindow)
                if over > .now { moments.append(over) }
            }
        }
        for expiry in [first.board?.expiresAt, first.agenda?.expiresAt, saved.boards?.weather?.expiresAt] { if let expiry, expiry > .now { moments.append(expiry) } }
        // Also every two hours: the day's progress ring and the greeting follow the clock.
        for hour in [0, 5, 7, 9, 11, 12, 14, 16, 18, 20, 22, 23] {
            if let next = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime), next < .now.addingTimeInterval(24 * 3600) { moments.append(next) }
        }
        let later = Set(moments).sorted().prefix(20).map { saved.entry(configuration, at: $0) }
        // New data makes the app reload the timelines by itself, so a long wait here costs nothing.
        return Timeline(entries: [first] + later, policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private struct Saved {
        let boards = AgentBoardStore.read()
        let profiles = SharedProfiles.read()

        func entry(_ configuration: SelectAgentIntent, at date: Date) -> BoardEntry {
            let known = boards?.boards ?? [:]
            let name = configuration.agent?.id ?? profiles.first?.name ?? known.keys.sorted().first ?? ""
            let title = profiles.first { $0.name == name }.map { $0.title.isEmpty ? name : $0.title } ?? (name.isEmpty ? "Agent" : name)
            return BoardEntry(date: date, profile: name, agentTitle: title, board: known[name], agenda: boards?.agendas[name],
                              weather: boards?.weather.flatMap { $0.isExpired(at: date) ? nil : $0 })
        }
    }
}

// MARK: - Look

struct BoardBackground: View {
    let profile: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = AgentLook.standard(for: profile).palette
        ZStack {
            WidgetPalette.background(scheme)
            LinearGradient(colors: [palette.main.opacity(scheme == .dark ? 0.24 : 0.13), .clear], startPoint: .topLeading, endPoint: .center)
        }
    }
}

private enum BoardTone {
    /// Dark text on a dark page was the problem: in the dark appearance every colour is its light counterpart (the agent's
    /// palette has a `light` shade for that), in the light appearance the deeper one.
    static func color(_ tone: String, _ palette: AgentLook.Palette, dark: Bool) -> Color {
        switch tone {
        case "positive": dark ? Color(red: 0.42, green: 0.82, blue: 0.56) : Color(red: 0.12, green: 0.5, blue: 0.3)
        case "warning": dark ? Color(red: 1.0, green: 0.72, blue: 0.32) : Color(red: 0.74, green: 0.4, blue: 0.03)
        case "negative": dark ? Color(red: 1.0, green: 0.5, blue: 0.45) : Color(red: 0.75, green: 0.2, blue: 0.16)
        default: dark ? palette.light : palette.main
        }
    }

    /// The agent's own symbol, else one guessed from the words, else a plain dot.
    static func symbol(_ item: AgentBoard.Item) -> String {
        if !item.icon.isEmpty, UIImage(systemName: item.icon) != nil { return item.icon }
        let text = item.text.lowercased()
        let guesses: [(String, [String])] = [
            ("shield.lefthalf.filled", ["quart", "travail", "garde"]), ("scissors", ["barbier", "coiffeur", "coiffure"]),
            ("fork.knife", ["souper", "dîner", "diner", "lunch", "resto", "déjeuner"]), ("cross.case", ["dentiste", "médecin", "medecin", "clinique", "docteur"]),
            ("cloud.sun", ["météo", "meteo", "pluie", "neige"]), ("server.rack", ["serveur", "service", "disque", "sauvegarde"]),
            ("envelope", ["courriel", "mail", "brouillon"]), ("figure.run", ["entraînement", "entrainement", "séance", "course", "gym"]),
            ("phone", ["appel", "téléphone"]), ("calendar", ["rendez", "réunion", "reunion"])]
        return guesses.first { _, words in words.contains { text.contains($0) } }?.0 ?? (item.time.isEmpty ? "circle.fill" : "calendar")
    }
}

private struct Tile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(color.opacity(0.16))
            Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(color)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// Where the day stands: a ring that fills from 6 h to 23 h, the moment's symbol inside.
private struct DayRing: View {
    let progress: Double
    let symbol: String
    let color: Color
    var size: CGFloat = 36
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: size * 0.11)
            Circle().trim(from: 0, to: max(0.02, progress)).stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round)).rotationEffect(.degrees(-90))
            Image(systemName: symbol).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(color)
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// The same progress as a line.
private struct DayBar: View {
    let progress: Double
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color).frame(width: max(6, proxy.size.width * progress))
            }
        }.frame(height: 6).accessibilityHidden(true)
    }
}

/// « Maintenant », or « dans 45 min » counting down by itself.
private struct Countdown: View {
    let row: BoardRow
    let color: Color
    var body: some View {
        switch row.phase {
        case .now: Text("Maintenant").font(.caption2.weight(.bold)).foregroundStyle(color)
        case .next:
            if let when = row.when { (Text("dans ") + Text(when, style: .relative)).font(.caption2.weight(.semibold)).foregroundStyle(color).lineLimit(1) }
        default: EmptyView()
        }
    }
}

// MARK: - Widget

struct BoardWidgetView: View {
    let entry: BoardEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    /// From « xLarge » up, fewer lines: what fits at the default size does not fit then.
    private var bigText: Bool { typeSize >= .xLarge }

    var body: some View {
        content.redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline, .accessoryRectangular: accessory
        case .systemSmall: small
        case .systemMedium: medium
        default: large
        }
    }

    private var dark: Bool { scheme == .dark }
    /// The agent's colour as text and icons: its light shade on the dark page.
    private var accent: Color { dark ? entry.palette.light : entry.palette.main }
    private func color(_ row: BoardRow) -> Color { BoardTone.color(row.item.tone, entry.palette, dark: dark) }
    // Lock Screen
    @ViewBuilder private var accessory: some View {
        let hero = entry.hero
        if family == .accessoryInline {
            if let hero { Text("\(hero.item.time.isEmpty ? "" : "\(hero.item.time) ")\(hero.item.text)") }
            else { Text(entry.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated)).environment(\.locale, Locale(identifier: "fr_CA")) }
        } else {
            HStack(spacing: 8) {
                Image(systemName: hero.map { BoardTone.symbol($0.item) } ?? (entry.weather != nil ? entry.weatherSymbol : entry.greetingSymbol)).font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    if let hero { Text(hero.item.text).font(.caption.weight(.semibold)).lineLimit(1) }
                    else { Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide)).environment(\.locale, Locale(identifier: "fr_CA")).font(.caption.weight(.semibold)).lineLimit(1) }
                    if let hero, let when = hero.when, hero.phase == .next { (Text("dans ") + Text(when, style: .relative)).font(.caption2) }
                    else if !entry.note.isEmpty { Text(entry.note).font(.caption2).lineLimit(1) }
                    else if hero == nil, let weather = entry.weather { Text("\(entry.temperature.map { "\($0)°" } ?? "") \(weather.summary)").font(.caption2).lineLimit(1) }
                    else if hero == nil, let end = entry.dayEnd { (Text("Encore ") + Text(end, style: .relative)).font(.caption2) }
                    else { Text(entry.agentTitle).font(.caption2) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header and pieces

    private func pill(_ label: String, symbol: String, host: String, filled: Bool) -> some View {
        Link(destination: BoardLinks.url(host, profile: entry.profile) ?? URL(string: "hermesios://open")!) {
            Label(label, systemImage: symbol).font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                .foregroundStyle(filled ? (dark ? entry.palette.deep : Color.white) : accent)
                .background(filled ? accent : accent.opacity(0.16), in: Capsule())
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            pill("Parler", symbol: "waveform", host: "voice", filled: true)
            pill("Écrire", symbol: "square.and.pencil", host: "open", filled: false)
        }
    }

    /// A line tapped puts « tell me more » in the composer; it is never sent by the tap.
    private func link<Content: View>(_ row: BoardRow, @ViewBuilder label: () -> Content) -> some View {
        let ask = "Dis-m’en plus sur : \(row.item.time.isEmpty ? "" : "\(row.item.time) ")\(row.item.text)"
        return Link(destination: BoardLinks.url("ask", profile: entry.profile, text: ask) ?? URL(string: "hermesios://open")!, label: label)
    }

    private func focusBox(_ text: String, compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "scope").font(.caption.weight(.bold)).foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                if !compact { Text("À retenir").font(.system(size: 9, weight: .bold)).foregroundStyle(accent).textCase(.uppercase) }
                Text(text).font(.caption.weight(.semibold)).lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(accent.opacity(dark ? 0.16 : 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Weather and the day (what is known when the agent and the calendar have nothing)

    private static let french = Locale(identifier: "fr_CA")

    /// The date as the page's anchor: the weekday small and in colour, the day number large, the month under it.
    private func dateBlock(day: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.date, format: .dateTime.weekday(.wide)).environment(\.locale, Self.french)
                .font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(accent).lineLimit(1)
            Text(entry.date, format: .dateTime.day()).environment(\.locale, Self.french)
                .font(.system(size: day, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1)
            Text(entry.date, format: .dateTime.month(.wide)).environment(\.locale, Self.french)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// « JEUDI 29 OCTOBRE » on one line.
    private func dateCaps(_ font: Font = .caption2) -> some View {
        Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide)).environment(\.locale, Self.french)
            .font(font.weight(.bold)).textCase(.uppercase).foregroundStyle(accent).lineLimit(1).minimumScaleFactor(0.7)
    }

    private func ring(_ size: CGFloat) -> some View { DayRing(progress: entry.dayProgress, symbol: entry.greetingSymbol, color: accent, size: size) }

    private var shortStatus: String { entry.dayDone ? "Journée terminée" : entry.freeDay ? "Agenda libre" : entry.greeting }

    /// « Encore 5 h 12 min » counting down by itself while the day lasts.
    @ViewBuilder private func dayLeft(_ font: Font = .caption2) -> some View {
        if let end = entry.dayEnd { (Text("Encore ") + Text(end, style: .relative)).font(font).foregroundStyle(.secondary).lineLimit(1) }
    }

    private var rainColor: Color { dark ? Color(red: 0.45, green: 0.7, blue: 1.0) : Color(red: 0.12, green: 0.4, blue: 0.85) }

    /// A weather symbol in its own colours (a yellow sun, a grey cloud); an unknown name is a plain cloud.
    private func wx(_ symbol: String, _ size: CGFloat) -> some View {
        Image(systemName: UIImage(systemName: symbol) != nil ? symbol : "cloud.fill").symbolRenderingMode(.multicolor)
            .font(.system(size: size)).accessibilityHidden(true)
    }

    private func degrees(_ value: Int?) -> String { value.map { "\($0)°" } ?? "–" }

    /// « Couvert · ressenti 6° · vent 14 km/h ».
    private func conditions(_ report: WeatherReport, wind: Bool = true) -> String {
        var parts = [report.summary]
        if let feels = report.feels, feels != entry.temperature { parts.append("ressenti \(feels)°") }
        if wind, let speed = report.wind, speed >= 20 { parts.append("vent \(speed) km/h") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// « ↑10° ↓3° » and the chance of rain when it is worth saying.
    private func highLow(_ day: WeatherReport.Day?) -> String {
        guard let day else { return "" }
        return ["↑\(day.high)° ↓\(day.low)°", day.rain >= 30 ? "pluie \(day.rain) %" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The next hours as columns: the hour, the sky, the temperature, and the chance of rain when it matters.
    private func hoursRow(_ count: Int, rain: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(entry.comingHours.prefix(count).enumerated()), id: \.offset) { index, hour in
                VStack(spacing: 2) {
                    Group {
                        if index == 0 { Text("Maint.") } else { Text(hour.at, format: .dateTime.hour()).environment(\.locale, Self.french) }
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    wx(hour.symbol, 15)
                    Text("\(hour.temp)°").font(.caption.weight(.semibold)).monospacedDigit()
                    if rain { Text(hour.rain >= 30 ? "\(hour.rain) %" : " ").font(.system(size: 9, weight: .semibold)).foregroundStyle(rainColor) }
                }.frame(maxWidth: .infinity)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Tomorrow and the days after: the weekday, the sky, the chance of rain, the high and the low.
    private func dayRow(_ day: WeatherReport.Day) -> some View {
        HStack(spacing: 8) {
            Text(day.date, format: .dateTime.weekday(.wide)).environment(\.locale, Self.french).font(.caption.weight(.semibold)).lineLimit(1)
                .frame(width: 66, alignment: .leading)
            wx(day.symbol, 15).frame(width: 22)
            Text(day.rain >= 30 ? "\(day.rain) %" : "").font(.system(size: 10, weight: .semibold)).foregroundStyle(rainColor).frame(width: 34, alignment: .leading)
            Spacer(minLength: 0)
            Text("\(day.low)°").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(day.high)°").font(.caption.weight(.semibold).monospacedDigit()).frame(width: 30, alignment: .trailing)
        }
    }

    /// Sunrise, how far the sun has gone, sunset.
    @ViewBuilder private func sunLine(_ day: WeatherReport.Day) -> some View {
        if let rise = day.sunrise, let set = day.sunset, set > rise {
            HStack(spacing: 8) {
                Image(systemName: "sunrise.fill").font(.caption2).foregroundStyle(accent).accessibilityHidden(true)
                Text(rise, format: .dateTime.hour().minute()).environment(\.locale, Self.french).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                DayBar(progress: min(1, max(0, entry.date.timeIntervalSince(rise) / set.timeIntervalSince(rise))), color: accent)
                Text(set, format: .dateTime.hour().minute()).environment(\.locale, Self.french).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Image(systemName: "sunset.fill").font(.caption2).foregroundStyle(accent).accessibilityHidden(true)
            }
        }
    }

    // MARK: Sizes
    // The system gives a widget its margins: about 126 pt of height for the small and medium ones, 322 for the large one.
    // Nothing is spent on a header; the content spreads over the whole height.

    private func bigTime(_ row: BoardRow) -> some View {
        Text(row.item.time.isEmpty ? "À voir" : row.item.time).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
            .minimumScaleFactor(0.6).lineLimit(1).foregroundStyle(color(row))
    }

    /// « Maintenant », « dans 45 min », else the place.
    @ViewBuilder private func sub(_ row: BoardRow) -> some View {
        if row.phase == .now || row.phase == .next { Countdown(row: row, color: color(row)) }
        else if !row.item.detail.isEmpty { Text(row.item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hero = entry.hero {
                ViewThatFits(in: .vertical) {
                    smallHero(hero, showNext: !bigText)
                    smallHero(hero, showNext: false)
                }
            } else if let weather = entry.weather {
                smallWeather(weather)
            } else {
                smallCalm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The date and the ring across the top, the weather under them.
    private func smallWeather(_ weather: WeatherReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.date, format: .dateTime.weekday(.wide)).environment(\.locale, Self.french)
                        .font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(accent).lineLimit(1)
                    Text(entry.date, format: .dateTime.day().month(.abbreviated)).environment(\.locale, Self.french)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                ring(30)
            }
            Spacer(minLength: 2)
            HStack(spacing: 6) {
                wx(entry.weatherSymbol, 30)
                Text(degrees(entry.temperature)).font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(weather.summary).font(.caption.weight(.semibold)).lineLimit(1)
            if entry.note.isEmpty {
                Text(highLow(entry.today)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "scope").font(.system(size: 9, weight: .bold)).foregroundStyle(accent).padding(.top, 1).accessibilityHidden(true)
                    Text(entry.note).font(.caption2.weight(.semibold)).lineLimit(2)
                }
            }
        }
    }

    /// No weather and nothing on the board: the date and where the day stands.
    private var smallCalm: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                dateBlock(day: 34)
                Spacer(minLength: 4)
                ring(34)
            }
            Spacer(minLength: 4)
            Text(shortStatus).font(.caption.weight(.semibold)).foregroundStyle(accent).lineLimit(1)
            dayLeft().padding(.top, 1)
        }
    }

    private func smallHero(_ hero: BoardRow, showNext: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                bigTime(hero)
                Spacer(minLength: 4)
                Tile(symbol: BoardTone.symbol(hero.item), color: color(hero), size: 30)
            }
            Spacer(minLength: 4)
            Text(hero.item.text).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            sub(hero).padding(.top, 2)
            if showNext, let after = entry.rows.first(where: { $0.id != hero.id && $0.phase != .past }) {
                Text("Ensuite · \(after.item.time.isEmpty ? "" : "\(after.item.time) ")\(after.item.text)").font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).padding(.top, 5)
            }
        }
    }

    private var medium: some View {
        Group {
            if let weather = entry.weather, !entry.upcomingRows.isEmpty || !entry.note.isEmpty {
                mediumSplit(weather)
            } else if entry.live != nil, let hero = entry.hero {
                mediumBoard(hero)
            } else if let weather = entry.weather {
                mediumWeather(weather)
            } else {
                mediumCalm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func mediumBoard(_ hero: BoardRow) -> some View {
        let rest = entry.rows.filter { $0.id != hero.id }
        let focus = entry.note
        return HStack(alignment: .top, spacing: 12) {
            link(hero) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        bigTime(hero)
                        Spacer(minLength: 4)
                        Tile(symbol: BoardTone.symbol(hero.item), color: color(hero), size: 30)
                    }
                    Spacer(minLength: 4)
                    Text(hero.item.text).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    sub(hero).padding(.top, 2)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }.frame(width: 138)
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rest.prefix(bigText ? 2 : focus.isEmpty ? 4 : 3))) { row in
                    link(row) { compactRow(row) }.frame(minHeight: 26, maxHeight: 40)
                }
                if rest.isEmpty && focus.isEmpty { Text("C’est tout pour l’instant.").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if !focus.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "scope").font(.caption2.weight(.bold)).foregroundStyle(accent).accessibilityHidden(true)
                        Text(focus).font(.caption2.weight(.semibold)).lineLimit(2)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Half weather, half agenda: the weather now on the left, what is coming (and the agent's note) on the right.
    private func mediumSplit(_ weather: WeatherReport) -> some View {
        let rows = Array(entry.upcomingRows.prefix(bigText ? 2 : entry.note.isEmpty ? 4 : 3))
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                dateCaps()
                Spacer(minLength: 2)
                HStack(spacing: 6) {
                    wx(entry.weatherSymbol, 26)
                    Text(degrees(entry.temperature)).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                Text(weather.summary).font(.caption.weight(.semibold)).lineLimit(1)
                Text(highLow(entry.today)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                dayLeft()
            }.frame(width: 128, alignment: .leading).frame(maxHeight: .infinity, alignment: .topLeading)
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in link(row) { compactRow(row) }.frame(minHeight: 26, maxHeight: 40) }
                if rows.isEmpty { Text(agendaEmptyText).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if !entry.note.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "scope").font(.caption2.weight(.bold)).foregroundStyle(accent).accessibilityHidden(true)
                        Text(entry.note).font(.caption2.weight(.semibold)).lineLimit(2)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var agendaEmptyText: String { entry.dayDone ? "Journée terminée" : entry.freeDay ? "Rien à l’agenda aujourd’hui" : "Rien à l’affiche" }

    /// The weather now at the top left, the day's ring at the top right, the next hours across the bottom.
    private func mediumWeather(_ weather: WeatherReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    dateCaps()
                    HStack(spacing: 8) {
                        wx(entry.weatherSymbol, 28)
                        Text(degrees(entry.temperature)).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(weather.summary).font(.caption.weight(.semibold)).lineLimit(1)
                            Text(highLow(entry.today)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                }
                Spacer(minLength: 6)
                ring(34)
            }
            Spacer(minLength: 4)
            hoursRow(bigText ? 4 : 6, rain: false)
        }
    }

    /// No weather and nothing on the board.
    private var mediumCalm: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    dateBlock(day: 34)
                    Spacer(minLength: 4)
                    ring(32)
                }
                Spacer(minLength: 4)
                Text(shortStatus).font(.caption.weight(.semibold)).foregroundStyle(accent).lineLimit(1)
            }.frame(width: 138, alignment: .leading).frame(maxHeight: .infinity, alignment: .topLeading)
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 6) {
                Text("Journée").font(.system(size: 9, weight: .bold)).textCase(.uppercase).foregroundStyle(accent)
                dayLeft(.title3.weight(.bold)).foregroundStyle(.primary)
                DayBar(progress: entry.dayProgress, color: accent)
                HStack {
                    ForEach(["6 h", "12 h", "18 h", "23 h"], id: \.self) { label in
                        Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                        if label != "23 h" { Spacer() }
                    }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let weather = entry.weather {
                largeSplit(weather)
            } else if entry.live != nil, entry.hero != nil {
                largeBoard
            } else {
                largeCalm
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var largeBoard: some View {
        let rows = Array(entry.rows.prefix(bigText ? 3 : 5))
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.live?.title.isEmpty == false ? entry.live?.title ?? "" : "Aujourd’hui").font(.caption.weight(.bold)).textCase(.uppercase)
                    .foregroundStyle(accent).lineLimit(1)
                Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide)).environment(\.locale, Self.french)
                    .font(.system(size: 19, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 8)
            if entry.weather != nil {
                HStack(spacing: 4) {
                    wx(entry.weatherSymbol, 17)
                    Text(degrees(entry.temperature)).font(.subheadline.weight(.bold)).monospacedDigit()
                }
            }
            ring(34)
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                link(row) { timelineRow(row, last: index == rows.count - 1) }.frame(minHeight: 40, maxHeight: 66)
            }
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity, alignment: .top)
        if !entry.note.isEmpty { focusBox(entry.note, compact: bigText) }
        actions
    }

    /// Half weather, half agenda. Top: the weather now and the next hours, the day's ring at the right. Bottom: what is coming
    /// (the agent's lines, else the calendar's), the agent's « À retenir » when it has one, Parler and Écrire.
    @ViewBuilder private func largeSplit(_ weather: WeatherReport) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                dateCaps(.caption)
                HStack(spacing: 8) {
                    wx(entry.weatherSymbol, 32)
                    Text(degrees(entry.temperature)).font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit().lineLimit(1)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(weather.summary).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(highLow(entry.today)).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                ring(40)
                dayLeft()
            }
        }
        hoursRow(6, rain: true)
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        let rows = Array(entry.upcomingRows.prefix(bigText ? 2 : entry.note.isEmpty ? 4 : 3))
        HStack(spacing: 5) {
            Image(systemName: "calendar").font(.system(size: 10, weight: .bold)).foregroundStyle(accent).accessibilityHidden(true)
            Text(entry.live?.title.isEmpty == false ? entry.live?.title ?? "" : "Aujourd’hui").font(.system(size: 10, weight: .bold)).textCase(.uppercase)
                .foregroundStyle(accent).lineLimit(1)
        }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                link(row) { timelineRow(row, last: index == rows.count - 1) }.frame(minHeight: 34, maxHeight: 56)
            }
            if rows.isEmpty {
                HStack(spacing: 8) {
                    Tile(symbol: entry.dayDone ? "checkmark" : "calendar", color: accent, size: 30)
                    Text(agendaEmptyText).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.frame(maxHeight: .infinity)
            }
            Spacer(minLength: 0)
        }.frame(maxHeight: .infinity, alignment: .top)
        if !entry.note.isEmpty { focusBox(entry.note, compact: bigText) }
        actions
    }

    /// No weather and nothing on the board: the date, the ring and where the day stands.
    @ViewBuilder private var largeCalm: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide)).environment(\.locale, Self.french)
                    .font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                Text(shortStatus).font(.subheadline.weight(.semibold)).foregroundStyle(accent).lineLimit(1)
            }
            Spacer(minLength: 8)
            ring(52)
        }
        card {
            VStack(spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Journée").font(.system(size: 9, weight: .bold)).textCase(.uppercase).foregroundStyle(accent)
                    Spacer()
                    dayLeft(.caption2.weight(.medium))
                }
                DayBar(progress: entry.dayProgress, color: accent)
                HStack {
                    ForEach(["6 h", "12 h", "18 h", "23 h"], id: \.self) { label in
                        Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                        if label != "23 h" { Spacer() }
                    }
                }
            }
        }
        Spacer(minLength: 0)
        actions
    }

    // MARK: Rows

    private func compactRow(_ row: BoardRow) -> some View {
        HStack(spacing: 7) {
            Tile(symbol: BoardTone.symbol(row.item), color: color(row), size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.item.text).font(.caption.weight(.semibold)).lineLimit(1)
                if !row.item.time.isEmpty { Text(row.item.time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
            }
            .opacity(row.phase == .past ? 0.5 : 1)
            Spacer(minLength: 0)
            if row.phase == .past { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
    }

    /// A step of the day: its tile, a line down to the next one, the title and detail, the time or the countdown.
    private func timelineRow(_ row: BoardRow, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Tile(symbol: row.phase == .past ? "checkmark" : BoardTone.symbol(row.item), color: row.phase == .past ? .secondary : color(row), size: 30)
                if !last { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1.5).frame(maxHeight: .infinity).padding(.vertical, 2) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.item.text).font(.subheadline.weight(row.phase == .next || row.phase == .now ? .bold : .medium)).lineLimit(1)
                if !row.item.detail.isEmpty { Text(row.item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .padding(.top, 3).padding(.bottom, last ? 0 : 6)
            .opacity(row.phase == .past ? 0.5 : 1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                if !row.item.time.isEmpty { Text(row.item.time).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(row.phase == .past ? Color.secondary : color(row)) }
                Countdown(row: row, color: color(row))
            }.padding(.top, 3)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
