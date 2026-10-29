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
    let item: AgentBoard.Item
    let when: Date?
    var phase: Phase
    var id: String { item.id }
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

    private var agentBoard: AgentBoard? { board.flatMap { $0.isEmpty || $0.isExpired(at: date) ? nil : $0 } }
    private var calendarBoard: AgentBoard? { agenda.flatMap { $0.isEmpty || $0.isExpired(at: date) ? nil : $0 } }
    /// What to draw: the agent's own board, else the calendar's next events, else nothing (the empty state).
    var live: AgentBoard? { agentBoard ?? calendarBoard }
    var fromCalendar: Bool { agentBoard == nil && calendarBoard != nil }
    /// The calendar answered and holds nothing: a free day, which is worth saying.
    var freeDay: Bool { live == nil && (agenda.map { !$0.isExpired(at: date) } ?? false) }
    var palette: AgentLook.Palette { AgentLook.standard(for: profile).palette }
    private var hour: Int { Calendar.current.component(.hour, from: date) }
    private var isOps: Bool { ["noriven", "default", "hermes"].contains(profile.lowercased()) }

    var greeting: String { hour < 5 || hour >= 18 ? "Bonsoir" : hour < 12 ? "Bonjour" : "Bon après-midi" }
    var greetingSymbol: String { hour < 5 || hour >= 20 ? "moon.stars.fill" : hour < 11 ? "sunrise.fill" : hour < 18 ? "sun.max.fill" : "sunset.fill" }

    /// What to ask when there is nothing on the board, by the hour and by agent. A tap fills the composer; it never sends.
    var suggestions: [Suggestion] {
        if isOps { return [Suggestion("État du serveur", "server.rack"), Suggestion("Les chiffres de Noriven ce mois-ci", "chart.line.uptrend.xyaxis"), Suggestion("Quoi de neuf ?", "newspaper")] }
        switch hour {
        case 5..<11: return [Suggestion("Résume ma journée", "sun.max"), Suggestion("Quelle météo aujourd’hui ?", "cloud.sun"), Suggestion("Qu’y a-t-il dans mes courriels ?", "envelope")]
        case 11..<18: return [Suggestion("Qu’est-ce qu’il me reste aujourd’hui ?", "checklist"), Suggestion("Quoi de neuf ?", "newspaper"), Suggestion("Quelle météo ce soir ?", "cloud.moon")]
        default: return [Suggestion("Qu’est-ce qui m’attend demain ?", "calendar"), Suggestion("Fais le point sur ma journée", "moon.stars"), Suggestion("Quelles nouvelles ce soir ?", "newspaper")]
        }
    }

    /// The lines in the agent's order, each placed in time: done, happening now, the next one, or untimed.
    var rows: [BoardRow] {
        var rows = (live?.items ?? []).map { item -> BoardRow in
            let when = item.at ?? BoardTime.date(item.time, on: date)
            let phase: BoardRow.Phase = when.map { $0 < date.addingTimeInterval(-BoardTime.nowWindow) ? .past : $0 <= date ? .now : .later } ?? .later
            return BoardRow(item: item, when: when, phase: phase)
        }
        if let first = rows.firstIndex(where: { $0.when != nil && $0.phase == .later }), !rows.contains(where: { $0.phase == .now }) { rows[first].phase = .next }
        return rows
    }
    /// The thing to put forward: what is happening, the next timed line, else the first one.
    var hero: BoardRow? {
        let rows = rows
        return rows.first { $0.phase == .now } ?? rows.first { $0.phase == .next } ?? rows.first { $0.phase != .past } ?? rows.first
    }

    /// A tap opens that agent's chat with the sentence it suggests waiting in the composer (never sent by itself).
    var openURL: URL? {
        if let ask = live?.ask, !ask.isEmpty { return BoardLinks.url("ask", profile: profile, text: ask) }
        if live == nil, let first = suggestions.first { return BoardLinks.url("ask", profile: profile, text: first.text) }
        return BoardLinks.url("open", profile: profile)
    }
}

struct Suggestion: Identifiable {
    let text: String, symbol: String
    var id: String { text }
    init(_ text: String, _ symbol: String) { self.text = text; self.symbol = symbol }
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
    private static let sample = AgentBoard(title: "Aujourd’hui", items: [
        .init(text: "Quart de jour", detail: "jusqu’à 15 h", time: "06:45", icon: "shield"), .init(text: "Barbier", detail: "Don Barbero", time: "13:45", icon: "scissors"),
        .init(text: "Souper chez Julie", time: "18:30", icon: "fork.knife")], focus: "Une chose : le souper de ce soir.")

    func placeholder(in context: Context) -> BoardEntry {
        BoardEntry(date: .now, profile: "personnel", agentTitle: "Jarvis", board: Self.sample, isPlaceholder: true)
    }

    func snapshot(for configuration: SelectAgentIntent, in context: Context) async -> BoardEntry {
        context.isPreview ? placeholder(in: context) : entry(for: configuration, at: .now)
    }

    func timeline(for configuration: SelectAgentIntent, in context: Context) async -> Timeline<BoardEntry> {
        let first = entry(for: configuration, at: .now)
        // The widget moves on by itself: a new « next » when a time passes, « maintenant » then done, the calm state at expiry.
        var moments: [Date] = []
        for item in first.board?.items ?? [] {
            if let when = item.at ?? BoardTime.date(item.time, on: .now), when > .now { moments += [when, when.addingTimeInterval(BoardTime.nowWindow)] }
        }
        for item in first.agenda?.items ?? [] {
            if let when = item.at ?? BoardTime.date(item.time, on: .now), when > .now { moments += [when, when.addingTimeInterval(BoardTime.nowWindow)] }
        }
        for expiry in [first.board?.expiresAt, first.agenda?.expiresAt] { if let expiry, expiry > .now { moments.append(expiry) } }
        let later = Set(moments).sorted().prefix(12).map { entry(for: configuration, at: $0) }
        return Timeline(entries: [first] + later, policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SelectAgentIntent, at date: Date) -> BoardEntry {
        let saved = AgentBoardStore.read(), boards = saved?.boards ?? [:], profiles = SharedProfiles.read()
        let name = configuration.agent?.id ?? profiles.first?.name ?? boards.keys.sorted().first ?? ""
        let title = profiles.first { $0.name == name }.map { $0.title.isEmpty ? name : $0.title } ?? (name.isEmpty ? "Agent" : name)
        return BoardEntry(date: date, profile: name, agentTitle: title, board: boards[name], agenda: saved?.agendas[name])
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
    static func color(_ tone: String, _ palette: AgentLook.Palette) -> Color {
        switch tone {
        case "positive": Color(red: 0.2, green: 0.62, blue: 0.4)
        case "warning": Color(red: 0.86, green: 0.52, blue: 0.1)
        case "negative": Color(red: 0.8, green: 0.25, blue: 0.2)
        default: palette.main
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
        }.frame(width: size, height: size)
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

    private func color(_ row: BoardRow) -> Color { BoardTone.color(row.item.tone, entry.palette) }
    private var palette: AgentLook.Palette { entry.palette }
    // Lock Screen
    @ViewBuilder private var accessory: some View {
        let hero = entry.hero
        if family == .accessoryInline {
            Text(hero.map { "\($0.item.time.isEmpty ? "" : "\($0.item.time) ")\($0.item.text)" } ?? entry.agentTitle)
        } else {
            HStack(spacing: 8) {
                Image(systemName: hero.map { BoardTone.symbol($0.item) } ?? "sparkles").font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(hero?.item.text ?? "Rien de particulier").font(.caption.weight(.semibold)).lineLimit(1)
                    if let hero, let when = hero.when, hero.phase == .next { (Text("dans ") + Text(when, style: .relative)).font(.caption2) }
                    else if let focus = entry.live?.focus, !focus.isEmpty { Text(focus).font(.caption2).lineLimit(1) }
                    else { Text(entry.agentTitle).font(.caption2) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header and pieces

    private func pill(_ label: String, symbol: String, host: String, filled: Bool) -> some View {
        Link(destination: BoardLinks.url(host, profile: entry.profile) ?? URL(string: "hermesios://open")!) {
            Label(label, systemImage: symbol).font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(filled ? Color.white : palette.main).background(filled ? palette.main : palette.main.opacity(0.14), in: Capsule())
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
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
            Image(systemName: "scope").font(.caption.weight(.bold)).foregroundStyle(palette.main)
            VStack(alignment: .leading, spacing: 1) {
                if !compact { Text("À retenir").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.main).textCase(.uppercase) }
                Text(text).font(.caption.weight(.semibold)).lineLimit(compact ? 1 : 2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(palette.main.opacity(0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Empty state (nothing from the agent, nothing from the calendar)

    private var dateLine: some View {
        Text(entry.date, format: .dateTime.weekday(.wide).day().month(.wide)).environment(\.locale, Locale(identifier: "fr_CA"))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private var statusLine: String { entry.freeDay ? "Rien à l’agenda aujourd’hui" : "Prêt quand vous l’êtes" }

    /// A suggestion: tapping it puts the sentence in the composer.
    private func suggestionRow(_ suggestion: Suggestion, size: CGFloat, font: Font) -> some View {
        Link(destination: BoardLinks.url("ask", profile: entry.profile, text: suggestion.text) ?? URL(string: "hermesios://open")!) {
            HStack(spacing: 8) {
                Tile(symbol: suggestion.symbol, color: palette.main, size: size)
                Text(suggestion.text).font(font).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private var voiceRow: some View {
        Link(destination: BoardLinks.url("voice", profile: entry.profile) ?? URL(string: "hermesios://voice")!) {
            HStack(spacing: 8) {
                Tile(symbol: "waveform", color: palette.main, size: 22)
                Text("Parler à \(entry.agentTitle)").font(.caption.weight(.semibold)).foregroundStyle(palette.main).lineLimit(1)
                Spacer(minLength: 0)
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
                HStack(alignment: .top) {
                    bigTime(hero)
                    Spacer(minLength: 4)
                    Tile(symbol: BoardTone.symbol(hero.item), color: color(hero), size: 30)
                }
                Spacer(minLength: 4)
                Text(hero.item.text).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                sub(hero).padding(.top, 2)
                if let after = entry.rows.first(where: { $0.id != hero.id && $0.phase != .past }) {
                    Text("Ensuite · \(after.item.time.isEmpty ? "" : "\(after.item.time) ")\(after.item.text)").font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).padding(.top, 5)
                }
            } else {
                Image(systemName: entry.greetingSymbol).font(.title).foregroundStyle(palette.main)
                Spacer(minLength: 4)
                Text(entry.greeting).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                dateLine
                Text(entry.freeDay ? statusLine : "Touchez : \(entry.suggestions.first?.text ?? "")").font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.main).lineLimit(2).padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        Group {
            if entry.live != nil, let hero = entry.hero {
                let rest = entry.rows.filter { $0.id != hero.id }
                let focus = entry.live?.focus ?? ""
                HStack(alignment: .top, spacing: 12) {
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
                        ForEach(Array(rest.prefix(focus.isEmpty ? 4 : 3))) { row in
                            link(row) { compactRow(row) }.frame(minHeight: 26, maxHeight: 40)
                        }
                        if rest.isEmpty && focus.isEmpty { Text("C’est tout pour l’instant.").font(.caption).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                        if !focus.isEmpty {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "scope").font(.caption2.weight(.bold)).foregroundStyle(palette.main)
                                Text(focus).font(.caption2.weight(.semibold)).lineLimit(2)
                            }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Image(systemName: entry.greetingSymbol).font(.title2).foregroundStyle(palette.main)
                        Spacer(minLength: 4)
                        Text(entry.greeting).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                        dateLine
                        Text(statusLine).font(.caption2.weight(.semibold)).foregroundStyle(palette.main).lineLimit(2).padding(.top, 4)
                    }.frame(width: 128, alignment: .leading).frame(maxHeight: .infinity, alignment: .topLeading)
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.1)).frame(width: 1).frame(maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entry.suggestions.prefix(2))) { suggestionRow($0, size: 26, font: .caption.weight(.medium)).frame(maxHeight: .infinity) }
                        voiceRow.frame(maxHeight: .infinity)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entry.live != nil, entry.hero != nil {
                let rows = Array(entry.rows.prefix(6))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        link(row) { timelineRow(row, last: index == rows.count - 1) }.frame(minHeight: 40, maxHeight: 66)
                    }
                    Spacer(minLength: 0)
                }.frame(maxHeight: .infinity, alignment: .top)
                if let focus = entry.live?.focus, !focus.isEmpty { focusBox(focus, compact: false) }
                actions
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: entry.greetingSymbol).font(.largeTitle).foregroundStyle(palette.main)
                    Text(entry.greeting).font(.system(size: 36, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).padding(.top, 4)
                    dateLine.font(.subheadline)
                    Text(statusLine).font(.subheadline.weight(.semibold)).foregroundStyle(palette.main).padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entry.suggestions) { suggestionRow($0, size: 32, font: .subheadline.weight(.medium)).frame(maxHeight: .infinity) }
                }.frame(maxHeight: .infinity)
                actions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            if row.phase == .past { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) }
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
