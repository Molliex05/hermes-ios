import Foundation

/// The day as a strip, from 6 h to 23 h: each event a coloured span, and where now stands. Jarvis's widget draws it so the
/// shape of the day (a shift, a dinner, the free hours between) reads at a glance.
public enum DayStrip {
    public static let firstHour = 6.0, lastHour = 23.0

    public struct Span: Equatable, Sendable {
        public let from: Double, to: Double
        public let tone: String
    }

    public struct Event: Sendable {
        public let start: Date, end: Date?, tone: String
        public init(start: Date, end: Date?, tone: String = "") { self.start = start; self.end = end; self.tone = tone }
    }

    /// Where a moment falls on the strip of `day`, 0 at 6 h and 1 at 23 h; nil outside that day.
    public static func position(_ date: Date, on day: Date, calendar: Calendar = .current) -> Double? {
        let midnight = calendar.startOfDay(for: day)
        let hours = date.timeIntervalSince(midnight) / 3600
        guard hours >= 0, hours < 24 else { return nil }
        return min(1, max(0, (hours - firstHour) / (lastHour - firstHour)))
    }

    /// Each event clipped to the strip (a night shift from yesterday shows from 6 h; one past 23 h stops there). An event
    /// without an end lasts an hour. Events wholly outside 6–23 h are left out.
    public static func spans(_ events: [Event], on day: Date, calendar: Calendar = .current) -> [Span] {
        let midnight = calendar.startOfDay(for: day)
        func clip(_ date: Date) -> Double { min(1, max(0, (date.timeIntervalSince(midnight) / 3600 - firstHour) / (lastHour - firstHour))) }
        return events.compactMap { event in
            let end = event.end ?? event.start.addingTimeInterval(3600)
            let (from, to) = (clip(event.start), clip(end))
            return to > from ? Span(from: from, to: to, tone: event.tone) : nil
        }
    }
}
