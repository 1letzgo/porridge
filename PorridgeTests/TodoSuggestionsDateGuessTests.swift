import XCTest
@testable import Porridge

/// A task's own words are no date unless they name one: month short forms that are everyday words ("out", "set",
/// "may") only count with a marked day or a year.
@MainActor
final class TodoSuggestionsDateGuessTests: XCTestCase {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// Friday, 20 November 2026, 10:00 in Berlin.
    private var meetingDate: Date {
        berlin.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
    }

    private func split(_ text: String) -> (title: String, owner: String?, dueDay: String?) {
        TodoSuggestions.split(text, meetingDate: meetingDate, calendar: berlin)
    }

    func testEverydayWordsInTheTaskAreNoMonth() {
        XCTAssertNil(split("Pick 2 out of the 5 offers – Anna").dueDay)
        XCTAssertEqual(split("Pick 2 out of the 5 offers – Anna").owner, "Anna")
        XCTAssertNil(split("Prepare 1 set of slides").dueDay)
        XCTAssertNil(split("Check whether option 2 may work – Ben").dueDay)
        XCTAssertNil(split("Set 2 reminders for the launch").dueDay)
        XCTAssertNil(split("Gib 3 mag ich nicht weiter").dueDay)
        XCTAssertNil(split("Plan 4 ago meetings").dueDay)
        XCTAssertNil(split("Buy 3 mar charts").dueDay)
    }

    func testRealDatesInTheTaskStillCount() {
        XCTAssertEqual(split("Kläre bis zum 3. Dezember das Budget").dueDay, "2026-12-03")
        XCTAssertEqual(split("Send the offer by 28 November").dueDay, "2026-11-28")
        XCTAssertEqual(split("Send the offer by Nov 28").dueDay, "2026-11-28")
        XCTAssertEqual(split("Send the offer by 28 Nov").dueDay, "2026-11-28")
        // Marked days and years make even the everyday words a month.
        XCTAssertEqual(split("Angebot bis 2. Mai schicken").dueDay, "2027-05-02")
        XCTAssertEqual(split("Send the offer by May 4th").dueDay, "2027-05-04")
        XCTAssertEqual(split("Send the offer by 4th May").dueDay, "2027-05-04")
        XCTAssertEqual(split("Send the offer by May 4, 2027").dueDay, "2027-05-04")
        XCTAssertEqual(split("Enviar a proposta até 2 de out de 2027").dueDay, "2027-10-02")
    }

    func testTheDatePartKeepsShortForms() {
        XCTAssertEqual(split("Send the offer – Anna – 4 mai").dueDay, "2027-05-04")
        XCTAssertEqual(split("Enviar a proposta – Ana – 2 out").dueDay, "2027-10-02")
        XCTAssertEqual(TodoSuggestions.dueDay(from: "1 set", meetingDate: meetingDate, calendar: berlin), "2027-09-01")
        XCTAssertNil(TodoSuggestions.dueDay(from: "1 set", meetingDate: meetingDate, calendar: berlin, strict: true))
    }
}
