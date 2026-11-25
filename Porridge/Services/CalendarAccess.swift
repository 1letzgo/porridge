import EventKit
import Foundation

/// A calendar appointment, as shown in the Record Meeting picker and in the meeting alert. Read only: Porridge never
/// changes the calendar, answers invitations or sets reminders; an appointment only starts or prepares a recording.
struct CalendarAppointment: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarName: String
    /// `EKCalendar.calendarIdentifier`; the settings pick which calendars alert.
    var calendarID: String = ""
    /// The other people invited (the user not among them), as names to offer for the speakers.
    var attendees: [String] = []
    /// The link of a video call (Zoom, Meet, Teams, …) found in the appointment.
    var videoURL: URL?
    /// The user declined the invitation.
    var isDeclined = false
    /// `EKEvent.calendarItemExternalIdentifier`: the same on every device and for every occurrence of a series
    /// (falls back to the event's identifier here). Links to entries and bowls are kept by it (`AppointmentLinks`).
    /// Optional so that appointments remembered before it decode.
    var externalID: String?
    /// Where it takes place (`EKEvent.location`), if it says.
    var location: String?
    /// One occurrence of a repeating appointment (optional so that appointments remembered before it decode).
    var repeats: Bool?

    var isRecurring: Bool { repeats == true }

    /// The series (or the single appointment), the same on every device.
    var seriesID: String { externalID.flatMap { $0.isEmpty ? nil : $0 } ?? id }
    /// This occurrence of the appointment, the same on every device.
    var key: String { AppointmentRef.key(seriesID: seriesID, start: start) }
}

/// Reads appointments from the calendars on this device.
enum CalendarAccess {
    private static let store = EKEventStore()

    enum Status {
        case granted
        case denied
        case notDetermined
    }

    static var status: Status {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Posted by EventKit when a calendar changed (here or synced); the alerts plan again.
    static var changedNotification: Notification.Name { .EKEventStoreChanged }
    static var eventStore: EKEventStore { store }

    static func todaysAppointments() -> [CalendarAppointment] {
        appointments(on: Date())
    }

    /// The appointments of one day, all-day ones first.
    static func appointments(on day: Date, calendar: Calendar = .current) -> [CalendarAppointment] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return appointments(from: start, to: end)
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    /// The appointments between two moments, not cancelled ones; empty without access.
    static func appointments(from start: Date, to end: Date) -> [CalendarAppointment] {
        guard status == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
            .map(appointment)
    }

    /// The calendars with events, for the settings: identifier, title and the account they belong to.
    static func eventCalendars() -> [(id: String, title: String, account: String)] {
        guard status == .granted else { return [] }
        return store.calendars(for: .event)
            .map { (id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    private static func appointment(_ event: EKEvent) -> CalendarAppointment {
        var people = (event.attendees ?? []).filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
        if let organizer = event.organizer, !organizer.isCurrentUser,
           !people.contains(where: { $0.url == organizer.url }) {
            people.insert(organizer, at: 0)
        }
        let me = (event.attendees ?? []).first(where: \.isCurrentUser)
        let names = people.compactMap { MeetingAlerts.attendeeName(name: $0.name, address: $0.url.absoluteString) }
        return CalendarAppointment(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: (event.title ?? "").isEmpty ? String(localized: "Untitled") : event.title,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarName: event.calendar.title,
            calendarID: event.calendar.calendarIdentifier,
            attendees: MeetingAlerts.unique(names),
            videoURL: MeetingAlerts.videoLink(in: [event.url?.absoluteString, event.location, event.notes]),
            isDeclined: me?.participantStatus == .declined,
            externalID: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? "",
            location: event.location.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 },
            repeats: event.hasRecurrenceRules
        )
    }
}
