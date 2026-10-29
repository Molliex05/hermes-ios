import Foundation

/// What an agent chose to put on the « À l'affiche » widget: a title, a few lines, one thing to keep in mind. The agent
/// writes it when it has something worth showing (never as a notification); the app downloads it and the widget draws it.
public struct AgentBoard: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var text: String, detail: String, time: String, icon: String, tone: String
        /// The exact moment, when the source knows it (the calendar does): « 13:45 » alone means today.
        public var at: Date?
        public var id: String { "\(time)|\(text)" }
        public init(text: String, detail: String = "", time: String = "", icon: String = "", tone: String = "", at: Date? = nil) {
            self.text = text; self.detail = detail; self.time = time; self.icon = icon; self.tone = tone; self.at = at
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

    /// Past its time, the board is stale: the widget falls back to a calm state instead of showing yesterday's news.
    public func isExpired(at date: Date = .now) -> Bool { expiresAt.map { $0 <= date } ?? false }
    public var isEmpty: Bool { items.isEmpty && focus.isEmpty }
    public static let maxItems = 5

    init(_ value: JSONValue) {
        func clean(_ text: String, _ limit: Int) -> String { String(text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(limit)) }
        title = clean(value["title"].string, 40)
        focus = clean(value["focus"].string, 140)
        ask = clean(value["ask"].string, 200)
        items = value["items"].array.prefix(Self.maxItems).compactMap { row in
            let text = clean(row["text"].string, 80)
            return text.isEmpty ? nil : Item(text: text, detail: clean(row["detail"].string, 50), time: clean(row["time"].string, 12),
                                             icon: clean(row["icon"].string, 40), tone: clean(row["tone"].string, 10).lowercased(),
                                             at: Self.date(row["at"].string))
        }
        updatedAt = Self.date(value["updated_at"].string)
        expiresAt = Self.date(value["expires_at"].string)
    }

    private static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let plain = ISO8601DateFormatter(), fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return plain.date(from: text) ?? fractional.date(from: text)
    }
}

/// The boards of every agent the server knows, by profile name.
public struct AgentBoards: Equatable, Sendable {
    public var boards: [String: AgentBoard]
    /// The next calendar events of the profiles that have Google, read by the server with no model: what the widget shows
    /// while the agent has written nothing. A profile present with no items is a free day, not an unknown.
    public var agendas: [String: AgentBoard]
    public init(boards: [String: AgentBoard] = [:], agendas: [String: AgentBoard] = [:]) { self.boards = boards; self.agendas = agendas }

    /// Tolerant on purpose: a malformed board is left out, the others are kept; not even an object is an error.
    public static func decode(_ data: Data) throws -> AgentBoards {
        let root = try JSONValue.decode(data)
        guard case .object = root, case .object(let rows) = root["boards"] else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no boards")) }
        let agendas = root["agendas"].object.mapValues(AgentBoard.init).filter { !$0.key.isEmpty }
        return AgentBoards(boards: rows.mapValues(AgentBoard.init).filter { !$0.key.isEmpty }, agendas: agendas)
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

    /// Everything waiting, once: the inbox is emptied as it is read.
    public static func take(from directory: URL? = nil, now: Date = .now) -> [SharedItem] {
        let items = read(from: directory, now: now)
        blob.clear(from: directory)
        return items
    }
}
