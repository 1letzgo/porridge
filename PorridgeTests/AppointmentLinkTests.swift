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

    /// Rule 2 and 4: a bowl shows the appointments of the series filed into it, one row per series (its next
    /// occurrence that is not over, else its last one), upcoming first, then past ones; others never.
    func testABowlShowsItsAppointmentsOncePerSeriesUpcomingFirst() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86400
        let weekly = (-2...3).map { appointment(id: "w\($0)", series: "weekly", title: "Jour fixe", start: now.addingTimeInterval(Double($0) * 7 * day)) }
        let party = appointment(id: "p", series: "party", title: "Christmas Party", start: now.addingTimeInterval(2 * day))
        let past = appointment(id: "old", series: "old", title: "Kick-off", start: now.addingTimeInterval(-30 * day))
        let elsewhere = appointment(id: "x", series: "other", title: "Dentist", start: now.addingTimeInterval(day))
        let loose = appointment(id: "l", series: "loose", title: "Lunch", start: now.addingTimeInterval(day))
        let bowls: [String: AppointmentLedger.BowlLink] = [
            "weekly": .init(bowl: "B", changedAt: now), "party": .init(bowl: "B", changedAt: now),
            "old": .init(bowl: "B", changedAt: now), "other": .init(bowl: "C", changedAt: now),
            "loose": .init(bowl: nil, changedAt: now),
        ]
        let rows = BowlAppointments.rows(weekly + [party, past, elsewhere, loose], bowl: "B", bowls: bowls, now: now.addingTimeInterval(1))
        XCTAssertEqual(rows.map(\.title), ["Jour fixe", "Christmas Party", "Kick-off"], "soonest first, the past one last")
        // The series once: the occurrence going on (it ends an hour after it started), not each one.
        XCTAssertEqual(rows.filter { $0.seriesID == "weekly" }.count, 1)
        XCTAssertEqual(rows.first { $0.seriesID == "weekly" }?.id, "w0", "not the next occurrence of the series")
        // A series with every occurrence over: its last one, after the upcoming ones.
        let over = BowlAppointments.rows(weekly, bowl: "B", bowls: bowls, now: now.addingTimeInterval(30 * day))
        XCTAssertEqual(over.map(\.id), ["w3"])
        XCTAssertTrue(BowlAppointments.rows(weekly + [party], bowl: "C", bowls: bowls, now: now).isEmpty)
    }

    /// Rule 3: appointments are no entries, so the Inbox never lists them; an entry linked to an appointment of a
    /// bowl leaves the Inbox for the bowl, one linked to an appointment without a bowl stays (nothing else does).
    func testAppointmentsNeverFillTheInbox() throws {
        let context = try TestStore.context()
        let links = links()
        let bowl = NoteFolder(name: "SPD")
        context.insert(bowl)
        let filedSeries = appointment(series: "filed"), looseSeries = appointment(id: "e2", series: "loose")
        links.setBowl(Projects.key(bowl), for: filedSeries, notes: [], in: context)
        let forFiled = Note(), forLoose = Note()
        [forFiled, forLoose].forEach(context.insert)
        links.link(forFiled, to: filedSeries, in: context)
        links.link(forLoose, to: looseSeries, in: context)
        let inbox = Inbox.notes([forFiled, forLoose])
        XCTAssertEqual(inbox.map(\.id), [forLoose.id], "the entry of an appointment of a bowl stays in the Inbox")
        XCTAssertEqual(forFiled.projectIDs, [Projects.key(bowl)])
        // The bowl lists the appointment itself.
        XCTAssertEqual(links.appointments(inBowl: Projects.key(bowl), among: [filedSeries, looseSeries], now: filedSeries.start).map(\.seriesID), ["filed"])
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
