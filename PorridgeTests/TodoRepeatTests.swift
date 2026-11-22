import SwiftData
import XCTest
@testable import Porridge

/// Repeating to-dos: one entry whose due day moves on when it is done, stored inside `todoSuggestionsRaw`.
@MainActor
final class TodoRepeatTests: XCTestCase {
    private func next(_ rule: TodoRepeat, _ due: String?, today: String) -> String {
        rule.nextDue(after: due, today: today)
    }

    // MARK: Rules and their stored form

    func testRawRoundTrip() {
        for rule in [TodoRepeat.daily, .weekly, .monthly, .yearly, .everyDays(3), TodoRepeat(unit: .month, interval: 2, anchorDay: 31)] {
            XCTAssertEqual(TodoRepeat(raw: rule.raw), rule, rule.raw)
        }
        XCTAssertEqual(TodoRepeat(unit: .month, anchorDay: 31).raw, "month:1:31")
        XCTAssertEqual(TodoRepeat.everyDays(3).raw, "day:3")
        XCTAssertNil(TodoRepeat(raw: "fortnight:1"))
        XCTAssertEqual(TodoRepeat(raw: "day:0")?.interval, 1, "an interval is at least 1")
        XCTAssertEqual(TodoRepeat.everyDays(3).title, "Every 3 Days")
        XCTAssertEqual(TodoRepeat.weekly.title, "Weekly")
    }

    // MARK: Next occurrence

    func testDailyWeeklyAndEveryNDays() {
        XCTAssertEqual(next(.daily, "2026-11-22", today: "2026-11-22"), "2026-11-23")
        XCTAssertEqual(next(.weekly, "2026-11-22", today: "2026-11-22"), "2026-11-29")
        XCTAssertEqual(next(.everyDays(3), "2026-11-22", today: "2026-11-22"), "2026-11-25")
        // Across the end of a month and a year.
        XCTAssertEqual(next(.daily, "2026-12-31", today: "2026-12-31"), "2027-01-01")
        XCTAssertEqual(next(.weekly, "2028-02-26", today: "2028-02-26"), "2028-03-04")
        // Done early: counted from the due day, not from today.
        XCTAssertEqual(next(.weekly, "2026-11-27", today: "2026-11-22"), "2026-12-04")
    }

    func testOverdueMovesToTheFirstOccurrenceAfterToday() {
        XCTAssertEqual(next(.daily, "2026-11-01", today: "2026-11-22"), "2026-11-23")
        // A Monday to-do done on Sunday, three weeks late: next Monday.
        XCTAssertEqual(next(.weekly, "2026-11-02", today: "2026-11-22"), "2026-11-23")
        XCTAssertEqual(next(.everyDays(3), "2026-11-01", today: "2026-11-22"), "2026-11-25")
        XCTAssertEqual(next(.monthly.anchored(to: "2026-01-15"), "2026-01-15", today: "2026-11-22"), "2026-12-15")
        // Years late is still quick and right.
        XCTAssertEqual(next(.daily, "2000-01-01", today: "2026-11-22"), "2026-11-23")
    }

    func testWithoutDueDayCountsFromToday() {
        XCTAssertEqual(next(.daily, nil, today: "2026-11-22"), "2026-11-23")
        XCTAssertEqual(next(.weekly, "none", today: "2026-11-22"), "2026-11-29")
    }

    func testMonthEndsKeepTheirDay() {
        let rule = TodoRepeat.monthly.anchored(to: "2027-01-31")
        XCTAssertEqual(rule.anchorDay, 31)
        var due = "2027-01-31"
        var seen: [String] = []
        for _ in 0..<4 {
            due = rule.nextDue(after: due, today: due)
            seen.append(due)
        }
        XCTAssertEqual(seen, ["2027-02-28", "2027-03-31", "2027-04-30", "2027-05-31"])
        // A leap year has a 29 February.
        XCTAssertEqual(rule.nextDue(after: "2028-01-31", today: "2028-01-31"), "2028-02-29")
        // The 30th stays the 30th after February.
        let thirtieth = TodoRepeat.monthly.anchored(to: "2027-01-30")
        XCTAssertEqual(thirtieth.nextDue(after: "2027-02-28", today: "2027-02-28"), "2027-03-30")
    }

    func testAMovedDueDayBecomesTheNewAnchor() {
        let rule = TodoRepeat(unit: .month, anchorDay: 31)
        // Moved by hand to the 15th: the 15th from now on.
        XCTAssertEqual(rule.nextDue(after: "2027-03-15", today: "2027-03-15"), "2027-04-15")
        // The 30th of a 31-day month is no clamped 31st either.
        XCTAssertEqual(rule.nextDue(after: "2027-03-30", today: "2027-03-30"), "2027-04-30")
        XCTAssertEqual(rule.nextDue(after: "2027-04-30", today: "2027-04-30"), "2027-05-31")
    }

    func testYearlyOnTheTwentyNinthOfFebruary() {
        let rule = TodoRepeat.yearly.anchored(to: "2028-02-29")
        var due = "2028-02-29"
        var seen: [String] = []
        for _ in 0..<4 {
            due = rule.nextDue(after: due, today: due)
            seen.append(due)
        }
        XCTAssertEqual(seen, ["2029-02-28", "2030-02-28", "2031-02-28", "2032-02-29"])
        XCTAssertEqual(TodoRepeat.yearly.nextDue(after: "2026-11-22", today: "2026-11-22"), "2027-11-22")
        XCTAssertEqual(TodoRepeat(unit: .month, interval: 3).nextDue(after: "2026-11-30", today: "2026-11-30"), "2027-02-28")
    }

    func testDayArithmeticMatchesTheCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var date = calendar.date(from: DateComponents(year: 1999, month: 12, day: 25))!
        var day = TodoRepeat.Day("1999-12-25")!
        for _ in 0..<(366 * 4 + 40) {
            XCTAssertEqual(day.key, Todos.dueKey(date, calendar: calendar))
            XCTAssertEqual(TodoRepeat.Day(ordinal: day.ordinal), day)
            date = calendar.date(byAdding: .day, value: 1, to: date)!
            day = day.adding(days: 1)
        }
        XCTAssertNil(TodoRepeat.Day("2027-02-29"), "no such day")
        XCTAssertTrue(TodoRepeat.Day.isLeap(2000))
        XCTAssertFalse(TodoRepeat.Day.isLeap(2100))
    }

    // MARK: Time zones and daylight saving time

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ calendar: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func todo(due: String?, rule: TodoRepeat, text: String = "- [x] One\n- [ ] Two") -> Note {
        let note = Note()
        note.todoState = .open
        note.todoDueDay = due
        note.text = text
        note.todoRepeat = rule.anchored(to: due)
        return note
    }

    func testDaylightSavingTimeDoesNotShiftTheDay() {
        // Berlin springs forward on 28 March 2027 (02:00 → 03:00) and falls back on 25 October 2026.
        let berlin = calendar("Europe/Berlin")
        for (now, due, expected) in [
            (date(berlin, 2027, 3, 28, 1, 30), "2027-03-28", "2027-03-29"),
            (date(berlin, 2027, 3, 28, 23, 30), "2027-03-28", "2027-03-29"),
            (date(berlin, 2027, 3, 27, 23, 59), "2027-03-27", "2027-03-28"),
            (date(berlin, 2026, 10, 25, 2, 30), "2026-10-25", "2026-10-26"),
            (date(berlin, 2026, 10, 25, 23, 59), "2026-10-24", "2026-10-26"),
        ] {
            let note = todo(due: due, rule: .daily)
            Todos.rollOver(note, now: now, calendar: berlin)
            XCTAssertEqual(note.todoDueDay, expected, "\(now)")
        }
        // New York springs forward on 14 March 2027; a weekly to-do keeps its weekday.
        let newYork = calendar("America/New_York")
        let weekly = todo(due: "2027-03-08", rule: .weekly)
        Todos.rollOver(weekly, now: date(newYork, 2027, 3, 14, 23, 30), calendar: newYork)
        XCTAssertEqual(weekly.todoDueDay, "2027-03-15")
        // Monthly across the change.
        let monthly = todo(due: "2027-02-28", rule: TodoRepeat(unit: .month, anchorDay: 28))
        Todos.rollOver(monthly, now: date(berlin, 2027, 2, 28, 22), calendar: berlin)
        XCTAssertEqual(monthly.todoDueDay, "2027-03-28")
    }

    // MARK: On the note

    func testStoredBesideTheSuggestionStates() {
        let note = Note()
        note.todoSuggestionsRaw = TodoSuggestions.encode(["send the offer": TodoSuggestions.taken])
        note.todoRepeat = .weekly
        XCTAssertEqual(note.todoRepeat, .weekly)
        let states = TodoSuggestions.states(note.todoSuggestionsRaw)
        XCTAssertEqual(states["send the offer"], TodoSuggestions.taken, "other states stay")
        XCTAssertEqual(states[TodoRepeat.storageKey], "week:1")
        XCTAssertNil(TodoSuggestions.state(of: "repeat", in: states), "never mistaken for a task")
        note.todoRepeat = nil
        XCTAssertEqual(TodoSuggestions.states(note.todoSuggestionsRaw), ["send the offer": TodoSuggestions.taken])

        let plain = Note()
        plain.todoRepeat = .daily
        XCTAssertEqual(plain.todoSuggestionsRaw, #"{"@repeat":"day:1"}"#)
        plain.todoRepeat = nil
        XCTAssertNil(plain.todoSuggestionsRaw, "back to nothing, as before")
    }

    func testDoneMovesTheDueDayAndUnticksTheSubtasks() throws {
        let context = try TestStore.context()
        let note = todo(due: Todos.dueKey(Date()), rule: .daily, text: "- [x] Water the plants\n- [ ] Feed the cat")
        context.insert(note)
        Todos.setDone(true, note, in: context)
        XCTAssertEqual(note.todoState, .open, "a repeating to-do is never done")
        XCTAssertNil(note.todoDoneAt)
        XCTAssertEqual(note.todoDueDay, Todos.dueKey(Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
        XCTAssertEqual(Todos.progress(note.text), Todos.Progress(done: 0, total: 2))
        let all = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(all.count, 1, "nothing is copied")
        XCTAssertNil(note.archivedAt)
    }

    func testTickingTheLastSubtaskRollsOver() {
        let note = todo(due: "2026-11-22", rule: .weekly, text: "- [x] One\n- [ ] Two")
        let old = note.text
        note.text = Todos.setAll(true, in: old)
        Todos.follow(note, from: old)
        XCTAssertEqual(note.todoState, .open)
        XCTAssertEqual(Todos.progress(note.text).done, 0)
        XCTAssertGreaterThan(note.todoDueDay ?? "", "2026-11-22")
    }

    func testSettingARuleStartsTodayAndTurningBackClearsIt() throws {
        let context = try TestStore.context()
        let note = Note()
        note.todoState = .open
        context.insert(note)
        let now = Date()
        Todos.setRepeat(.monthly, note, in: context, now: now)
        XCTAssertEqual(note.todoDueDay, Todos.dueKey(now))
        XCTAssertEqual(note.todoRepeat?.anchorDay, Calendar.current.component(.day, from: now))
        XCTAssertTrue(note.isRepeating)
        Todos.setTodo(false, note, in: context)
        XCTAssertNil(note.todoRepeat)
        XCTAssertFalse(note.offersTodoSuggestions)
    }

    func testANoteThatIsNoTodoGetsNoRule() throws {
        let context = try TestStore.context()
        let note = Note()
        context.insert(note)
        Todos.setRepeat(.daily, note, in: context)
        XCTAssertNil(note.todoRepeat)
    }
}
