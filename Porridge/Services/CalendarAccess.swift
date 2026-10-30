import EventKit
import Foundation

/// A calendar appointment of today, as shown in the picker.
struct CalendarAppointment: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarName: String
}

/// Reads today's appointments from the calendars on this device.
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

    static func todaysAppointments() -> [CalendarAppointment] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map {
                CalendarAppointment(
                    id: $0.eventIdentifier ?? UUID().uuidString,
                    title: ($0.title ?? "").isEmpty ? "Untitled" : $0.title,
                    start: $0.startDate,
                    end: $0.endDate,
                    isAllDay: $0.isAllDay,
                    calendarName: $0.calendar.title
                )
            }
    }
}
