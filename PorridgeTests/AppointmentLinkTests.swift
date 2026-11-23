import SwiftData
import XCTest
@testable import Porridge

/// Entries linked to appointments, appointments filed into bowls, and how the links merge between devices.
@MainActor
final class AppointmentLinkTests: XCTestCase {
    private func appointment(id: String = "e1", series: String? = "series-1", title: String = "Weekly", start: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> CalendarAppointment {
        CalendarAppointment(id: id, title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: false, calendarName: "Work", externalID: series)
    }

    private func links() -> AppointmentLinks {
        let defaults = UserDefaults(suiteName: "AppointmentLinkTests-\(UUID().uuidString)")!
        return AppointmentLinks(defaults: defaults, cloud: nil)
    }

    func testOccurrencesOfASeriesHaveTheirOwnKeyAndMatchWithinTheirDay() {
        let first = appointment()
        let next = appointment(start: first.start.addingTimeInterval(7 * 86400))
        XCTAssertNotEqual(first.key, next.key)
        XCTAssertEqual(first.seriesID, next.seriesID)
        let ref = AppointmentRef(first)
        XCTAssertTrue(ref.matches(first))
        XCTAssertFalse(ref.matches(next))
        // Moved by an hour on the same day: still the same occurrence.
        XCTAssertTrue(ref.matches(appointment(start: first.start.addingTimeInterval(3600))))
        // Without an external identifier the event's own identifier stands for the series.
        XCTAssertEqual(appointment(id: "local", series: nil).seriesID, "local")
    }

    func testEntriesOfTheSameAppointment() throws {
        let context = try TestStore.context()
        let links = links()
        let meeting = Note(), note = Note(), other = Note()
        [meeting, note, other].forEach(context.insert)
        links.link(meeting, to: appointment(), in: context)
        links.link(note, to: appointment(), in: context)
        links.link(other, to: appointment(start: Date(timeIntervalSince1970: 1_900_000_000)), in: context)
        XCTAssertEqual(links.others(linkedWith: meeting, among: [meeting, note, other]).map(\.id), [note.id])
        XCTAssertEqual(Set(links.notes(for: appointment(), among: [meeting, note, other]).map(\.id)), [meeting.id, note.id])

        links.link(note, to: nil, in: context)
        XCTAssertNil(links.appointment(for: note.id))
        XCTAssertTrue(links.others(linkedWith: meeting, among: [meeting, note, other]).isEmpty)
    }

    func testAMeetingIsLinkedOnlyOnceAndNotAgainAfterItWasUnlinked() throws {
        let context = try TestStore.context()
        let links = links()
        let meeting = Note()
        context.insert(meeting)
        links.linkMeeting(meeting, to: appointment(), in: context)
        XCTAssertEqual(links.appointment(for: meeting.id)?.title, "Weekly")
        links.linkMeeting(meeting, to: appointment(title: "Other"), in: context)
        XCTAssertEqual(links.appointment(for: meeting.id)?.title, "Weekly", "a link is not replaced automatically")
        links.link(meeting, to: nil, in: context)
        links.linkMeeting(meeting, to: appointment(), in: context)
        XCTAssertNil(links.appointment(for: meeting.id), "removed by hand, not linked again")
    }

    func testTheAppointmentsBowlTakesWhatWaitsInTheInbox() throws {
        let context = try TestStore.context()
        let links = links()
        let bowl = NoteFolder(name: "Project X")
        let elsewhere = NoteFolder(name: "Elsewhere")
        context.insert(bowl)
        context.insert(elsewhere)
        let waiting = Note(), filed = Note()
        filed.projectIDs = [Projects.key(elsewhere)]
        [waiting, filed].forEach(context.insert)
        links.link(waiting, to: appointment(), in: context)
        links.link(filed, to: appointment(), in: context)
        XCTAssertTrue(waiting.isInInbox)

        // Every occurrence of the series belongs to the bowl.
        links.setBowl(Projects.key(bowl), for: appointment(start: Date(timeIntervalSince1970: 1_700_000_000)), notes: [waiting, filed], in: context)
        XCTAssertEqual(links.bowl(for: appointment()), Projects.key(bowl))
        XCTAssertEqual(waiting.projectIDs, [Projects.key(bowl)])
        XCTAssertEqual(filed.projectIDs, [Projects.key(elsewhere)], "an entry in a bowl stays there")

        // Linked later: into the bowl at once.
        let later = Note()
        context.insert(later)
        links.link(later, to: appointment(), in: context)
        XCTAssertEqual(later.projectIDs, [Projects.key(bowl)])
    }

    func testDevicesMergeLinkByLinkAndTheLaterChangeWins() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let ref = AppointmentRef(appointment())
        var a = AppointmentLedger()
        a.notes["n1"] = .init(ref: ref, changedAt: early)
        a.notes["n2"] = .init(ref: ref, changedAt: late)
        var b = AppointmentLedger()
        b.notes["n1"] = .init(ref: nil, changedAt: late)
        b.notes["n2"] = .init(ref: nil, changedAt: early)
        b.bowls["series-1"] = .init(bowl: "B", changedAt: early)
        let merged = AppointmentLedger.merged(a, b)
        XCTAssertNil(merged.notes["n1"]?.ref, "removed later on the other device")
        XCTAssertEqual(merged.notes["n2"]?.ref, ref, "linked later here")
        XCTAssertEqual(merged.bowls["series-1"]?.bowl, "B")
        XCTAssertEqual(AppointmentLedger.merged(b, a), merged)
    }

    func testOldTombstonesAreDropped() {
        let now = Date()
        var ledger = AppointmentLedger()
        ledger.notes["old"] = .init(ref: nil, changedAt: now.addingTimeInterval(-AppointmentLedger.keepTombstones - 1))
        ledger.notes["recent"] = .init(ref: nil, changedAt: now)
        ledger.notes["linked"] = .init(ref: AppointmentRef(appointment()), changedAt: .distantPast)
        XCTAssertEqual(Set(ledger.pruned(now: now).notes.keys), ["recent", "linked"])
    }

    func testOldRememberedAppointmentsStillDecode() throws {
        // Stored before the external identifier existed.
        let json = #"{"id":"x","title":"T","start":0,"end":60,"isAllDay":false,"calendarName":"C","calendarID":"","attendees":[],"isDeclined":false}"#
        let decoded = try JSONDecoder().decode(CalendarAppointment.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.seriesID, "x")
    }

    func testTodayTodosAreDueTodayOrBefore() {
        let now = Date()
        let today = Note(), overdue = Note(), later = Note(), none = Note()
        for note in [today, overdue, later, none] { note.todoState = .open }
        today.todoDueDay = Todos.dueKey(now)
        overdue.todoDueDay = Todos.dueKey(now.addingTimeInterval(-3 * 86400))
        later.todoDueDay = Todos.dueKey(now.addingTimeInterval(3 * 86400))
        XCTAssertEqual(Set(TodayTodos.open([today, overdue, later, none], now: now).map(\.id)), [today.id, overdue.id])
    }
}
