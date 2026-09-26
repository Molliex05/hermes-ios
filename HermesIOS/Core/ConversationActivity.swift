import Foundation

/// Local reading position, scoped by the enclosing saved gateway cache.
/// A server heartbeat, title edit or reordering is not a new message.
struct ConversationActivity: Codable, Sendable {
    private struct Entry: Codable, Sendable {
        var count: Int?
        var preview: String
        var unread: Bool
    }
    private var entries: [String: Entry] = [:]
    private var baselines: [String: Date] = [:]
    private var visits: [String: Date] = [:]

    mutating func observe(_ rows: [Conversation], establishesBaseline: Bool = true, emptyProfile: String? = nil, at discoveredAt: Date = Date()) {
        if establishesBaseline, rows.isEmpty, let emptyProfile, baselines[emptyProfile] == nil {
            baselines[emptyProfile] = discoveredAt
        }
        for (profile, conversations) in Dictionary(grouping: rows, by: \.profile) {
            let baseline = baselines[profile]
            for row in conversations where !row.id.isEmpty {
                let key = key(row.profile, row.id)
                let preview = String(row.preview.prefix(500))
                if var old = entries[key] {
                    // A slower request can finish after a newer history/roster read.
                    if let count = row.messageCount, let previous = old.count, count < previous { continue }
                    let changedCount = row.messageCount.map { $0 != (old.count ?? $0) } ?? false
                    // Roster previews show the last message; session lists can show the first.
                    // Compare previews only on older servers that provide no message count.
                    let changedPreview = row.messageCount == nil && old.count == nil && !preview.isEmpty && !old.preview.isEmpty && preview != old.preview
                    old.unread = old.unread || changedCount || changedPreview
                    old.count = row.messageCount ?? old.count
                    if !preview.isEmpty { old.preview = preview }
                    entries[key] = old
                } else {
                    entries[key] = Entry(count: row.messageCount, preview: preview,
                        unread: baseline.map { (row.createdAt ?? row.updated) > $0 && (row.messageCount ?? 1) > 0 } ?? false)
                }
            }
            // The first snapshot is a quiet baseline, not hundreds of unread chats.
            if establishesBaseline, baseline == nil {
                // RPC lists omit last_active; later HTTP pages must not turn old chats unread.
                baselines[profile] = max(discoveredAt, conversations.compactMap(\.createdAt).max() ?? .distantPast)
            }
        }
    }

    func isUnread(profile: String, id: String) -> Bool { entries[key(profile, id)]?.unread == true }
    func hasUnread(profile: String) -> Bool { entries.contains { $0.key.hasPrefix(profile + "\u{1f}") && $0.value.unread } }
    mutating func markRead(profile: String, id: String) { entries[key(profile, id)]?.unread = false }
    mutating func visit(profile: String, at date: Date = Date()) { visits[profile] = date }
    func lastVisited(profile: String) -> Date? { visits[profile] }
    mutating func remove(profile: String) {
        entries = entries.filter { !$0.key.hasPrefix(profile + "\u{1f}") }
        baselines[profile] = nil; visits[profile] = nil
    }
    private func key(_ profile: String, _ id: String) -> String { profile + "\u{1f}" + id }
}
