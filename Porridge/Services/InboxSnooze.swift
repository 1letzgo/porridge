import Foundation
import Observation
import SwiftData
import UserNotifications

/// "Later" for Inbox entries: an entry is put away until a time. Until then it is not in the Inbox list and not in
/// its count (search finds it, and the Inbox's "Later" section lists it); then it is back in the Inbox, marked
/// "Back from Later" for a day, and a notification says so. Nothing is archived and nothing goes away by itself.
///
/// Stored without a field of its own (the CloudKit schema stays as it is): in the JSON object of
/// `Note.todoSuggestionsRaw` under the reserved key `@snooze` as whole seconds since 1970, e.g.
/// `{"@snooze":"1795000000"}` (task keys never contain "@", see `TodoSuggestions.key`). The time stays after it has
/// passed: it is what says "Back from Later". A note that had no suggestion states gets `@unoffered` with it, so the
/// object being there does not count as "suggestions offered" (`Note.offersTodoSuggestions`).
enum InboxSnooze {
    /// The key in `Note.todoSuggestionsRaw`.
    static let storageKey = "@snooze"
    /// Marks an object that exists only for the snooze: no to-do suggestions were offered for the note.
    static let unofferedKey = "@unoffered"
    /// How long an entry is marked "Back from Later".
    static let backWindow: TimeInterval = 24 * 3600
    /// No notification between 22:00 and 8:00: one due then comes at 8:00.
    static let quietStart = 22
    static let quietEnd = 8

    // MARK: Choices

    enum Choice: String, CaseIterable, Identifiable {
        case laterToday, thisEvening, tomorrow, thisWeekend, nextWeek

        var id: String { rawValue }

        var title: String {
            switch self {
            case .laterToday: String(localized: "Later Today")
            case .thisEvening: String(localized: "This Evening")
            case .tomorrow: String(localized: "Tomorrow")
            case .thisWeekend: String(localized: "This Weekend")
            case .nextWeek: String(localized: "Next Week")
            }
        }

        var systemImage: String {
            switch self {
            case .laterToday: "clock"
            case .thisEvening: "moon"
            case .tomorrow: "sunrise"
            case .thisWeekend: "sofa"
            case .nextWeek: "calendar"
            }
        }
    }

    /// When a choice puts an entry back; nil when it makes no sense now (the evening after 17:00, the weekend on one).
    /// Later Today: three hours on, at the full hour, until 21:00. This Evening: 18:00. Tomorrow: 9:00.
    /// This Weekend: Saturday 9:00. Next Week: Monday 9:00.
    static func date(for choice: Choice, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        func at(_ hour: Int, daysFrom day: Date, _ days: Int = 0) -> Date? {
            guard let base = calendar.date(byAdding: .day, value: days, to: day) else { return nil }
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)
        }
        switch choice {
        case .laterToday:
            let inThree = now.addingTimeInterval(3 * 3600)
            // To the next full hour.
            let hour = calendar.dateInterval(of: .hour, for: inThree).map { $0.start == inThree ? $0.start : $0.end } ?? inThree
            guard let limit = at(21, daysFrom: today), hour <= limit, calendar.isDate(hour, inSameDayAs: now) else { return nil }
            return hour
        case .thisEvening:
            guard let evening = at(18, daysFrom: today), evening.timeIntervalSince(now) >= 3600 else { return nil }
            return evening
        case .tomorrow:
            return at(9, daysFrom: today, 1)
        case .thisWeekend:
            guard !calendar.isDateInWeekend(now) else { return nil }
            guard let saturday = calendar.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime) else { return nil }
            return at(9, daysFrom: calendar.startOfDay(for: saturday))
        case .nextWeek:
            guard let monday = calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) else { return nil }
            return at(9, daysFrom: calendar.startOfDay(for: monday))
        }
    }

    /// The choices that make sense now, each with its time.
    static func choices(now: Date = Date(), calendar: Calendar = .current) -> [(choice: Choice, date: Date)] {
        Choice.allCases.compactMap { choice in date(for: choice, now: now, calendar: calendar).map { (choice, $0) } }
    }

    /// "18:00", "Tomorrow 09:00", "Sat 09:00", "3 Dec 09:00": when an entry comes back, short.
    static func timeLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow \(time)")
        }
        if date > now, date.timeIntervalSince(now) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }

    // MARK: Notification time

    /// When the notification for an entry back at `date` is shown: at that time, or at 8:00 when it falls between
    /// 22:00 and 8:00.
    static func notificationDate(for date: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: date)
        let day = calendar.startOfDay(for: date)
        if hour >= quietStart {
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            return calendar.date(bySettingHour: quietEnd, minute: 0, second: 0, of: next) ?? date
        }
        if hour < quietEnd {
            return calendar.date(bySettingHour: quietEnd, minute: 0, second: 0, of: day) ?? date
        }
        return date
    }

    // MARK: How long it waits

    /// How long an entry has been waiting in the Inbox, quiet: nil under a day, then "1 day", "5 days", "3 weeks",
    /// "4 months".
    static func waitingLabel(since start: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return nil
        case 1: return String(localized: "1 day")
        case 2..<14: return String(localized: "\(days) days")
        case 14..<60: return String(localized: "\(days / 7) weeks")
        default: return String(localized: "\(days / 30) months")
        }
    }

    // MARK: Stored form

    static func raw(_ date: Date) -> String { String(Int(date.timeIntervalSince1970.rounded())) }

    static func date(raw: String) -> Date? {
        guard let seconds = Double(raw), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - On the note

extension Note {
    /// The time a "Later" puts the entry back into the Inbox; it stays after it has passed. nil = never put away.
    var snoozedUntil: Date? {
        get {
            guard let raw = todoSuggestionsRaw, raw.contains(InboxSnooze.storageKey) else { return nil }
            return TodoSuggestions.states(raw)[InboxSnooze.storageKey].flatMap(InboxSnooze.date(raw:))
        }
        set {
            let had = todoSuggestionsRaw
            var all = TodoSuggestions.states(had)
            if let newValue {
                // No states before: the object is only here for the snooze, no suggestions are offered by it.
                if had == nil { all[InboxSnooze.unofferedKey] = "1" }
                all[InboxSnooze.storageKey] = InboxSnooze.raw(newValue)
            } else {
                guard all[InboxSnooze.storageKey] != nil else { return }
                all[InboxSnooze.storageKey] = nil
            }
            // Nothing else left in it: back to nil, as before.
            let rest = all.keys.filter { $0 != InboxSnooze.unofferedKey }
            todoSuggestionsRaw = rest.isEmpty && all[InboxSnooze.unofferedKey] != nil ? nil : TodoSuggestions.encode(all)
        }
    }

    /// Put away with "Later" and not back yet: hidden from the Inbox.
    func isSnoozed(now: Date = Date()) -> Bool {
        guard isInInbox, let until = snoozedUntil else { return false }
        return until > now
    }

    /// Back in the Inbox from "Later" within the last day.
    func isBackFromLater(now: Date = Date()) -> Bool {
        guard isInInbox, let until = snoozedUntil else { return false }
        return until <= now && now.timeIntervalSince(until) < InboxSnooze.backWindow
    }

    /// In the Inbox and shown there: in no bowl and not put away for later.
    func isWaitingInInbox(now: Date = Date()) -> Bool {
        isInInbox && !isSnoozed(now: now)
    }
}

// MARK: - Changing it

@MainActor
extension InboxSnooze {
    /// Puts the entries away until `date` (only Inbox entries; nothing in a view-only bowl), with an undo toast.
    static func snooze(_ notes: [Note], until date: Date, in context: ModelContext) {
        let notes = notes.filter { $0.isInInbox && !$0.isDeleted && !BowlSharing.shared.isReadOnly($0) }
        guard !notes.isEmpty else { return }
        let when = timeLabel(date)
        let message = notes.count == 1 ? String(localized: "Later: back \(when)") : String(localized: "\(notes.count) entries later: back \(when)")
        Undoable.run(message, systemImage: "clock", notes: notes, in: context) {
            let now = Date()
            for note in notes {
                note.snoozedUntil = date
                note.updatedAt = now
            }
            try? context.save()
        }
        InboxSnoozeScheduler.shared.askForNotifications()
    }

    /// Back into the Inbox now.
    static func unsnooze(_ notes: [Note], in context: ModelContext) {
        let notes = notes.filter { $0.isSnoozed() && !BowlSharing.shared.isReadOnly($0) }
        guard !notes.isEmpty else { return }
        let message = notes.count == 1 ? String(localized: "Back in the Inbox") : String(localized: "\(notes.count) entries back in the Inbox")
        Undoable.run(message, systemImage: "tray", notes: notes, in: context) {
            let now = Date()
            for note in notes {
                note.snoozedUntil = nil
                note.updatedAt = now
            }
            try? context.save()
        }
    }

    /// The entries put away for later, the next to come back first.
    static func snoozed(_ notes: [Note], now: Date = Date()) -> [Note] {
        notes.filter { $0.isSnoozed(now: now) }.sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
    }
}

// MARK: - Coming back

/// Follows the entries put away for later on this device: plans one local notification for each (from the synced
/// data, on every device), and ticks when one comes back or its "Back from Later" ends, so the lists show it.
@MainActor
@Observable
final class InboxSnoozeScheduler {
    static let shared = InboxSnoozeScheduler()

    static let prefix = "snooze-"
    /// iOS keeps at most 64 planned notifications per app (the meeting alerts take some).
    static let maximum = 30

    /// Goes up whenever an entry comes back or stops being "Back from Later": lists read it to be built again.
    private(set) var tick = 0
    /// Also called then (the Mac's library).
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var planned: [String: Date] = [:]

    private init() {}

    /// Plans the notifications and the next tick from the notes. Cheap when nothing changed.
    func refresh(_ notes: [Note], now: Date = Date()) {
        var wanted: [String: (date: Date, title: String)] = [:]
        var next: Date?
        for note in notes where note.isInInbox {
            guard let until = note.snoozedUntil else { continue }
            if until > now {
                wanted[Self.prefix + note.id.uuidString] = (until, note.displayTitle)
                next = min(next ?? until, until)
            } else {
                let end = until.addingTimeInterval(InboxSnooze.backWindow)
                if end > now { next = min(next ?? end, end) }
            }
        }
        schedule(next)
        let dates = wanted.mapValues(\.date)
        guard dates != planned else { return }
        planned = dates
        plan(wanted, now: now)
    }

    private func schedule(_ date: Date?) {
        timer?.cancel()
        guard let date else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, date.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled, let self else { return }
            self.tick += 1
            self.onChange?()
        }
    }

    private func plan(_ wanted: [String: (date: Date, title: String)], now: Date) {
        Task {
            let center = UNUserNotificationCenter.current()
            let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard !wanted.isEmpty, await Self.isAllowed() else { return }
            for (id, entry) in wanted.sorted(by: { $0.value.date < $1.value.date }).prefix(Self.maximum) {
                let wait = InboxSnooze.notificationDate(for: entry.date).timeIntervalSince(now)
                guard wait > 1 else { continue }
                let content = UNMutableNotificationContent()
                content.title = String(localized: "Back from Later")
                content.body = entry.title
                content.sound = .default
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }

    private static func isAllowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        #if os(iOS)
        return status == .authorized || status == .provisional || status == .ephemeral
        #else
        return status == .authorized || status == .provisional
        #endif
    }

    /// The first "Later" asks whether notifications may be shown (once; never at launch).
    func askForNotifications() {
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            // Asked now: what was put away gets its notification.
            planned = [:]
            tick += 1
            onChange?()
        }
    }

}
