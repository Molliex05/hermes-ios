import EventKit
import EventKitUI
import SwiftUI

/// An event a card points to: what the agent wrote, matched against the phone's calendars when it is tapped.
struct CalendarEventRequest {
    let title: String
    let start: Date
}

/// Opens a card's event: the real Calendar event page when the event is in the phone's calendars, else Calendar on that
/// day and time. Set by the chat, which presents the page.
struct CalendarEventAction {
    let open: @MainActor (CalendarEventRequest) -> Void
}

extension EnvironmentValues {
    @Entry var calendarEvent: CalendarEventAction? = nil
}

/// Where cards are shown without the chat around them (a command's output, a task result), Calendar opens on the day.
@MainActor func openInCalendar(_ request: CalendarEventRequest, using action: CalendarEventAction?) {
    Haptics.select()
    if let action { action.open(request) } else { CalendarLink.openDay(request.start) }
}

/// The phone's calendars (Google, iCloud, work… as set up in Settings), read only to find the event a card means.
@MainActor enum CalendarLink {
    private static let store = EKEventStore()

    /// The event a card means, asking once for access to the calendars. nil without access or without a clear match.
    static func find(_ request: CalendarEventRequest) async -> EKEvent? {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: break
        case .notDetermined:
            guard await requestAccess() else { return nil }
        default: return nil
        }
        let window = store.predicateForEvents(withStart: request.start.addingTimeInterval(-86_400),
                                              end: request.start.addingTimeInterval(86_400), calendars: nil)
        let events = store.events(matching: window)
        let match = ChatCard.bestEventMatch(title: request.title, start: request.start,
                                            among: events.map { (title: $0.title ?? "", start: $0.startDate) })
        return match.map { events[$0] }
    }

    /// EventKit answers on a queue of its own: the handler is @Sendable so Swift does not expect it on the main actor
    /// (it would stop the app the moment Maxime answers the permission alert).
    private static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { @Sendable granted, _ in continuation.resume(returning: granted) }
        }
    }

    /// Calendar on that day and time (the only link Calendar offers: it cannot open one event).
    static func openDay(_ date: Date) {
        if let url = URL(string: "calshow:\(Int(date.timeIntervalSinceReferenceDate))") { UIApplication.shared.open(url) }
    }

    #if DEBUG
    /// Puts the demo's barber appointment in the simulator's calendar, to try the event page (`--demo-calendar`).
    static func seedDemoEvent() async {
        guard await requestAccess(), let start = ChatCard.date("2026-10-29T17:00"), let calendar = store.defaultCalendarForNewEvents else { return }
        let existing = store.events(matching: store.predicateForEvents(withStart: start, end: start.addingTimeInterval(3_600), calendars: nil))
        guard !existing.contains(where: { $0.title == "Barbier du Village" }) else { return }
        let event = EKEvent(eventStore: store)
        event.title = "Barbier du Village"; event.startDate = start; event.endDate = start.addingTimeInterval(45 * 60)
        event.location = "Rue Saint-Pierre, Saint-Constant"; event.calendar = calendar
        try? store.save(event, span: .thisEvent)
    }
    #endif
}

/// A calendar event shown in a sheet.
struct EventPage: Identifiable {
    let id = UUID()
    let event: EKEvent
}

/// The event page already has « Supprimer l’événement » in its list: its toolbar would show a second one. An invitation
/// keeps its toolbar, where Accepter, Peut-être and Refuser are.
private final class EventNavigationController: UINavigationController {
    var keepsToolbar = false
    override func setToolbarHidden(_ hidden: Bool, animated: Bool) { super.setToolbarHidden(keepsToolbar ? hidden : true, animated: animated) }
}

/// Apple's own event page (time, place, alerts, attendees, edit), as in Calendar.
struct EventPageView: UIViewControllerRepresentable {
    let event: EKEvent
    let done: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = EKEventViewController()
        controller.event = event
        controller.allowsEditing = true
        controller.allowsCalendarPreview = true
        controller.delegate = context.coordinator
        let navigation = EventNavigationController(rootViewController: controller)
        navigation.keepsToolbar = event.hasAttendees && event.organizer?.isCurrentUser == false
        navigation.navigationBar.tintColor = UIColor(AppTheme.accent)
        return navigation
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    @MainActor final class Coordinator: NSObject, @preconcurrency EKEventViewDelegate {
        let done: @MainActor () -> Void
        init(done: @escaping @MainActor () -> Void) { self.done = done }
        func eventViewController(_ controller: EKEventViewController, didCompleteWith action: EKEventViewAction) { done() }
    }
}
