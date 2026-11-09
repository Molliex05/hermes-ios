import Foundation

/// The cards to show on the voice screen: those of the newest agent reply given during the call. The voice reads only the
/// text; a card (an event, the weather, places, the news) stays on screen to look at while talking, until a newer reply
/// brings its own. Replies from before the call are recognised by their text, which survives the history being reloaded
/// (ids may not).
public enum VoiceCards {
    public struct Card: Equatable, Sendable { public let json: String, complete: Bool }
    public struct Shown: Equatable, Sendable { public let messageID: String, cards: [Card] }

    public static func latest(in messages: [ChatMessage], before: Set<String>) -> Shown? {
        for message in messages.reversed() where message.role == "assistant" && !before.contains(message.text) {
            guard message.text.contains("```") || message.text.contains("~~~") else { continue }
            let cards = ChatMarkdown.parse(message.text).compactMap { block -> Card? in
                if case .card(let json, let complete) = block { Card(json: json, complete: complete || !message.streaming) } else { nil }
            }
            if !cards.isEmpty { return Shown(messageID: message.id, cards: Array(cards.prefix(3))) }
        }
        return nil
    }

    /// What was already in the conversation when the call started.
    public static func snapshot(_ messages: [ChatMessage]) -> Set<String> {
        Set(messages.filter { $0.role == "assistant" }.map(\.text))
    }
}

extension VoiceCards {
    /// The first readable card of the newest reply given during the call, made small for the call's Live Activity.
    public static func glance(in messages: [ChatMessage], before: Set<String>) -> CardGlance? {
        guard let shown = latest(in: messages, before: before) else { return nil }
        for card in shown.cards where card.complete {
            if let parsed = ChatCard.parse(card.json), let glance = CardGlance(parsed) { return glance }
        }
        return nil
    }
}

extension CardGlance {
    init?(_ card: ChatCard) {
        func degrees(_ value: Double?) -> String { value.map { String(format: "%.0f°", $0) } ?? "" }
        func joined(_ parts: String...) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }
        switch card {
        case .weather(let weather):
            let today = weather.days.first.map { joined($0.high.map { "Max \(degrees($0))" } ?? "", $0.low.map { "Min \(degrees($0))" } ?? "") } ?? ""
            let days = weather.days.prefix(3).map {
                Row(symbol: Self.weatherSymbol($0.condition), label: $0.label, detail: $0.condition,
                    value: [degrees($0.high), degrees($0.low)].filter { !$0.isEmpty }.joined(separator: " / "))
            }
            self.init(symbol: Self.weatherSymbol(weather.condition), title: weather.place.isEmpty ? "Météo" : weather.place,
                      value: degrees(weather.temperature), lines: [weather.condition, today], rows: days)
        case .event(let event):
            let when = Self.when(event.start, end: event.end)
            self.init(symbol: "calendar", title: event.title, lines: [when, event.location],
                      rows: [Row(symbol: "clock", label: when), Row(symbol: "mappin.and.ellipse", label: event.location)])
        case .agenda(let title, let slots):
            self.init(symbol: "calendar", title: title.isEmpty ? "Agenda" : title, value: "\(slots.count)",
                      lines: slots.prefix(2).map { joined(Self.when($0.start), $0.title) },
                      rows: slots.prefix(3).map { Row(label: Self.when($0.start), detail: $0.title, value: $0.location) })
        case .email(let message):
            self.init(symbol: "envelope.fill", title: message.email.subject, value: message.due,
                      lines: [message.email.sender.label, message.points.first ?? message.email.summary])
        case .emails(let inbox):
            self.init(symbol: "tray.full.fill", title: inbox.title.isEmpty ? "Courriels" : inbox.title,
                      value: inbox.unread > 0 ? "\(inbox.unread) non lus" : "\(inbox.items.count)",
                      lines: inbox.items.prefix(2).map { "\($0.sender.label) — \($0.subject)" },
                      rows: inbox.items.prefix(3).map {
                          Row(symbol: $0.unread ? "circle.fill" : "", label: $0.sender.label, detail: $0.subject,
                              value: $0.date.map { Self.when($0) } ?? "")
                      })
        case .triage(let triage):
            self.init(symbol: "tray.and.arrow.down.fill", title: triage.title.isEmpty ? "Tri des courriels" : triage.title,
                      value: "\(triage.pendingCount)", lines: ["\(triage.archived) archivés · \(triage.drafts) brouillons",
                                                               triage.pending.first.map { "\($0.sender.label) — \($0.subject)" } ?? ""])
        case .draft(let draft):
            self.init(symbol: "square.and.pencil", title: draft.subject.isEmpty ? "Brouillon" : draft.subject, lines: ["À \(draft.to)"])
        case .metrics(let title, let metrics):
            self.init(symbol: "chart.bar.fill", title: title.isEmpty ? (metrics.first?.label ?? "Chiffres") : title, value: metrics.first?.value ?? "",
                      lines: metrics.dropFirst(title.isEmpty ? 1 : 0).prefix(2).map { joined($0.label, $0.value, $0.delta) },
                      rows: metrics.prefix(3).map {
                          let arrow = switch $0.trend { case .up: "arrow.up.right"; case .down: "arrow.down.right"; case .flat: "arrow.right" }
                          return Row(symbol: arrow, label: $0.label, detail: $0.delta, value: $0.value)
                      })
        case .chart(let chart):
            self.init(symbol: "chart.xyaxis.line", title: chart.title, value: chart.value, lines: [chart.delta])
        case .progress(let title, let goals):
            let first = goals.first
            self.init(symbol: "target", title: title.isEmpty ? (first?.label ?? "Objectifs") : title,
                      value: first.map { "\(Int(($0.progress * 100).rounded())) %" } ?? "",
                      lines: goals.prefix(2).map { "\($0.label) : \(Self.number($0.value)) / \(Self.number($0.goal)) \($0.unit)" },
                      rows: goals.prefix(3).map {
                          Row(label: $0.label, value: "\(Self.number($0.value)) / \(Self.number($0.goal)) \($0.unit)", progress: $0.progress)
                      })
        case .list(let title, let rows, let total):
            self.init(symbol: "list.bullet", title: title.isEmpty ? "Liste" : title, value: total?.value ?? "",
                      lines: rows.prefix(2).map { joined($0.title, $0.value) },
                      rows: rows.prefix(3).map { Row(label: $0.title, detail: $0.subtitle, value: $0.value) })
        case .places(let title, let places):
            self.init(symbol: "mappin.and.ellipse", title: title.isEmpty ? "Lieux" : title, value: "\(places.count)",
                      lines: places.prefix(2).map { joined($0.name, $0.address) })
        case .route(let route):
            self.init(symbol: "map.fill", title: route.title, value: route.stats.first?.value ?? "",
                      lines: route.stats.dropFirst().prefix(2).map { joined($0.label, $0.value) })
        case .status(let status):
            let symbol = switch status.state {
            case .ok: "checkmark.seal.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .down: "xmark.octagon.fill"
            case .unknown: "questionmark.circle.fill"
            }
            self.init(symbol: symbol, title: status.title, lines: [status.subtitle] + status.items.filter { $0.state != .ok }.prefix(1).map { joined($0.name, $0.detail) })
        case .workout(let workout):
            self.init(symbol: "figure.strengthtraining.traditional", title: workout.title, value: workout.stats.first?.value ?? "",
                      lines: [workout.subtitle] + workout.exercises.prefix(1).map { joined($0.name, $0.sets, $0.weight) })
        case .news(let title, let articles):
            self.init(symbol: "newspaper.fill", title: title.isEmpty ? "Nouvelles" : title, lines: articles.prefix(2).map(\.title))
        case .brief(let brief):
            self.init(symbol: "sun.horizon.fill", title: brief.greeting.isEmpty ? "Ta journée" : brief.greeting,
                      value: degrees(brief.weather?.temperature), lines: [brief.focus, brief.sections.map(\.title).prefix(3).joined(separator: " · ")])
        case .carousel(let title, let items):
            self.init(symbol: "square.grid.2x2.fill", title: title.isEmpty ? "Suggestions" : title, value: "\(items.count)",
                      lines: items.prefix(2).map { joined($0.title, $0.price) })
        case .links(let title, let links):
            self.init(symbol: "link", title: title.isEmpty ? "Liens" : title, lines: links.prefix(2).map(\.title))
        case .choices(let choices):
            guard let question = choices.questions.first else { return nil }
            self.init(symbol: "questionmark.bubble.fill", title: question.prompt, lines: [question.options.map(\.label).joined(separator: " · ")])
        }
    }

    /// An agent's ISO time made short: « 14:00 » today, « mar. 14:00 » another day, « mar. 3 nov. » for a whole day.
    /// Anything that is not a date is kept as written.
    static func when(_ raw: String, end: String = "") -> String {
        guard let start = ChatCard.date(raw) else { return raw }
        if raw.trimmingCharacters(in: .whitespaces).count <= 10 { return start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        let first = when(start)
        guard let finish = ChatCard.date(end) else { return first }
        return "\(first) – \(finish.formatted(.dateTime.hour().minute()))"
    }

    static func when(_ moment: Date) -> String {
        Calendar.current.isDateInToday(moment) ? moment.formatted(.dateTime.hour().minute())
            : moment.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func weatherSymbol(_ condition: String) -> String {
        let text = condition.lowercased()
        if text.contains("orage") { return "cloud.bolt.rain.fill" }
        if text.contains("neige") || text.contains("flocon") { return "snowflake" }
        if text.contains("pluie") || text.contains("averse") || text.contains("bruine") { return "cloud.rain.fill" }
        if text.contains("brouillard") || text.contains("brume") { return "cloud.fog.fill" }
        if text.contains("ensoleill") || text.contains("dégagé") || text.contains("soleil") { return "sun.max.fill" }
        if text.contains("nuage") || text.contains("couvert") { return "cloud.fill" }
        return "cloud.sun.fill"
    }
}
