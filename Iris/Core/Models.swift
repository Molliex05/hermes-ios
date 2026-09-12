import Foundation

public struct AgentProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var title: String
    public var detail: String
    public var model: String
    public var provider: String
    public var canonicalID: String?
    public var preview: String
    public var skillCount: Int

    public init(_ v: JSONValue) {
        name = v["name"].string
        let meta = v["ui_meta"]["hermes-bots"]
        title = v["display_name"].string
        if title.isEmpty { title = meta["title"].string }
        if title.isEmpty { title = name == "default" ? "Hermes" : name.capitalized }
        detail = v["description"].string
        model = v["model"].string
        provider = v["provider"].string
        let canonical = v["canonical_session"]
        let cid = canonical["resolved_id"].string.isEmpty ? canonical["id"].string : canonical["resolved_id"].string
        canonicalID = cid.isEmpty ? nil : cid
        preview = canonical["preview"].string
        skillCount = v["skill_count"].int
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var profile: String
    public var title: String
    public var preview: String
    public var updated: Date
    public init(_ v: JSONValue, profile: String) {
        id = v["resolved_id"].string.isEmpty ? v["id"].string : v["resolved_id"].string
        self.profile = profile
        title = v["title"].string
        if title.isEmpty { title = "Nouvelle conversation" }
        preview = v["preview"].string
        let timestamp = max(v["last_active"].double, v["last_activity_at"].double, v["started_at"].double)
        updated = Date(timeIntervalSince1970: timestamp)
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Delivery: String, Codable, Sendable { case confirmed, sending, uncertain, failed }
    public var id: String
    public var role: String
    public var text: String
    public var delivery: Delivery
    public var streaming: Bool
    public init(id: String = UUID().uuidString, role: String, text: String, delivery: Delivery = .confirmed, streaming: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.delivery = delivery; self.streaming = streaming
    }
}

public struct ChatSnapshot: Codable, Sendable {
    public var storedID: String
    public var runtimeID: String
    public var profile: String
    public var title: String
    public var messages: [ChatMessage]
    public var lastSequence: Int
    public var epoch: String?
    public init(storedID: String, runtimeID: String = "", profile: String, title: String, messages: [ChatMessage] = [], lastSequence: Int = 0, epoch: String? = nil) {
        self.storedID = storedID; self.runtimeID = runtimeID; self.profile = profile; self.title = title
        self.messages = messages; self.lastSequence = lastSequence; self.epoch = epoch
    }
}

public struct Routine: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var prompt: String
    public var schedule: String
    public var paused: Bool
    public init(_ v: JSONValue) {
        id = v["job_id"].string.isEmpty ? v["id"].string : v["job_id"].string
        name = v["name"].string.replacingOccurrences(of: #"^\[bot:[^\]]+\]\s*"#, with: "", options: .regularExpression)
        prompt = v["prompt"].string.isEmpty ? v["prompt_preview"].string : v["prompt"].string
        schedule = v["schedule_display"].string
        if schedule.isEmpty { schedule = v["schedule"].string }
        if schedule.isEmpty { schedule = v["schedule"]["display"].string }
        paused = v["paused"].bool || v["state"].string == "paused" || v["enabled"] == .bool(false)
    }
}
