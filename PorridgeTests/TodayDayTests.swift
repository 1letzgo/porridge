import XCTest
@testable import Porridge

/// Paging through days on the Today page: stepping, the title, and which to-dos belong to a day.
@MainActor
final class TodayDayTests: XCTestCase {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func key(_ date: Date, calendar: Calendar) -> String { Todos.dueKey(date, calendar: calendar) }

    // MARK: Stepping

    func testStepLandsOnTheStartOfTheNextAndPreviousDay() {
        let calendar = berlin
        let noon = date(2026, 11, 23, 15, calendar: calendar)
        let next = TodayDay.step(noon, by: 1, calendar: calendar)
        XCTAssertEqual(next, date(2026, 11, 24, 0, calendar: calendar))
        XCTAssertEqual(TodayDay.step(noon, by: -1, calendar: calendar), date(2026, 11, 22, 0, calendar: calendar))
        XCTAssertEqual(TodayDay.step(noon, by: 0, calendar: calendar), date(2026, 11, 23, 0, calendar: calendar))
    }

    func testStepCrossesDaylightSavingDaysAsOneDayEach() {
        let calendar = berlin
        // Spring forward: 29 March 2026 has 23 hours.
        let before = date(2026, 3, 28, 0, calendar: calendar)
        let short = TodayDay.step(before, by: 1, calendar: calendar)
        XCTAssertEqual(key(short, calendar: calendar), "2026-03-29")
        let after = TodayDay.step(short, by: 1, calendar: calendar)
        XCTAssertEqual(key(after, calendar: calendar), "2026-03-30")
        XCTAssertEqual(after.timeIntervalSince(short), 23 * 3600)
        XCTAssertEqual(calendar.component(.hour, from: after), 0)
        // Fall back: 25 October 2026 has 25 hours, and back again lands on the same days.
        let long = date(2026, 10, 25, 0, calendar: calendar)
        let monday = TodayDay.step(long, by: 1, calendar: calendar)
        XCTAssertEqual(key(monday, calendar: calendar), "2026-10-26")
        XCTAssertEqual(monday.timeIntervalSince(long), 25 * 3600)
        XCTAssertEqual(TodayDay.step(monday, by: -1, calendar: calendar), long)
        XCTAssertEqual(TodayDay.offset(of: monday, now: date(2026, 10, 24, 23, calendar: calendar), calendar: calendar), 2)
    }

    func testStepCrossesMonthAndYearBorders() {
        let calendar = berlin
        XCTAssertEqual(key(TodayDay.step(date(2026, 1, 31, calendar: calendar), by: 1, calendar: calendar), calendar: calendar), "2026-02-01")
        XCTAssertEqual(key(TodayDay.step(date(2026, 3, 1, calendar: calendar), by: -1, calendar: calendar), calendar: calendar), "2026-02-28")
        XCTAssertEqual(key(TodayDay.step(date(2028, 2, 28, calendar: calendar), by: 1, calendar: calendar), calendar: calendar), "2028-02-29")
        XCTAssertEqual(key(TodayDay.step(date(2026, 12, 31, calendar: calendar), by: 1, calendar: calendar), calendar: calendar), "2027-01-01")
        XCTAssertEqual(key(TodayDay.step(date(2027, 1, 1, calendar: calendar), by: -1, calendar: calendar), calendar: calendar), "2026-12-31")
    }

    // MARK: Title

    func testTitleNamesNearDaysAndOtherwiseTheWeekdayAndDate() {
        let calendar = berlin
        let locale = Locale(identifier: "en_GB")
        let now = date(2026, 11, 23, 23, calendar: calendar)
        func title(_ day: Date) -> String { TodayDay.title(day, now: now, calendar: calendar, locale: locale) }
        XCTAssertEqual(title(date(2026, 11, 23, 1, calendar: calendar)), String(localized: "Today"))
        XCTAssertEqual(title(TodayDay.step(now, by: 1, calendar: calendar)), String(localized: "Tomorrow"))
        XCTAssertEqual(title(TodayDay.step(now, by: -1, calendar: calendar)), String(localized: "Yesterday"))
        let friday = title(date(2026, 11, 27, calendar: calendar))
        XCTAssertTrue(friday.contains("Fri"), friday)
        XCTAssertFalse(friday.contains("Friday"), "the short weekday fits the bar: \(friday)")
        XCTAssertTrue(friday.contains("27"), friday)
        XCTAssertTrue(friday.contains("Nov"), friday)
        XCTAssertFalse(friday.contains("2026"), friday)
        // Another year shows it; across the year's end too.
        let nextYear = title(date(2027, 1, 2, calendar: calendar))
        XCTAssertTrue(nextYear.contains("Sat") && nextYear.contains("2027"), nextYear)
        // In the device's language.
        XCTAssertTrue(TodayDay.title(date(2026, 11, 27, calendar: calendar), now: now, calendar: calendar, locale: Locale(identifier: "de_DE")).contains("Fr"))
    }

    func testTitleCountsCalendarDaysNotHoursAcrossDaylightSaving() {
        let calendar = berlin
        // Late on the Saturday before the clocks go forward: Sunday is tomorrow, Monday the day after.
        let now = date(2026, 3, 28, 23, calendar: calendar)
        XCTAssertEqual(TodayDay.title(date(2026, 3, 29, 23, calendar: calendar), now: now, calendar: calendar), String(localized: "Tomorrow"))
        XCTAssertEqual(TodayDay.offset(of: date(2026, 3, 30, 0, calendar: calendar), now: now, calendar: calendar), 2)
    }

    // MARK: To-dos of a day

    func testTodosOfADay() {
        let calendar = berlin
        let now = date(2026, 11, 23, 10, calendar: calendar)
        let tomorrow = TodayDay.step(now, by: 1, calendar: calendar)
        let yesterday = TodayDay.step(now, by: -1, calendar: calendar)
        func todo(due: Date?) -> Note {
            let note = Note()
            note.todoState = .open
            note.todoDueDay = due.map { key($0, calendar: calendar) }
            return note
        }
        let dueToday = todo(due: now)
        let dueTomorrow = todo(due: tomorrow)
        let dueYesterday = todo(due: yesterday)
        let longOverdue = todo(due: date(2026, 10, 1, calendar: calendar))
        let undated = todo(due: nil)
        let doneTomorrowDue = todo(due: tomorrow)
        doneTomorrowDue.todoState = .done
        let all = [dueToday, dueTomorrow, dueYesterday, longOverdue, undated, doneTomorrowDue]

        // Today as before: due today or late.
        XCTAssertEqual(Set(TodayTodos.open(all, now: now, calendar: calendar).map(\.id)), [dueToday.id, dueYesterday.id, longOverdue.id])
        XCTAssertEqual(Set(TodayTodos.open(all, on: now, now: now, calendar: calendar).map(\.id)), [dueToday.id, dueYesterday.id, longOverdue.id])
        // Another day: only what is due on exactly that day, open.
        XCTAssertEqual(TodayTodos.open(all, on: tomorrow, now: now, calendar: calendar).map(\.id), [dueTomorrow.id])
        XCTAssertEqual(TodayTodos.open(all, on: yesterday, now: now, calendar: calendar).map(\.id), [dueYesterday.id])
        XCTAssertTrue(TodayTodos.open(all, on: TodayDay.step(now, by: 5, calendar: calendar), now: now, calendar: calendar).isEmpty)
    }

    func testDoneTodosBelongToTheDayTheyWereTicked() {
        let calendar = berlin
        let now = date(2026, 11, 23, 10, calendar: calendar)
        let yesterday = TodayDay.step(now, by: -1, calendar: calendar)
        let early = Note(), late = Note(), today = Note()
        for note in [early, late, today] { note.todoState = .done }
        early.todoDoneAt = date(2026, 11, 22, 8, calendar: calendar)
        late.todoDoneAt = date(2026, 11, 22, 23, calendar: calendar)
        today.todoDoneAt = date(2026, 11, 23, 0, calendar: calendar)
        let all = [early, late, today]
        XCTAssertEqual(TodayTodos.done(all, on: yesterday, calendar: calendar).map(\.id), [late.id, early.id])
        XCTAssertEqual(TodayTodos.doneToday(all, now: now, calendar: calendar).map(\.id), [today.id])
        XCTAssertTrue(TodayTodos.done(all, on: TodayDay.step(now, by: 1, calendar: calendar), calendar: calendar).isEmpty)
    }
}
