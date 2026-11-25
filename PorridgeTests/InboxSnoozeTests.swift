import SwiftData
import XCTest
@testable import Porridge

/// What is left of "Later" (owner revision 9 took it away): entries that were put away are in the Inbox like every
/// other entry in no bowl, the old keys keep meaning "nothing offered" and go with the next change of the
/// suggestions; and how long an entry has been waiting.
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

    /// A note as an older version left it after "Later": the time far ahead, the device, and `@unoffered`.
    private func putAwayBefore(_ note: Note) {
        note.todoSuggestionsRaw = TodoSuggestions.encode([
            InboxSnooze.storageKey: "4102444800", InboxSnooze.deviceKey: "another device", InboxSnooze.unofferedKey: "1",
        ])
    }

    func testEntriesPutAwayBeforeAreInTheInboxAndCounted() throws {
        let context = try TestStore.context()
        let a = Note(), b = Note(), filed = Note()
        a.createdAt = Date().addingTimeInterval(-3600)
        b.createdAt = Date().addingTimeInterval(-7200)
        filed.projectIDs = ["X"]
        [a, b, filed].forEach(context.insert)
        putAwayBefore(a)
        XCTAssertEqual(Inbox.notes([a, b, filed]).map(\.id), [a.id, b.id])
        XCTAssertEqual(Places.inboxCount([a, b, filed]), 2)
        var triage = InboxTriage(notes: [a, b, filed])
        XCTAssertEqual(triage.current(in: [a, b, filed])?.note.id, a.id)
        triage.advance(in: [a, b, filed])
        XCTAssertEqual(triage.current(in: [a, b, filed])?.note.id, b.id)
    }

    func testTheOldKeysStillSayNothingWasOfferedAndGoWithSuggestAgain() throws {
        let context = try TestStore.context()
        let note = Note()
        note.summary = "Tasks:\n- Call Anna"
        context.insert(note)
        putAwayBefore(note)
        XCTAssertFalse(note.offersTodoSuggestions, "the object was only there for the Later")
        TodoSuggestions.suggestAgain(note, in: context)
        XCTAssertTrue(note.offersTodoSuggestions)
        let states = TodoSuggestions.states(note.todoSuggestionsRaw)
        XCTAssertNil(states[InboxSnooze.storageKey])
        XCTAssertNil(states[InboxSnooze.deviceKey])
        XCTAssertNil(states[InboxSnooze.unofferedKey])
    }

    func testPrunedKeepsTheTaskStates() {
        let states = [InboxSnooze.storageKey: "1795000000", InboxSnooze.deviceKey: "x", "call anna": TodoSuggestions.taken]
        XCTAssertEqual(InboxSnooze.pruned(states), ["call anna": TodoSuggestions.taken])
    }

    func testWaitingLabel() {
        let now = date(2026, 11, 22, 10)
        XCTAssertNil(Inbox.waitingLabel(since: date(2026, 11, 22, 1), now: now, calendar: calendar))
        XCTAssertEqual(Inbox.waitingLabel(since: date(2026, 11, 21, 23), now: now, calendar: calendar), "1 day")
        XCTAssertEqual(Inbox.waitingLabel(since: date(2026, 11, 17, 10), now: now, calendar: calendar), "5 days")
        XCTAssertEqual(Inbox.waitingLabel(since: date(2026, 11, 1, 10), now: now, calendar: calendar), "3 weeks")
        XCTAssertEqual(Inbox.waitingLabel(since: date(2026, 7, 1, 10), now: now, calendar: calendar), "4 months")
    }

    func testCountedTitlesLeaveOutZero() {
        XCTAssertEqual(Places.countedTitle("Archive", 0), "Archive")
        XCTAssertEqual(Places.countedTitle("Deleted", 27), "Deleted 27")
        XCTAssertEqual(Places.countedTitle("All", 3, gap: "  "), "All  3")
    }
}
