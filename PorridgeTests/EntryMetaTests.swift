import SwiftData
import XCTest
@testable import Porridge

/// The one meta line under an entry's title: facts first, then only the values that are set, in a fixed order, each
/// opening its Details section.
@MainActor
final class EntryMetaTests: XCTestCase {
    private typealias F = EntryFixtures

    func testOnlySetValuesNeverPlaceholders() throws {
        let context = try TestStore.context()
        let note = F.note(in: context)
        let (facts, values) = EntryMeta.items(for: note, context: EntryContext())
        XCTAssertTrue(facts.hasPrefix("Note · Today "), facts)
        XCTAssertEqual(values, [], "a plain note in the Inbox has no values")
        // A to-do without a day: no due value either.
        XCTAssertEqual(EntryMeta.values(for: F.todo(in: context), context: EntryContext()), [])
    }

    func testValuesKeepTheirOrderAndSections() throws {
        let context = try TestStore.context()
        let kitchen = F.bowl("Kitchen Renovation", in: context)
        let todo = F.todo("Choose worktop colour", text: "- [ ] Samples\n- [x] Measure\n- [ ] Compare\n- [ ] Decide #design", due: F.day(3), in: context)
        todo.todoRepeat = .weekly
        todo.labels = ["home"]
        F.file(todo, into: kitchen)
        var state = EntryContext(bowls: [kitchen])
        state.appointment = AppointmentRef(CalendarAppointment.fixture(title: "Showroom"))
        state.activityLine = "Changed by Anna"
        let values = EntryMeta.values(for: todo, context: state)
        XCTAssertEqual(values.map(\.kind), [.bowl, .due, .repeat, .appointment, .tag, .tag, .activity])
        XCTAssertEqual(values.map(\.section), [.organize, .organize, .organize, .appointment, .organize, .organize, .sharingActivity])
        XCTAssertEqual(values[0].text, "Kitchen Renovation")
        XCTAssertEqual(values[0].symbol, EntryMeta.bowlImage)
        XCTAssertEqual(values[0].tone, .bowl)
        XCTAssertEqual(values[2].text, "Weekly")
        XCTAssertTrue(values[3].text.hasPrefix("Showroom "))
        XCTAssertEqual(values.filter { $0.kind == .tag }.map(\.text), ["#home", "#design"])
        let facts = EntryMeta.facts(for: todo, context: state)
        XCTAssertTrue(facts.hasPrefix("To-do · "), facts)
        XCTAssertTrue(facts.hasSuffix("1 of 4 subtasks"), facts)
    }

    func testOverdueFlag() throws {
        let context = try TestStore.context()
        let late = F.todo(due: F.day(-2), in: context)
        let due = try XCTUnwrap(EntryMeta.values(for: late, context: EntryContext()).first)
        XCTAssertEqual(due.kind, .due)
        XCTAssertTrue(due.isOverdue)
        XCTAssertEqual(due.tone, .danger)
        // Done: no longer late.
        late.todoState = .done
        let done = try XCTUnwrap(EntryMeta.values(for: late, context: EntryContext()).first)
        XCTAssertFalse(done.isOverdue)
        XCTAssertEqual(done.tone, .task)

        let soon = try XCTUnwrap(EntryMeta.values(for: F.todo(due: F.day(1), in: context), context: EntryContext()).first)
        XCTAssertEqual(soon.text, "Due Tomorrow")
        XCTAssertFalse(soon.isOverdue)

        // A bill past its day.
        var info = DocumentInfo(kind: .invoice, correspondent: "Telekom")
        info.amount = "119.00 EUR"
        info.dueDay = DocumentInfo.dayKey(Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? Date())
        let bill = F.pdf(document: info, in: context)
        let values = EntryMeta.values(for: bill, context: EntryContext())
        XCTAssertEqual(values.map(\.kind), [.document, .payment])
        XCTAssertTrue(values[0].text.hasPrefix("Invoice · Telekom · "), values[0].text)
        XCTAssertEqual(values[0].section, .document)
        XCTAssertEqual(values[1].text, "Overdue")
        XCTAssertTrue(values[1].isOverdue)
    }

    func testPaymentWords() throws {
        let context = try TestStore.context()
        var info = DocumentInfo(kind: .invoice, correspondent: "Telekom")
        info.dueDay = F.day(9)
        let bill = F.pdf(document: info, in: context)
        XCTAssertEqual(EntryMeta.values(for: bill, context: EntryContext()).last?.text, "Unpaid")
        info.setPaid(true)
        bill.documentInfo = info
        let paid = try XCTUnwrap(EntryMeta.values(for: bill, context: EntryContext()).last)
        XCTAssertEqual(paid.text, "Paid")
        XCTAssertEqual(paid.tone, .task)
        // A PDF nobody read yet: no document value at all.
        XCTAssertEqual(EntryMeta.values(for: F.pdf(in: context), context: EntryContext()), [])
        XCTAssertTrue(EntryMeta.facts(for: F.pdf(in: context), context: EntryContext(pageCount: 3)).hasSuffix("3 pages"))
        XCTAssertTrue(EntryMeta.facts(for: F.pdf(in: context), context: EntryContext()).hasPrefix("PDF · "))
    }

    func testMeetingFactsAndSpeakers() throws {
        let context = try TestStore.context()
        let meeting = F.meeting(speakers: ["Sam", "Ben", "Priya", "Speaker 4"], in: context)
        let (facts, values) = EntryMeta.items(for: meeting, context: EntryContext())
        XCTAssertTrue(facts.hasPrefix("Meeting · Today "), facts)
        XCTAssertTrue(facts.hasSuffix(" · 42 min"), facts)
        XCTAssertEqual(values.map(\.kind), [.speakers])
        XCTAssertEqual(values.first?.text, "4 Speakers · 1 unnamed")
        XCTAssertEqual(values.first?.section, .speakers)

        let link = F.link(in: context)
        XCTAssertTrue(EntryMeta.facts(for: link, context: EntryContext()).hasSuffix(" · example.com"))
    }

    func testSuggestionOnlyInTheInbox() throws {
        let context = try TestStore.context()
        let bills = F.bowl("House & Bills", in: context)
        let pdf = F.pdf(in: context)
        pdf.suggestedProjectIDs = [Projects.key(bills)]
        let state = EntryContext(bowls: [bills])
        XCTAssertEqual(EntryMeta.suggestion(for: pdf, context: state)?.name, "House & Bills")
        XCTAssertFalse(EntryMeta.values(for: pdf, context: state).contains { $0.kind == .bowl }, "a suggestion is no value")
        var viewOnly = state
        viewOnly.isReadOnly = true
        XCTAssertNil(EntryMeta.suggestion(for: pdf, context: viewOnly))
        Inbox.file(pdf, into: Projects.key(bills), in: context)
        XCTAssertNil(EntryMeta.suggestion(for: pdf, context: state))
        XCTAssertEqual(EntryMeta.values(for: pdf, context: state).first?.kind, .bowl)
    }

    func testDateText() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 12)) ?? Date()
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 10)) ?? Date()
        XCTAssertTrue(EntryMeta.dateText(morning, now: now).hasPrefix("Today "))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: morning) ?? Date()
        XCTAssertTrue(EntryMeta.dateText(yesterday, now: now).hasPrefix("Yesterday "))
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 3, day: 2)) ?? Date()
        XCTAssertTrue(EntryMeta.dateText(lastYear, now: now).contains("2025"))
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 3, day: 2)) ?? Date()
        XCTAssertFalse(EntryMeta.dateText(earlier, now: now).contains("2026"))
    }

    // MARK: The kinds of the mockups (stage 2)

    /// "Meeting · Today 10:00 · 42 min  Q4 Planning  Design Review 10:00  4 Speakers · 1 unnamed  #design".
    func testMockupMeeting() throws {
        let context = try TestStore.context()
        let q4 = F.bowl("Q4 Planning", in: context)
        let meeting = F.meeting(speakers: ["Sam", "Ben", "Priya", "Speaker 4"], in: context)
        meeting.labels = ["design"]
        F.file(meeting, into: q4)
        var state = EntryContext(bowls: [q4])
        state.appointment = AppointmentRef(CalendarAppointment.fixture(title: "Design Review"))
        let values = EntryMeta.values(for: meeting, context: state)
        XCTAssertEqual(values.map(\.kind), [.bowl, .appointment, .speakers, .tag])
        XCTAssertEqual(values.map(\.section), [.organize, .appointment, .speakers, .organize])
        XCTAssertEqual(values.map(\.tone), [.bowl, .navy, .navy, .secondary])
        XCTAssertNil(EntryMeta.suggestion(for: meeting, context: state), "filed: no suggestion")
        // Details: no Document, Speakers with Known Voices…, the type row without a to-do switch (a recording).
        let sections = EntryDetails.sections(for: meeting, context: state)
        XCTAssertEqual(sections.map(\.kind), [.organize, .appointment, .speakers, .connections, .sharingActivity])
        XCTAssertEqual(sections.first { $0.kind == .speakers }?.action, .knownVoices)
        XCTAssertEqual(sections.first { $0.kind == .appointment }?.rows.map(\.kind), [.appointment, .sameAppointment])
        XCTAssertFalse(EntryDetails.showsTodoSwitch(meeting))
        XCTAssertEqual(EntryDetails.typeName(for: meeting), "Meeting")
        XCTAssertEqual(EntryDetails.label(.origin, for: meeting), "Recorded")
    }

    /// "PDF · 23 Nov · 2 pages  ✦ File into House & Bills  Invoice · Telekom · 119,00 €  Unpaid".
    func testMockupPDFInInbox() throws {
        let context = try TestStore.context()
        let bills = F.bowl("House & Bills", in: context)
        var info = DocumentInfo(kind: .invoice, correspondent: "Telekom")
        info.amount = "119.00 EUR"
        info.dueDay = F.day(8)
        let pdf = F.pdf(document: info, in: context)
        pdf.suggestedProjectIDs = [Projects.key(bills)]
        let state = EntryContext(bowls: [bills], pageCount: 2)
        let (facts, values) = EntryMeta.items(for: pdf, context: state)
        XCTAssertTrue(facts.hasPrefix("PDF · Today "), facts)
        XCTAssertTrue(facts.hasSuffix(" · 2 pages"), facts)
        XCTAssertEqual(values.map(\.kind), [.document, .payment])
        XCTAssertEqual(values.map(\.text).last, "Unpaid")
        XCTAssertEqual(EntryMeta.suggestion(for: pdf, context: state)?.name, "House & Bills")
        let organize = try XCTUnwrap(EntryDetails.sections(for: pdf, context: state).first)
        XCTAssertEqual(organize.rows.map(\.kind), [.type, .bowl, .suggestedBowl, .tags])
        XCTAssertEqual(EntryDetails.typeName(for: pdf), "PDF")
        XCTAssertEqual(EntryDetails.sharingText(for: pdf), "Not shared")
        XCTAssertEqual(EntryDetails.origin(for: pdf).label, "Came In")
        XCTAssertTrue(EntryDetails.origin(for: pdf).value.hasPrefix("Shared · "))
        pdf.text = MailNote.fromLabel + "Telekom <bill@telekom.de>\n\nYour bill"
        XCTAssertTrue(EntryDetails.origin(for: pdf).value.hasPrefix("By Mail · "))
    }

    /// "To-do · 2 of 4 subtasks  Kitchen Renovation  Due Fri  Weekly"; Details: Type Note + to-do switch on, Due and
    /// Repeat rows.
    func testMockupTodoWithRepeat() throws {
        let context = try TestStore.context()
        let kitchen = F.bowl("Kitchen Renovation", in: context)
        let todo = F.todo("Choose worktop colour", text: "- [x] Samples\n- [x] Measure\n- [ ] Compare\n- [ ] Decide", due: F.day(3), in: context)
        todo.todoRepeat = .weekly
        F.file(todo, into: kitchen)
        let state = EntryContext(bowls: [kitchen])
        let (facts, values) = EntryMeta.items(for: todo, context: state)
        XCTAssertTrue(facts.hasSuffix("2 of 4 subtasks"), facts)
        XCTAssertEqual(values.map(\.kind), [.bowl, .due, .repeat])
        XCTAssertEqual(values.map(\.tone), [.bowl, .task, .task])
        XCTAssertEqual(values[2].text, "Weekly")
        XCTAssertEqual(EntryDetails.typeName(for: todo), "Note")
        XCTAssertTrue(EntryDetails.showsTodoSwitch(todo))
        XCTAssertTrue(EntryDetails.canSwitchTodo(todo, context: state))
        XCTAssertEqual(EntryDetails.sections(for: todo, context: state).first?.rows.map(\.kind), [.type, .bowl, .due, .repeat, .tags])
        XCTAssertEqual(EntryDetails.label(.payBy, for: todo), "Pay By")
        XCTAssertEqual(EntryDetails.origin(for: todo).label, "Created")
    }
}
