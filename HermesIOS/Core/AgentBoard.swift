import Foundation

/// What an agent chose to put on the « À l'affiche » widget: a title, a few lines, one thing to keep in mind. The agent
/// writes it when it has something worth showing (never as a notification); the app downloads it and the widget draws it.
public struct AgentBoard: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var text: String, detail: String, time: String, icon: String, tone: String
        /// The exact moment, when the source knows it (the calendar does): « 13:45 » alone means today.
        public var at: Date?
        /// When it ends, when known: a night shift started yesterday is still « maintenant » until then.
        public var until: Date?
        public var id: String { "\(at.map { String(Int($0.timeIntervalSince1970)) } ?? "")|\(time)|\(text)" }
        public init(text: String, detail: String = "", time: String = "", icon: String = "", tone: String = "", at: Date? = nil, until: Date? = nil) {
            self.text = text; self.detail = detail; self.time = time; self.icon = icon; self.tone = tone; self.at = at; self.until = until
        }
    }

    public var title: String
    public var items: [Item]
    public var focus: String
    /// A sentence to put in the composer when the widget is tapped (never sent by itself).
    public var ask: String
    public var updatedAt: Date?
    public var expiresAt: Date?

    public init(title: String = "", items: [Item] = [], focus: String = "", ask: String = "", updatedAt: Date? = nil, expiresAt: Date? = nil) {
        self.title = title; self.items = items; self.focus = focus; self.ask = ask; self.updatedAt = updatedAt; self.expiresAt = expiresAt
    }

    /// Past its time, the board is stale: the widget falls back to a calm state instead of showing yesterday's news. A board
    /// that names no expiry is good for a day from when it was written.
    public func isExpired(at date: Date = .now) -> Bool {
        if let expiresAt { return expiresAt <= date }
        if let updatedAt { return date.timeIntervalSince(updatedAt) > 24 * 3600 }
        return false
    }
    public var isEmpty: Bool { items.isEmpty && focus.isEmpty }
    public static let maxItems = 5

    init(_ value: JSONValue) {
        // Cut first: a huge string is never split and joined whole.
        func clean(_ text: String, _ limit: Int) -> String { String(String(text.prefix(limit * 4)).split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(limit)) }
        title = clean(value["title"].string, 40)
        focus = clean(value["focus"].string, 140)
        ask = clean(value["ask"].string, 200)
        items = value["items"].array.prefix(Self.maxItems).compactMap { row in
            let text = clean(row["text"].string, 80)
            return text.isEmpty ? nil : Item(text: text, detail: clean(row["detail"].string, 50), time: clean(row["time"].string, 12),
                                             icon: clean(row["icon"].string, 40), tone: clean(row["tone"].string, 10).lowercased(),
                                             at: Self.date(row["at"].string), until: Self.date(row["until"].string))
        }
        updatedAt = Self.date(value["updated_at"].string)
        expiresAt = Self.date(value["expires_at"].string)
    }

    nonisolated(unsafe) private static let plainISO = ISO8601DateFormatter()      // built once; parsing with a formatter is thread-safe
    nonisolated(unsafe) private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()

    fileprivate static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return plainISO.date(from: text) ?? fractionalISO.date(from: text)
    }
}

/// The weather of the user's place, read by the server from Open-Meteo with no model: now, the next hours, the next days.
public struct WeatherReport: Equatable, Sendable {
    public struct Hour: Equatable, Sendable { public var at: Date, temp: Int, rain: Int; public var symbol: String }
    public struct Day: Equatable, Sendable {
        public var date: Date, high: Int, low: Int, rain: Int; public var summary: String, symbol: String
        public var sunrise: Date?, sunset: Date?
    }
    public var place: String, summary: String, symbol: String
    public var temp: Int
    public var feels: Int?, wind: Int?
    public var hours: [Hour], days: [Day]
    public var updatedAt: Date?, expiresAt: Date?

    /// Past its time the figures are stale: the widget leaves the weather out rather than show this morning's.
    public func isExpired(at date: Date = .now) -> Bool {
        if let expiresAt { return expiresAt <= date }
        if let updatedAt { return date.timeIntervalSince(updatedAt) > 3 * 3600 }
        return false
    }

    /// nil when there is no temperature: nothing worth drawing.
    init?(_ value: JSONValue) {
        guard case .object = value, !value["temp"].isNull else { return nil }
        func text(_ key: String, _ limit: Int) -> String { String(value[key].string.prefix(limit)) }
        func optional(_ key: String) -> Int? { value[key].isNull ? nil : value[key].int }
        place = text("place", 40); summary = text("summary", 40); symbol = text("symbol", 40)
        temp = value["temp"].int; feels = optional("feels"); wind = optional("wind")
        hours = value["hours"].array.prefix(12).compactMap { row in
            guard let at = AgentBoard.date(row["at"].string), !row["temp"].isNull else { return nil }
            return Hour(at: at, temp: row["temp"].int, rain: row["rain"].int, symbol: String(row["symbol"].string.prefix(40)))
        }
        days = value["days"].array.prefix(7).compactMap { row in
            guard let date = Self.local(row["date"].string), !row["high"].isNull, !row["low"].isNull else { return nil }
            return Day(date: date, high: row["high"].int, low: row["low"].int, rain: row["rain"].int, summary: String(row["summary"].string.prefix(40)),
                       symbol: String(row["symbol"].string.prefix(40)), sunrise: Self.local(row["sunrise"].string), sunset: Self.local(row["sunset"].string))
        }
        updatedAt = AgentBoard.date(value["updated_at"].string); expiresAt = AgentBoard.date(value["expires_at"].string)
    }

    nonisolated(unsafe) private static let dayFormat = format("yyyy-MM-dd")
    nonisolated(unsafe) private static let minuteFormat = format("yyyy-MM-dd'T'HH:mm")
    private static func format(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = pattern; return formatter
    }
    /// « 2026-10-29 » or « 2026-10-29T07:17 » (no zone: the place's own clock, which is the phone's).
    private static func local(_ text: String) -> Date? { text.isEmpty ? nil : (text.contains("T") ? minuteFormat : dayFormat).date(from: text) }
}

/// The boards of every agent the server knows, by profile name.
public struct AgentBoards: Equatable, Sendable {
    public var boards: [String: AgentBoard]
    /// The next calendar events of the profiles that have Google, read by the server with no model: what the widget shows
    /// while the agent has written nothing. A profile present with no items is a free day, not an unknown.
    public var agendas: [String: AgentBoard]
    /// The weather of the user's place, the same for every agent; nil when the server has none.
    public var weather: WeatherReport?
    public init(boards: [String: AgentBoard] = [:], agendas: [String: AgentBoard] = [:], weather: WeatherReport? = nil) {
        self.boards = boards; self.agendas = agendas; self.weather = weather
    }

    /// Tolerant on purpose: a malformed board is left out, the others are kept; not even an object is an error.
    public static func decode(_ data: Data) throws -> AgentBoards {
        let root = try JSONValue.decode(data)
        // Either part may be missing (a server that has only the agendas), but an answer with neither is not a board.
        guard case .object = root else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an object")) }
        var rows: [String: JSONValue] = [:], hasBoards = false
        if case .object(let found) = root["boards"] { rows = found; hasBoards = true }
        guard hasBoards || !root["agendas"].object.isEmpty else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no boards")) }
        let agendas = root["agendas"].object.mapValues(AgentBoard.init).filter { !$0.key.isEmpty }
        return AgentBoards(boards: rows.mapValues(AgentBoard.init).filter { !$0.key.isEmpty }, agendas: agendas, weather: WeatherReport(root["weather"]))
    }
}

/// The boards saved for the widgets by the app.
public enum AgentBoardStore {
    private static let blob = SharedBlob(account: "agent-board")

    public static func read(from directory: URL? = nil) -> AgentBoards? {
        blob.read(from: directory).flatMap { try? AgentBoards.decode($0) }
    }

    /// Validates before saving, so a malformed answer never replaces a good board.
    @discardableResult
    public static func write(_ data: Data, to directory: URL? = nil) -> AgentBoards? {
        guard let boards = try? AgentBoards.decode(data), blob.write(data, to: directory) else { return nil }
        return boards
    }

    public static func clear(from directory: URL? = nil) { blob.clear(from: directory) }
}

/// A profile as the extensions list it (the widget's choice of agent, the share sheet's destination).
public struct SharedProfile: Codable, Equatable, Sendable, Identifiable {
    public var name: String, title: String
    public var id: String { name }
    public init(name: String, title: String) { self.name = name; self.title = title }
}

public enum SharedProfiles {
    private static let blob = SharedBlob(account: "profiles")

    public static func read(from directory: URL? = nil) -> [SharedProfile] {
        blob.read(from: directory).flatMap { try? JSONDecoder().decode([SharedProfile].self, from: $0) } ?? []
    }

    public static func write(_ profiles: [SharedProfile], to directory: URL? = nil) {
        if let data = try? JSONEncoder().encode(profiles) { blob.write(data, to: directory) }
    }
}

/// What the share sheet leaves for the app: a link or a text for an agent, waiting for the app to send it.
public struct SharedItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var profile: String
    public var text: String
    public var note: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, profile: String, text: String, note: String = "", createdAt: Date = .now) {
        self.id = id; self.profile = profile; self.text = text; self.note = note; self.createdAt = createdAt
    }

    /// The message the agent receives: the note first (what to do), then what was shared.
    public var message: String { [note, text].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

public enum ShareInbox {
    private static let blob = SharedBlob(account: "share-inbox")
    /// Old enough to be forgotten: a share nobody opened the app for in two days is no longer wanted.
    static let lifetime: TimeInterval = 2 * 86_400
    static let capacity = 10

    public static func read(from directory: URL? = nil, now: Date = .now) -> [SharedItem] {
        let items = blob.read(from: directory).flatMap { try? JSONDecoder().decode([SharedItem].self, from: $0) } ?? []
        return items.filter { now.timeIntervalSince($0.createdAt) < lifetime }
    }

    @discardableResult
    public static func add(_ item: SharedItem, to directory: URL? = nil) -> Bool {
        let items = Array((read(from: directory) + [item]).suffix(capacity))
        guard let data = try? JSONEncoder().encode(items) else { return false }
        return blob.write(data, to: directory)
    }

    /// Takes away only the items with these ids, whatever else was added since they were read (the share sheet and the app
    /// are different processes).
    public static func remove(ids: Set<String>, from directory: URL? = nil) {
        guard !ids.isEmpty else { return }
        let remaining = read(from: directory).filter { !ids.contains($0.id) }
        if remaining.isEmpty { blob.clear(from: directory) }
        else if let data = try? JSONEncoder().encode(remaining) { blob.write(data, to: directory) }
    }

    /// Everything waiting, emptied as it is read (tests and simple callers; the app removes items once they are handled).
    public static func take(from directory: URL? = nil, now: Date = .now) -> [SharedItem] {
        let items = read(from: directory, now: now)
        remove(ids: Set(items.map(\.id)), from: directory)
        return items
    }
}
