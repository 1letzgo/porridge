import Foundation
import SwiftData

/// How a to-do repeats: every N days, weeks, months or years. A repeating to-do is one entry: when it is done, its
/// due day moves to the next occurrence and its subtasks are unticked again. It is never copied and never archived.
///
/// Stored without a field of its own (the CloudKit schema stays as it is): in the JSON object of
/// `Note.todoSuggestionsRaw` under the reserved key `@repeat` (task keys never contain "@", see
/// `TodoSuggestions.key`), e.g. `{"@repeat":"month:1:31"}`. Versions that do not know it keep it and ignore it.
struct TodoRepeat: Hashable {
    enum Unit: String, CaseIterable {
        case day, week, month, year
    }

    var unit: Unit
    /// Every `interval` units, at least 1.
    var interval: Int
    /// Monthly and yearly: the day of the month it falls on (1–31). Kept so that a to-do on the 31st comes back
    /// on the 31st after a shorter month (31 Jan → 28 Feb → 31 Mar), and one on 29 Feb in the next leap year.
    var anchorDay: Int?

    init(unit: Unit, interval: Int = 1, anchorDay: Int? = nil) {
        self.unit = unit
        self.interval = max(1, min(interval, 999))
        self.anchorDay = anchorDay.map { max(1, min($0, 31)) }
    }

    static let daily = TodoRepeat(unit: .day)
    static let weekly = TodoRepeat(unit: .week)
    static let monthly = TodoRepeat(unit: .month)
    static let yearly = TodoRepeat(unit: .year)

    static func everyDays(_ days: Int) -> TodoRepeat { TodoRepeat(unit: .day, interval: days) }

    /// The choices of the Repeat menu (without "Every N Days…").
    static let presets: [TodoRepeat] = [.daily, .weekly, .monthly, .yearly]

    /// The key in `Note.todoSuggestionsRaw`.
    static let storageKey = "@repeat"

    // MARK: Stored form

    /// "day:1", "week:2", "month:1:31".
    var raw: String {
        var parts = [unit.rawValue, String(interval)]
        if let anchorDay, unit == .month || unit == .year { parts.append(String(anchorDay)) }
        return parts.joined(separator: ":")
    }

    init?(raw: String) {
        let parts = raw.split(separator: ":").map(String.init)
        guard let first = parts.first, let unit = Unit(rawValue: first) else { return nil }
        let interval = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        let anchor = parts.count > 2 ? Int(parts[2]) : nil
        self.init(unit: unit, interval: interval, anchorDay: anchor)
    }

    /// Same rule, whatever day it is anchored on (for ticks in the menu).
    func sameRule(as other: TodoRepeat?) -> Bool {
        guard let other else { return false }
        return unit == other.unit && interval == other.interval
    }

    // MARK: Names

    /// "Daily", "Weekly", "Every 3 Days", "Every 2 Months".
    var title: String {
        switch (unit, interval) {
        case (.day, 1): String(localized: "Daily")
        case (.week, 1): String(localized: "Weekly")
        case (.month, 1): String(localized: "Monthly")
        case (.year, 1): String(localized: "Yearly")
        case (.day, let n): String(localized: "Every \(n) Days")
        case (.week, let n): String(localized: "Every \(n) Weeks")
        case (.month, let n): String(localized: "Every \(n) Months")
        case (.year, let n): String(localized: "Every \(n) Years")
        }
    }

    // MARK: Next occurrence

    /// The day after `key` by the rule: days and weeks count calendar days, months and years keep the anchor day
    /// (or the last day of a shorter month). Pure day arithmetic, no times: daylight saving time cannot shift it.
    func advance(_ key: String) -> String? {
        guard let day = Day(key) else { return nil }
        switch unit {
        case .day: return day.adding(days: interval).key
        case .week: return day.adding(days: 7 * interval).key
        case .month: return day.adding(months: interval, anchor: effectiveAnchor(for: day)).key
        case .year: return day.adding(months: 12 * interval, anchor: effectiveAnchor(for: day)).key
        }
    }

    /// The anchor that counts for a due day: the stored one while the due day is it, or that day clamped to a
    /// shorter month; otherwise the due day was moved by hand and its own day is the anchor now.
    func effectiveAnchor(for day: Day) -> Int {
        guard let anchorDay else { return day.day }
        if anchorDay == day.day { return anchorDay }
        if anchorDay > day.day, day.day == Day.daysInMonth(year: day.year, month: day.month) { return anchorDay }
        return day.day
    }

    /// The next due day after a to-do with due day `due` was done on `today` ("yyyy-MM-dd" both): the first
    /// occurrence after the due day that is after today. Without a due day it counts from today.
    func nextDue(after due: String?, today: String) -> String {
        let base = due.flatMap { Todos.isDueKey($0) ? $0 : nil } ?? today
        var next = advance(base) ?? today
        // Days and weeks overdue for long: jump close to today instead of stepping through every occurrence.
        if unit == .day || unit == .week, let from = Day(next), let to = Day(today), from.key <= to.key {
            let step = (unit == .week ? 7 : 1) * interval
            let behind = to.ordinal - from.ordinal
            next = from.adding(days: (behind / step) * step).key
        }
        var guardCount = 0
        while next <= today, guardCount < 10_000, let after = advance(next) {
            next = after
            guardCount += 1
        }
        return next
    }

    /// The rule with its anchor set from a due day (months and years).
    func anchored(to due: String?) -> TodoRepeat {
        guard unit == .month || unit == .year, let day = due.flatMap(Day.init) else { return self }
        return TodoRepeat(unit: unit, interval: interval, anchorDay: day.day)
    }

    /// A calendar day as year, month and day, with the arithmetic the rules need (proleptic Gregorian).
    struct Day: Equatable {
        var year: Int
        var month: Int
        var day: Int

        init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }

        init?(_ key: String) {
            guard Todos.isDueKey(key) else { return nil }
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, (1...12).contains(parts[1]),
                  (1...Day.daysInMonth(year: parts[0], month: parts[1])).contains(parts[2]) else { return nil }
            self.init(year: parts[0], month: parts[1], day: parts[2])
        }

        var key: String { String(format: "%04d-%02d-%02d", year, month, day) }

        static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }

        static func daysInMonth(year: Int, month: Int) -> Int {
            switch month {
            case 2: isLeap(year) ? 29 : 28
            case 4, 6, 9, 11: 30
            default: 31
            }
        }

        /// Days since 1 March of year 0 (a count that only goes up by one per day).
        var ordinal: Int {
            let y = month <= 2 ? year - 1 : year
            let m = month <= 2 ? month + 9 : month - 3
            return 365 * y + y / 4 - y / 100 + y / 400 + (306 * m + 5) / 10 + day - 1
        }

        init(ordinal: Int) {
            var y = (10000 * ordinal + 14780) / 3652425
            var doy = ordinal - (365 * y + y / 4 - y / 100 + y / 400)
            if doy < 0 {
                y -= 1
                doy = ordinal - (365 * y + y / 4 - y / 100 + y / 400)
            }
            let mi = (100 * doy + 52) / 3060
            let month = (mi + 2) % 12 + 1
            self.init(year: y + (mi + 2) / 12, month: month, day: doy - (mi * 306 + 5) / 10 + 1)
        }

        func adding(days: Int) -> Day { Day(ordinal: ordinal + days) }

        func adding(months: Int, anchor: Int) -> Day {
            let total = year * 12 + (month - 1) + months
            let y = total / 12, m = total % 12 + 1
            return Day(year: y, month: m, day: min(anchor, Day.daysInMonth(year: y, month: m)))
        }
    }
}

// MARK: - On the note

extension Note {
    /// The repeat rule of a to-do; nil = it does not repeat. Read while the note is a to-do (a note turned back
    /// keeps nothing: `Todos.setTodo` clears it).
    var todoRepeat: TodoRepeat? {
        get {
            guard let raw = todoSuggestionsRaw, raw.contains(TodoRepeat.storageKey) else { return nil }
            return TodoSuggestions.states(raw)[TodoRepeat.storageKey].flatMap(TodoRepeat.init(raw:))
        }
        set {
            var all = TodoSuggestions.states(todoSuggestionsRaw)
            all[TodoRepeat.storageKey] = newValue?.raw
            // Nothing else was in it: back to nil, as before the rule was set.
            todoSuggestionsRaw = all.isEmpty && newValue == nil && todoSuggestionsRaw?.contains(TodoRepeat.storageKey) == true
                ? nil : TodoSuggestions.encode(all)
        }
    }

    /// A to-do with a repeat rule.
    var isRepeating: Bool { isTodo && todoRepeat != nil }
}

extension Todos {
    /// A repeating to-do was done: the due day moves to the next occurrence, the subtasks are unticked, it stays
    /// open. Nothing is copied.
    static func rollOver(_ note: Note, now: Date = Date(), calendar: Calendar = .current) {
        guard let rule = note.todoRepeat else { return }
        let today = dueKey(now, calendar: calendar)
        let current = isDueKey(note.todoDueDay) ? note.todoDueDay : nil
        let next = rule.nextDue(after: current, today: today)
        // The anchor stays the day it was set on, or follows a due day moved by hand.
        if let currentDay = current.flatMap(TodoRepeat.Day.init), rule.unit == .month || rule.unit == .year {
            let anchor = rule.effectiveAnchor(for: currentDay)
            if anchor != rule.anchorDay { note.todoRepeat = TodoRepeat(unit: rule.unit, interval: rule.interval, anchorDay: anchor) }
        }
        note.todoDueDay = next
        note.text = setAll(false, in: note.text)
        note.todoState = .open
        note.todoDoneAt = nil
    }
}

@MainActor
extension Todos {
    /// Sets or takes away the repeat rule. A rule without a due day starts today.
    static func setRepeat(_ rule: TodoRepeat?, _ note: Note, in context: ModelContext, now: Date = Date()) {
        guard note.isTodo else { return }
        if let rule {
            if note.todoDue == nil { note.todoDueDay = dueKey(now) }
            note.todoRepeat = rule.anchored(to: note.todoDueDay)
            // A done to-do that gets a rule starts its next round.
            if note.isDone { rollOver(note, now: now) }
        } else {
            guard note.todoRepeat != nil else { return }
            note.todoRepeat = nil
        }
        note.updatedAt = Date()
        guard note.modelContext != nil else { return }
        try? context.save()
    }
}
