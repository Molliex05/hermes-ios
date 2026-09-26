import Foundation

/// Presentation of Hermes schedules. The server remains responsible for parsing,
/// time zones and calculating the next occurrence.
public struct RoutineSchedule: Equatable, Sendable {
    public enum Rhythm: String, CaseIterable, Sendable {
        case daily, weekdays, weekly, hourly

        public var title: String {
            switch self {
            case .daily: "Tous les jours"
            case .weekdays: "Du lundi au vendredi"
            case .weekly: "Chaque semaine"
            case .hourly: "Toutes les heures"
            }
        }
    }

    public var rhythm: Rhythm
    public var hour: Int
    public var minute: Int
    /// Cron convention: 0 = Sunday, 1 = Monday, …, 6 = Saturday.
    public var weekday: Int

    public init(rhythm: Rhythm, hour: Int = 8, minute: Int = 0, weekday: Int = 1) {
        self.rhythm = rhythm
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        self.weekday = min(6, max(0, weekday))
    }

    public init?(_ expression: String) {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
              let minute = Int(fields[0]), (0...59).contains(minute) else { return nil }
        if fields[1] == "*", fields[4] == "*" {
            self.init(rhythm: .hourly, minute: minute)
            return
        }
        guard let hour = Int(fields[1]), (0...23).contains(hour) else { return nil }
        if fields[4] == "*" { self.init(rhythm: .daily, hour: hour, minute: minute) }
        else if fields[4] == "1-5" { self.init(rhythm: .weekdays, hour: hour, minute: minute) }
        else if let day = Int(fields[4]), (0...7).contains(day) {
            self.init(rhythm: .weekly, hour: hour, minute: minute, weekday: day == 7 ? 0 : day)
        } else { return nil }
    }

    public var expression: String {
        switch rhythm {
        case .daily: "\(minute) \(hour) * * *"
        case .weekdays: "\(minute) \(hour) * * 1-5"
        case .weekly: "\(minute) \(hour) * * \(weekday)"
        case .hourly: "\(minute) * * * *"
        }
    }

    public var summary: String {
        let time = minute == 0 ? "\(hour) h" : String(format: "%d h %02d", hour, minute)
        switch rhythm {
        case .daily: return "Tous les jours à \(time)"
        case .weekdays: return "Du lundi au vendredi à \(time)"
        case .weekly: return "Le \(Self.weekdays[weekday]) à \(time)"
        case .hourly: return minute == 0 ? "Toutes les heures" : "Toutes les heures, à la minute \(minute)"
        }
    }

    public static let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]

    /// Prefer the canonical schedule object over its display string. In particular,
    /// converting a saved one-shot back to “in 30m” would shift its execution.
    public static func expression(from job: JSONValue) -> String {
        let schedule = job["schedule"]
        if !schedule.string.isEmpty { return schedule.string }
        switch schedule["kind"].string {
        case "cron": if !schedule["expr"].string.isEmpty { return schedule["expr"].string }
        case "interval":
            let minutes = schedule["minutes"].double
            if minutes > 0 {
                let value = minutes.rounded() == minutes ? String(format: "%.0f", minutes) : String(minutes)
                return "every \(value)m"
            }
        case "once": if !schedule["run_at"].string.isEmpty { return schedule["run_at"].string }
        default: break
        }
        return [schedule["value"].string, job["schedule_display"].string, schedule["display"].string].first { !$0.isEmpty } ?? ""
    }

    public static func nextRun(from job: JSONValue) -> Date? {
        let raw = job["next_run_at"].string
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: raw) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: raw)
    }

    public static func runConversation(_ run: JSONValue, profile: String) -> Conversation? {
        // /api/cron/jobs/{id}/runs returns stored SessionInfo rows. Never derive a
        // session id from a job id, a timestamp, or the destination Bot Chat.
        guard !run["id"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              run["profile"].string.isEmpty || run["profile"].string == profile else { return nil }
        return Conversation(run, profile: profile)
    }
}
