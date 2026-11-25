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
    /// The start of the current day; it moves when the day turns, and the Today page goes back to it then.
    private(set) var today = Calendar.current.startOfDay(for: Date())
    /// Counts the calendar's changes, so the appointments of other days are read again.
    private var version = 0

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The appointments of other days paged to on the Today page, read once per change of the calendar.
    @ObservationIgnored private var otherDays: [Date: [CalendarAppointment]] = [:]

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
        let day = Calendar.current.startOfDay(for: Date())
        if day != today { today = day }
        var read = CalendarAccess.todaysAppointments().filter { !$0.isDeclined }
        #if DEBUG
        // Appointments added for a test stay through every reading, and show as if the calendar were allowed.
        if !testing.isEmpty {
            status = .granted
            read += testing
        }
        #endif
        if read != appointments { appointments = read }
        otherDays = [:]
        window = nil
        version += 1
    }

    /// The appointments of a day: today's as kept, another day's read from the calendar (declined ones left out).
    func appointments(on day: Date, calendar: Calendar = .current) -> [CalendarAppointment] {
        let start = calendar.startOfDay(for: day)
        guard start != today else { return appointments }
        _ = version
        if let known = otherDays[start] { return known }
        let read = CalendarAccess.appointments(on: start, calendar: calendar).filter { !$0.isDeclined }
        otherDays[start] = read
        return read
    }

    /// The appointments from `windowDaysBack` days back to `windowDaysAhead` days ahead, for the bowls' Appointments
    /// (`BowlAppointments`): read once per change of the calendar and per day, declined ones left out.
    func windowAppointments() -> [CalendarAppointment] {
        _ = version
        if let window, window.day == today { return window.items }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -Self.windowDaysBack, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: Self.windowDaysAhead, to: today) ?? today
        var read = CalendarAccess.appointments(from: start, to: end).filter { !$0.isDeclined }
        #if DEBUG
        read += testing
        #endif
        window = (today, read)
        return read
    }

    /// Changes whenever the calendar is read again (`windowAppointments` too).
    var windowToken: Int { version }

    static let windowDaysBack = 180
    static let windowDaysAhead = 365
    @ObservationIgnored private var window: (day: Date, items: [CalendarAppointment])?

    /// An appointment by its occurrence (`CalendarAppointment.key`): of the day shown, else of the bowls' window.
    func appointment(key: String, on day: Date) -> CalendarAppointment? {
        appointments(on: day).first { $0.key == key } ?? windowAppointments().first { $0.key == key }
    }

    #if DEBUG
    /// For looking at the Today page without touching a calendar: an appointment only in memory.
    func addForTesting(_ appointment: CalendarAppointment) {
        testing.append(appointment)
        refresh()
    }

    @ObservationIgnored private var testing: [CalendarAppointment] = []
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

/// The day the Today page shows: paged a day at a time, as view state only (not kept, back to today at launch and
/// when the day turns). Days are their start in the device calendar.
enum TodayDay {
    /// The day `days` after (or before) `day`, by the calendar, so a day of 23 or 25 hours is still one day.
    static func step(_ day: Date, by days: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        return calendar.date(byAdding: .day, value: days, to: start).map { calendar.startOfDay(for: $0) } ?? start
    }

    /// Whole days from today to `day` (negative before today).
    static func offset(of day: Date, now: Date = Date(), calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0
    }

    static func isToday(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.isDate(day, inSameDayAs: now)
    }

    /// The page's title: "Today", "Tomorrow", "Yesterday", otherwise the short weekday and date ("Wed 25 Nov"), so it
    /// fits the one-row bar beside ‹ › and "+"; with the year when it is another one; in the device's locale.
    static func title(_ day: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch offset(of: day, now: now, calendar: calendar) {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        case -1: return String(localized: "Yesterday")
        default: break
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEdMMM" : "EEEdMMMy")
        return formatter.string(from: day)
    }

    /// The whole date for VoiceOver and tooltips ("Wednesday, 25 November 2026").
    static func fullDate(_ day: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: day)
    }
}

/// What the Today page shows of the to-dos: only what is open. On today the open ones due today or before (the late
/// ones come along), on another day the open ones due on exactly that day. Done to-dos never show in Today (owner
/// decision, 2026-11-24): a to-do ticked there leaves the list (with the undo toast); it stays in its bowl or the
/// Inbox and in Open To-dos' "Done Today".
enum TodayTodos {
    static func open(_ notes: [Note], now: Date = Date(), calendar: Calendar = .current) -> [Note] {
        open(notes, on: now, now: now, calendar: calendar)
    }

    static func open(_ notes: [Note], on day: Date, now: Date = Date(), calendar: Calendar = .current) -> [Note] {
        let isToday = TodayDay.isToday(day, now: now, calendar: calendar)
        let key = Todos.dueKey(day, calendar: calendar)
        return Todos.byDue(notes.filter { note in
            guard note.isTodo, !note.isDone, !note.isDeleted, let due = note.todoDue else { return false }
            if !isToday { return due == key }
            return Todos.dueStatus(due, now: now, calendar: calendar).map { $0 != .later } ?? false
        })
    }

    /// "Up Next" in Today: open to-dos due on one of the next `days` days (after today), by due day.
    static func upcoming(_ notes: [Note], days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [Note] {
        let today = Todos.dueKey(now, calendar: calendar)
        let last = Todos.dueKey(calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now, calendar: calendar)
        return Todos.byDue(notes.filter { note in
            guard note.isTodo, !note.isDone, !note.isDeleted, let due = note.todoDue else { return false }
            return due > today && due <= last
        })
    }

    /// The entries linked to an appointment as Today lists them under it: done to-dos left out like everywhere in Today.
    static func shown(_ linked: [Note]) -> [Note] {
        linked.filter { !($0.isTodo && $0.isDone) }
    }
}
