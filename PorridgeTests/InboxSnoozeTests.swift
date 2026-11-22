import SwiftData
import XCTest
@testable import Porridge

/// "Later" for Inbox entries: how it is stored, what the Inbox shows, when an entry comes back and when its
/// notification is shown.
@MainActor
final class InboxSnoozeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: Stored form

    func testSnoozeIsStoredUnderAReservedKeyAndGoesAwayWithoutATrace() {
        let note = Note()
        let until = Date(timeIntervalSince1970: 1_795_000_000)
        note.snoozedUntil = until
        XCTAssertEqual(note.snoozedUntil, until)
        XCTAssertEqual(TodoSuggestions.states(note.todoSuggestionsRaw)[InboxSnooze.storageKey], "1795000000")
        // A note that had no suggestion states is not one with suggestions offered because of it.
        XCTAssertEqual(TodoSuggestions.states(note.todoSuggestionsRaw)[InboxSnooze.unofferedKey], "1")
        note.summary = "Tasks:\n- Call Anna"
        XCTAssertFalse(note.offersTodoSuggestions)

        note.snoozedUntil = nil
        XCTAssertNil(note.todoSuggestionsRaw)
        XCTAssertNil(note.snoozedUntil)
    }

    func testSnoozeKeepsSuggestionStatesAndTheRepeatRule() {
        let note = Note()
        note.todoSuggestionsRaw = TodoSuggestions.encode(["call anna": TodoSuggestions.taken])
        note.summary = "Tasks:\n- Call Anna"
        XCTAssertTrue(note.offersTodoSuggestions)
        note.snoozedUntil = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(note.offersTodoSuggestions)
        XCTAssertEqual(TodoSuggestions.states(note.todoSuggestionsRaw)["call anna"], TodoSuggestions.taken)
        XCTAssertNil(TodoSuggestions.states(note.todoSuggestionsRaw)[InboxSnooze.unofferedKey])

        note.snoozedUntil = nil
        XCTAssertEqual(TodoSuggestions.states(note.todoSuggestionsRaw), ["call anna": TodoSuggestions.taken])

        let todo = Note()
        todo.todoState = .open
        todo.todoRepeat = .weekly
        todo.snoozedUntil = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(todo.todoRepeat, .weekly)
        todo.snoozedUntil = nil
        XCTAssertEqual(todo.todoRepeat, .weekly)
        XCTAssertNil(todo.snoozedUntil)
    }

    func testASummaryWrittenWhileSnoozedOffersItsTasks() {
        let note = Note()
        note.snoozedUntil = Date(timeIntervalSince1970: 1_800_000_000)
        note.summary = "Tasks:\n- Call Anna"
        TodoSuggestions.offer(note)
        XCTAssertTrue(note.offersTodoSuggestions)
        XCTAssertNotNil(note.snoozedUntil)
        note.snoozedUntil = nil
        XCTAssertEqual(note.todoSuggestionsRaw, "{}")
    }

    func testGarbageIsNoSnooze() {
        let note = Note()
        note.todoSuggestionsRaw = #"{"@snooze":"soon"}"#
        XCTAssertNil(note.snoozedUntil)
        XCTAssertFalse(note.isSnoozed())
    }

    // MARK: The Inbox

    func testASnoozedEntryLeavesTheInboxUntilItsTimeAndIsMarkedForADay() throws {
        let context = try TestStore.context()
        let now = date(2026, 11, 22, 10)
        let a = Note(), b = Note(), filed = Note()
        a.createdAt = now.addingTimeInterval(-3600)
        b.createdAt = now.addingTimeInterval(-7200)
        filed.projectIDs = ["X"]
        [a, b, filed].forEach(context.insert)
        a.snoozedUntil = date(2026, 11, 23, 9)
        filed.snoozedUntil = date(2026, 11, 23, 9)

        XCTAssertEqual(Inbox.notes([a, b, filed], now: now).map(\.id), [b.id])
        XCTAssertTrue(a.isSnoozed(now: now))
        XCTAssertTrue(a.isInInbox)
        // Snooze is for the Inbox: in a bowl the entry is there as always.
        XCTAssertFalse(filed.isSnoozed(now: now))
        XCTAssertEqual(InboxSnooze.snoozed([a, b, filed], now: now).map(\.id), [a.id])

        let back = date(2026, 11, 23, 9, 30)
        XCTAssertEqual(Inbox.notes([a, b, filed], now: back).map(\.id), [a.id, b.id])
        XCTAssertTrue(a.isBackFromLater(now: back))
        XCTAssertFalse(a.isBackFromLater(now: date(2026, 11, 24, 9, 30)))
        XCTAssertFalse(b.isBackFromLater(now: back))
    }

    func testSnoozeAndUnsnoozeCanBeUndone() throws {
        let context = try TestStore.context()
        let note = Note()
        context.insert(note)
        let toast = UndoToast.shared
        let until = Date().addingTimeInterval(3600)
        InboxSnooze.snooze([note], until: until, in: context)
        XCTAssertTrue(note.isSnoozed())
        XCTAssertNotNil(toast.current)
        toast.undo()
        XCTAssertFalse(note.isSnoozed())
        XCTAssertNil(note.todoSuggestionsRaw)

        InboxSnooze.snooze([note], until: until, in: context)
        InboxSnooze.unsnooze([note], in: context)
        XCTAssertFalse(note.isSnoozed())
        XCTAssertTrue(Inbox.notes([note]).contains { $0.id == note.id })
    }

    func testOnlyInboxEntriesAreSnoozed() throws {
        let context = try TestStore.context()
        let filed = Note()
        filed.projectIDs = ["X"]
        context.insert(filed)
        InboxSnooze.snooze([filed], until: Date().addingTimeInterval(3600), in: context)
        XCTAssertNil(filed.snoozedUntil)
    }

    // MARK: Times

    func testQuickChoices() {
        // Sunday 22 Nov 2026, 10:20.
        let sunday = date(2026, 11, 22, 10, 20)
        XCTAssertEqual(InboxSnooze.date(for: .laterToday, now: sunday, calendar: calendar), date(2026, 11, 22, 14))
        XCTAssertEqual(InboxSnooze.date(for: .thisEvening, now: sunday, calendar: calendar), date(2026, 11, 22, 18))
        XCTAssertEqual(InboxSnooze.date(for: .tomorrow, now: sunday, calendar: calendar), date(2026, 11, 23, 9))
        // On the weekend there is no "This Weekend".
        XCTAssertNil(InboxSnooze.date(for: .thisWeekend, now: sunday, calendar: calendar))
        XCTAssertEqual(InboxSnooze.date(for: .nextWeek, now: sunday, calendar: calendar), date(2026, 11, 23, 9))

        // Wednesday 25 Nov 2026, 19:00: the evening is gone, later today too.
        let wednesday = date(2026, 11, 25, 19)
        XCTAssertNil(InboxSnooze.date(for: .laterToday, now: wednesday, calendar: calendar))
        XCTAssertNil(InboxSnooze.date(for: .thisEvening, now: wednesday, calendar: calendar))
        XCTAssertEqual(InboxSnooze.date(for: .thisWeekend, now: wednesday, calendar: calendar), date(2026, 11, 28, 9))
        XCTAssertEqual(InboxSnooze.date(for: .nextWeek, now: wednesday, calendar: calendar), date(2026, 11, 30, 9))
        XCTAssertEqual(InboxSnooze.choices(now: wednesday, calendar: calendar).map(\.choice), [.tomorrow, .thisWeekend, .nextWeek])

        // Later today on the full hour.
        XCTAssertEqual(InboxSnooze.date(for: .laterToday, now: date(2026, 11, 25, 9), calendar: calendar), date(2026, 11, 25, 12))
    }

    func testNotificationsWaitForTheEndOfQuietHours() {
        XCTAssertEqual(InboxSnooze.notificationDate(for: date(2026, 11, 23, 9), calendar: calendar), date(2026, 11, 23, 9))
        XCTAssertEqual(InboxSnooze.notificationDate(for: date(2026, 11, 23, 21, 59), calendar: calendar), date(2026, 11, 23, 21, 59))
        XCTAssertEqual(InboxSnooze.notificationDate(for: date(2026, 11, 23, 22), calendar: calendar), date(2026, 11, 24, 8))
        XCTAssertEqual(InboxSnooze.notificationDate(for: date(2026, 11, 23, 23, 30), calendar: calendar), date(2026, 11, 24, 8))
        XCTAssertEqual(InboxSnooze.notificationDate(for: date(2026, 11, 24, 3), calendar: calendar), date(2026, 11, 24, 8))
        XCTAssertEqual(InboxSnooze.notificationDate(for: date(2026, 11, 24, 8), calendar: calendar), date(2026, 11, 24, 8))
        // Across the end of a month.
        XCTAssertEqual(InboxSnooze.notificationDate(for: date(2026, 11, 30, 23), calendar: calendar), date(2026, 12, 1, 8))
    }

    func testWaitingLabel() {
        let now = date(2026, 11, 22, 10)
        XCTAssertNil(InboxSnooze.waitingLabel(since: date(2026, 11, 22, 1), now: now, calendar: calendar))
        XCTAssertEqual(InboxSnooze.waitingLabel(since: date(2026, 11, 21, 23), now: now, calendar: calendar), "1 day")
        XCTAssertEqual(InboxSnooze.waitingLabel(since: date(2026, 11, 17, 10), now: now, calendar: calendar), "5 days")
        XCTAssertEqual(InboxSnooze.waitingLabel(since: date(2026, 11, 1, 10), now: now, calendar: calendar), "3 weeks")
        XCTAssertEqual(InboxSnooze.waitingLabel(since: date(2026, 7, 1, 10), now: now, calendar: calendar), "4 months")
    }
}
