import Foundation
import Observation

/// Today's appointments for the Today card and page, read again when a calendar changes, the day turns or the
/// app comes back. Declined invitations are left out.
@MainActor
@Observable
final class TodayCalendar {
    static let shared = TodayCalendar()

    private(set) var appointments: [CalendarAppointment] = []
    private(set) var status = CalendarAccess.status

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: CalendarAccess.changedNotification, object: CalendarAccess.eventStore, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    func refresh() {
        status = CalendarAccess.status
        let read = CalendarAccess.todaysAppointments().filter { !$0.isDeclined }
        if read != appointments { appointments = read }
    }

    #if DEBUG
    /// For looking at the Today page without touching a calendar: an appointment only in memory.
    func addForTesting(_ appointment: CalendarAppointment) {
        appointments.append(appointment)
    }
    #endif

    /// Asks for the calendars, once.
    func requestAccess() async {
        if CalendarAccess.status == .notDetermined { _ = await CalendarAccess.requestAccess() }
        MeetingLinks.forgetLookups()
        refresh()
    }

    /// The next appointment that has not ended, if any (all-day ones not counted).
    func next(now: Date = Date()) -> CalendarAppointment? {
        appointments.first { !$0.isAllDay && $0.end > now }
    }
}

/// What the Today card and page show of the to-dos: open ones due today or before, and those done today.
enum TodayTodos {
    static func open(_ notes: [Note], now: Date = Date(), calendar: Calendar = .current) -> [Note] {
        Todos.byDue(notes.filter { note in
            guard note.isTodo, !note.isDone, !note.isDeleted, let due = note.todoDue else { return false }
            return Todos.dueStatus(due, now: now, calendar: calendar).map { $0 != .later } ?? false
        })
    }

    static func doneToday(_ notes: [Note], now: Date = Date(), calendar: Calendar = .current) -> [Note] {
        notes.filter { $0.isTodo && $0.isDone && !$0.isDeleted && $0.todoDoneAt.map { calendar.isDate($0, inSameDayAs: now) } == true }
            .sorted { ($0.todoDoneAt ?? .distantPast) > ($1.todoDoneAt ?? .distantPast) }
    }
}
