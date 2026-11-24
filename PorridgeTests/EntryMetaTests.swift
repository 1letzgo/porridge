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
}
