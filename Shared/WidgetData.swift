import Foundation

/// What the widgets show, written by the app into the app group (`WidgetStore`). The widget extension cannot open
/// the notes: the SwiftData store lives in the app's own container (and syncs through CloudKit from there), so the
/// app keeps this small copy of what the widgets need, and rewrites it whenever the notes change.
struct WidgetSnapshot: Codable, Equatable {
    /// One entry of the inbox, as a widget lists it.
    struct Entry: Codable, Equatable, Identifiable {
        /// `Note.id` as uppercase string.
        var id: String
        var title: String
        /// The SF Symbol of the entry's kind (`Note.kindSymbol`).
        var symbol: String
    }

    /// One open to-do.
    struct Todo: Codable, Equatable, Identifiable {
        /// `Note.id` as uppercase string.
        var id: String
        var title: String
        /// "yyyy-MM-dd" (`Note.todoDue`); nil = no due day.
        var due: String?
        var isRepeating = false
        /// In a bowl shared with me to view only: the widget shows it without a box to tick.
        var isReadOnly = false
    }

    var generatedAt = Date()
    /// Everything that waits in the inbox.
    var inboxCount = 0
    /// The newest entries of the inbox, newest first (a few).
    var inbox: [Entry] = []
    /// Every open to-do.
    var openTodoCount = 0
    /// Open to-dos by due day, earliest first, those without a due day last (capped).
    var todos: [Todo] = []

    /// How many inbox entries and to-dos the snapshot carries at most.
    static let inboxLimit = 8
    static let todoLimit = 60

    /// The day as it is stored in `Note.todoDueDay`: "yyyy-MM-dd" in the calendar's time zone.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The snapshot with to-dos ticked in a widget that the app has not taken in yet (`WidgetStore.pendingCompletions`):
    /// they leave the list at once. A repeating one stays open (it moves to its next due day, which is after today),
    /// so it still counts.
    func applying(_ pending: [WidgetStore.Completion]) -> WidgetSnapshot {
        guard !pending.isEmpty else { return self }
        let ids = Set(pending.map(\.id))
        var copy = self
        let ticked = todos.filter { ids.contains($0.id) }
        copy.todos.removeAll { ids.contains($0.id) }
        copy.openTodoCount = max(0, openTodoCount - ticked.filter { !$0.isRepeating }.count)
        return copy
    }

    /// The to-dos for today: the overdue ones first (earliest first), then those due today.
    func dueToday(now: Date = Date(), calendar: Calendar = .current) -> [Todo] {
        let today = Self.dayKey(now, calendar: calendar)
        let due = todos.filter { ($0.due ?? "9999") <= today }
        // Keys are zero-padded, so they sort like the days they name; the order otherwise stays.
        return due.enumerated().sorted { a, b in
            let x = a.element.due ?? "", y = b.element.due ?? ""
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// How many of `dueToday` are overdue.
    func overdueCount(now: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = Self.dayKey(now, calendar: calendar)
        return todos.filter { ($0.due ?? "9999") < today }.count
    }

    static func isOverdue(_ todo: Todo, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due = todo.due else { return false }
        return due < dayKey(now, calendar: calendar)
    }

    /// The due day for a widget row: "Today", "Yesterday", or day and month ("12 Nov").
    static func dueLabel(_ key: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let due = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return "" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: due).day ?? 0
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        case -1: return String(localized: "Yesterday")
        default: break
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: due) == calendar.component(.year, from: now) ? "dMMM" : "dMMMy")
        return formatter.string(from: due)
    }
}

/// The files the app and the widget extension share in the app group: the snapshot the widgets show, and the
/// to-dos ticked in a widget that wait for the app.
///
/// A box ticked in a widget runs in the widget extension, which cannot open the notes. It is queued here, the
/// widget drops it from its list at once, and the app applies it through `Todos.setDone` (repeat rules and view-only
/// bowls included) as soon as it runs: right away when it is open (a Darwin notification wakes it), otherwise at
/// its next start or return to the foreground.
enum WidgetStore {
    static let groupID = "group.de.letzgo.porridge"

    /// The widget kinds, for reloading them.
    enum Kind {
        static let todos = "de.letzgo.porridge.widget.todos"
        static let inbox = "de.letzgo.porridge.widget.inbox"
        static let inboxCount = "de.letzgo.porridge.widget.inboxCount"
        static let todoCount = "de.letzgo.porridge.widget.todoCount"
        static let newNote = "de.letzgo.porridge.widget.newNote"
    }

    /// A to-do ticked in a widget.
    struct Completion: Codable, Equatable {
        /// `Note.id` as uppercase string.
        var id: String
        /// The due day the widget showed: a repeating to-do is only moved on if it still has it, so a tick that
        /// arrives late never skips a second occurrence.
        var due: String?
        var date = Date()
    }

    /// Overridden by tests.
    nonisolated(unsafe) static var rootOverride: URL?

    private static var root: URL? {
        rootOverride ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    private static var snapshotURL: URL? { root?.appendingPathComponent("WidgetSnapshot.json") }
    private static var completionsURL: URL? { root?.appendingPathComponent("WidgetCompletions.json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    static func snapshot() -> WidgetSnapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot when it differs from the one there (the time it was made aside). True when it changed.
    @discardableResult
    static func write(_ snapshot: WidgetSnapshot) -> Bool {
        guard let snapshotURL else { return false }
        if var old = self.snapshot() {
            old.generatedAt = snapshot.generatedAt
            if old == snapshot { return false }
        }
        guard let data = try? encoder.encode(snapshot) else { return false }
        return (try? data.write(to: snapshotURL, options: .atomic)) != nil
    }

    // MARK: To-dos ticked in a widget

    static func pendingCompletions() -> [Completion] {
        guard let completionsURL else { return [] }
        var result: [Completion] = []
        NSFileCoordinator().coordinate(readingItemAt: completionsURL, options: [], error: nil) { url in
            result = read(url)
        }
        return result
    }

    /// Queues a tick; a second tick of the same to-do replaces the first.
    static func queueCompletion(_ completion: Completion) {
        update { all in
            all.removeAll { $0.id == completion.id }
            all.append(completion)
        }
    }

    /// Takes the handled ticks out of the queue (the app, once it applied or dropped them). Only these ticks: one
    /// queued for the same to-do meanwhile (a widget and the app run at once) stays for the next time.
    static func removeCompletions(_ handled: [Completion]) {
        guard !handled.isEmpty else { return }
        update { all in all.removeAll { handled.contains($0) } }
    }

    private static func read(_ url: URL) -> [Completion] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Completion].self, from: data)) ?? []
    }

    /// Reads, changes and writes the queue as one step: the widget extension and the app share the file, so each
    /// waits for the other (`NSFileCoordinator`).
    private static func update(_ change: (inout [Completion]) -> Void) {
        guard let completionsURL else { return }
        NSFileCoordinator().coordinate(writingItemAt: completionsURL, options: .forMerging, error: nil) { url in
            var all = read(url)
            change(&all)
            if all.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? encoder.encode(all) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: Telling the running app

    /// Posted across processes when a widget queued something for the app.
    static let darwinNotification = "de.letzgo.porridge.widgetAction"

    static func notifyApp() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(darwinNotification as CFString), nil, nil, true
        )
    }

    /// The app listens once: a widget's tick arrives as `Notification.Name.porridgeWidgetAction`.
    static func observeWidgetActions() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { NotificationCenter.default.post(name: .porridgeWidgetAction, object: nil) }
            },
            darwinNotification as CFString, nil, .deliverImmediately
        )
    }
}

extension Notification.Name {
    /// A widget queued a tick (`WidgetStore`).
    static let porridgeWidgetAction = Notification.Name("de.letzgo.porridge.widgetAction")
    /// A shortcut put something into the share inbox (`ShareInbox`): the app takes it in when it runs.
    static let porridgeShareInboxChanged = Notification.Name("de.letzgo.porridge.shareInboxChanged")
}

/// Set by the app while its list is on screen: a widget's tick that runs in the app's own process is applied at once.
@MainActor
enum WidgetBridge {
    /// Ticks the to-do (`id`, the due day the widget showed); false when it could not be applied here.
    static var complete: ((WidgetStore.Completion) -> Bool)?
}
