import AppIntents
import SwiftUI
import WidgetKit

/// The agent's own board: what it judged worth showing right now (the next appointment, a shift, one thing to keep in
/// mind). It decides when to update it and never notifies for it; the widget only draws what the app last saved.
struct AgentBoardWidget: Widget {
    static let kind = "AgentBoardWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectAgentIntent.self, provider: BoardProvider()) { entry in
            BoardWidgetView(entry: entry)
                .widgetURL(entry.openURL)
                .containerBackground(for: .widget) { WidgetBackground() }
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

struct BoardEntry: TimelineEntry {
    let date: Date
    let profile: String
    let agentTitle: String
    /// nil: this agent has not published anything.
    let board: AgentBoard?
    var isPlaceholder = false

    /// The board to draw: absent, empty or out of date means the calm state.
    var live: AgentBoard? { board.flatMap { $0.isEmpty || $0.isExpired(at: date) ? nil : $0 } }
    /// A tap opens that agent's chat with the sentence it suggests waiting in the composer (never sent by itself).
    var openURL: URL? {
        var parts = URLComponents(); parts.scheme = "hermesios"
        if let ask = live?.ask, !ask.isEmpty { parts.host = "ask"; parts.queryItems = [URLQueryItem(name: "profile", value: profile), URLQueryItem(name: "text", value: ask)] }
        else { parts.host = "open"; parts.queryItems = profile.isEmpty ? nil : [URLQueryItem(name: "profile", value: profile)] }
        return parts.url
    }
}

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
        var entries = [first]
        // At its expiry the board gives way to the calm state without waiting for the next refresh.
        if let expiry = first.board?.expiresAt, expiry > .now { entries.append(entry(for: configuration, at: expiry)) }
        return Timeline(entries: entries, policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SelectAgentIntent, at date: Date) -> BoardEntry {
        let boards = AgentBoardStore.read()?.boards ?? [:], profiles = SharedProfiles.read()
        let name = configuration.agent?.id ?? profiles.first?.name ?? boards.keys.sorted().first ?? ""
        let title = profiles.first { $0.name == name }.map { $0.title.isEmpty ? name : $0.title } ?? (name.isEmpty ? "Agent" : name)
        return BoardEntry(date: date, profile: name, agentTitle: title, board: boards[name])
    }
}

private enum BoardTone {
    static func color(_ tone: String) -> Color {
        switch tone {
        case "positive": Color(red: 0.2, green: 0.62, blue: 0.4)
        case "warning": Color(red: 0.86, green: 0.52, blue: 0.1)
        case "negative": Color(red: 0.8, green: 0.25, blue: 0.2)
        default: WidgetPalette.accent
        }
    }
}

struct BoardWidgetView: View {
    let entry: BoardEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content.redacted(reason: entry.isPlaceholder ? .placeholder : [])
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Text(entry.live?.items.first.map { "\($0.time.isEmpty ? "" : "\($0.time) ") \($0.text)" } ?? entry.live?.focus.nilIfEmpty ?? entry.agentTitle)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.live?.title.nilIfEmpty ?? entry.agentTitle).font(.caption.weight(.semibold))
                if let live = entry.live {
                    ForEach(live.items.prefix(2)) { Text("\($0.time.isEmpty ? "" : "\($0.time) ")\($0.text)").lineLimit(1) }
                    if live.items.isEmpty { Text(live.focus).lineLimit(2) }
                } else { Text("Rien de particulier") }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                header
                if let live = entry.live { lines(live) } else { calm }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            OrbView(phase: .idle, animated: false, look: .standard(for: entry.profile), compact: true).frame(width: 22, height: 22)
            Text(entry.live?.title.nilIfEmpty ?? entry.agentTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if let updated = entry.live?.updatedAt {
                Text(updated, style: .relative).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var calm: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Rien de particulier").font(.callout.weight(.medium))
            Text("\(entry.agentTitle) vous le dira quand il y aura quelque chose.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func lines(_ board: AgentBoard) -> some View {
        let count = family == .systemSmall ? 2 : family == .systemMedium ? 3 : 5
        VStack(alignment: .leading, spacing: 7) {
            ForEach(board.items.prefix(count)) { item in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(BoardTone.color(item.tone)).frame(width: 6, height: 6).padding(.top, 5)
                    if !item.time.isEmpty && family != .systemSmall {
                        Text(item.time).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(BoardTone.color(item.tone))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.text).font(family == .systemSmall ? .caption.weight(.medium) : .subheadline.weight(.medium)).lineLimit(family == .systemSmall ? 2 : 1)
                        if !item.detail.isEmpty && family != .systemSmall { Text(item.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            if !board.focus.isEmpty && family != .systemSmall {
                Text(board.focus).font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.accent).lineLimit(2).padding(.top, 2)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
