import EventKit
import Foundation

/// Whether Porridge may read and write Reminders.
enum ReminderAccess: Equatable {
    case granted
    case denied
    case notDetermined
}

/// A list in Reminders.
struct ReminderListInfo: Equatable {
    /// `calendarIdentifier` (of this device).
    var id: String
    var title: String
    /// The account (`EKSource.sourceIdentifier`).
    var account: String
    var isWritable = true
    var isSubscribed = false
}

/// A reminder as read from Reminders.
struct ReminderItem: Equatable {
    /// `calendarItemIdentifier` (of this device).
    var localID: String
    /// `calendarItemExternalIdentifier`: the same on every device (may be missing until it was saved).
    var externalID: String?
    var listID: String
    var title: String
    var notes: String
    var isDone: Bool
    var due: DateComponents?
    var url: URL?
    var created: Date?

    /// The external identifier, or the local one while there is none.
    var stableID: String { externalID.flatMap { $0.isEmpty ? nil : $0 } ?? localID }
}

/// What is written into a reminder.
struct ReminderWrite: Equatable {
    /// nil: a new reminder.
    var localID: String?
    var listID: String
    var title: String
    var notes: String
    var isDone: Bool
    var due: DateComponents?
    var url: URL
}

enum ReminderStoreError: Error {
    case noList
    case notFound
    case noAccount
}

/// Reminders as the sync with it uses them (`ReminderSyncEngine`): behind a protocol, so tests run against a stand-in
/// and never against the real Reminders.
@MainActor
protocol ReminderStore: AnyObject {
    var access: ReminderAccess { get }
    func requestAccess() async -> Bool
    func lists() -> [ReminderListInfo]
    /// The list new reminders go into by default (`defaultCalendarForNewReminders`).
    func defaultListID() -> String?
    /// A new list in the account of the default list.
    func createList(title: String) throws -> ReminderListInfo
    func renameList(_ id: String, to title: String) throws
    func deleteList(_ id: String) throws
    /// Every reminder of these lists, done ones included.
    func reminders(in listIDs: [String]) async -> [ReminderItem]
    func reminder(externalID: String) -> ReminderItem?
    /// Saves a reminder (a new one without `localID`), into `listID`; returns it as saved.
    func save(_ write: ReminderWrite) throws -> ReminderItem
    func deleteReminder(localID: String) throws
}

/// Reminders through EventKit. Only reminders: the calendar stays read only (`CalendarAccess`).
@MainActor
final class EventKitReminderStore: ReminderStore {
    private var store = EKEventStore()

    /// Posted when Reminders changed (here or synced).
    var changedNotification: Notification.Name { .EKEventStoreChanged }

    var access: ReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        // A store made before access was given may not see the lists: a fresh one.
        if granted { store = EKEventStore() }
        return granted
    }

    func lists() -> [ReminderListInfo] {
        guard access == .granted else { return [] }
        return store.calendars(for: .reminder).map(Self.info)
    }

    func defaultListID() -> String? {
        guard access == .granted else { return nil }
        return store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    func createList(title: String) throws -> ReminderListInfo {
        guard let source = store.defaultCalendarForNewReminders()?.source else { throw ReminderStoreError.noAccount }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = title
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return Self.info(calendar)
    }

    func renameList(_ id: String, to title: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else { throw ReminderStoreError.noList }
        calendar.title = title
        try store.saveCalendar(calendar, commit: true)
    }

    func deleteList(_ id: String) throws {
        guard let calendar = store.calendar(withIdentifier: id) else { return }
        try store.removeCalendar(calendar, commit: true)
    }

    func reminders(in listIDs: [String]) async -> [ReminderItem] {
        let calendars = listIDs.compactMap { store.calendar(withIdentifier: $0) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForReminders(in: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(EventKitReminderStore.item))
            }
        }
    }

    func reminder(externalID: String) -> ReminderItem? {
        store.calendarItems(withExternalIdentifier: externalID).compactMap { $0 as? EKReminder }.first.map(Self.item)
    }

    func save(_ write: ReminderWrite) throws -> ReminderItem {
        guard let calendar = store.calendar(withIdentifier: write.listID) else { throw ReminderStoreError.noList }
        let reminder: EKReminder
        if let id = write.localID {
            guard let existing = store.calendarItem(withIdentifier: id) as? EKReminder else { throw ReminderStoreError.notFound }
            reminder = existing
        } else {
            reminder = EKReminder(eventStore: store)
        }
        if reminder.calendar?.calendarIdentifier != calendar.calendarIdentifier { reminder.calendar = calendar }
        if reminder.title != write.title { reminder.title = write.title }
        if (reminder.notes ?? "") != write.notes { reminder.notes = write.notes.isEmpty ? nil : write.notes }
        if reminder.isCompleted != write.isDone { reminder.isCompleted = write.isDone }
        if reminder.dueDateComponents != write.due { reminder.dueDateComponents = write.due }
        if reminder.url != write.url { reminder.url = write.url }
        try store.save(reminder, commit: true)
        return Self.item(reminder)
    }

    func deleteReminder(localID: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: localID) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    private static func info(_ calendar: EKCalendar) -> ReminderListInfo {
        ReminderListInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            account: calendar.source?.sourceIdentifier ?? "",
            isWritable: calendar.allowsContentModifications,
            isSubscribed: calendar.isSubscribed || calendar.isImmutable || calendar.type == .subscription
        )
    }

    nonisolated private static func item(_ reminder: EKReminder) -> ReminderItem {
        ReminderItem(
            localID: reminder.calendarItemIdentifier,
            externalID: reminder.calendarItemExternalIdentifier,
            listID: reminder.calendar?.calendarIdentifier ?? "",
            title: reminder.title ?? "",
            notes: reminder.notes ?? "",
            isDone: reminder.isCompleted,
            due: reminder.dueDateComponents,
            url: reminder.url,
            created: reminder.creationDate
        )
    }
}
