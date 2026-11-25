import SwiftData
import XCTest
@testable import Porridge

/// Details (iPhone sheet, Mac inspector): the fixed order of its sections, which kinds have which, and what is
/// locked.
@MainActor
final class EntryDetailsTests: XCTestCase {
    private typealias F = EntryFixtures

    private func kinds(_ note: Note, _ context: EntryContext = EntryContext()) -> [EntryDetails.Section.Kind] {
        EntryDetails.sections(for: note, context: context).map(\.kind)
    }

    private func rows(_ note: Note, _ section: EntryDetails.Section.Kind, _ context: EntryContext = EntryContext()) -> [EntryDetails.Row.Kind] {
        EntryDetails.sections(for: note, context: context).first { $0.kind == section }?.rows.map(\.kind) ?? []
    }

    func testSectionOrderPerKind() throws {
        let context = try TestStore.context()
        XCTAssertEqual(kinds(F.note(in: context)), [.organize, .appointment, .connections, .sharingActivity])
        XCTAssertEqual(kinds(F.todo(in: context)), [.organize, .appointment, .connections, .sharingActivity])
        XCTAssertEqual(kinds(F.link(in: context)), [.organize, .appointment, .connections, .sharingActivity])
        XCTAssertEqual(kinds(F.meeting(speakers: ["Sam"], in: context)), [.organize, .appointment, .speakers, .connections, .sharingActivity])
        XCTAssertEqual(kinds(F.pdf(in: context)), [.organize, .appointment, .document, .connections, .sharingActivity])
        XCTAssertEqual(kinds(F.image(in: context)), [.organize, .appointment, .document, .connections, .sharingActivity])
        // The order is the declared one whatever the kind.
        let all = EntryDetails.Section.Kind.allCases
        for note in [F.meeting(in: context), F.pdf(in: context)] {
            let shown = kinds(note)
            XCTAssertEqual(shown, all.filter(shown.contains))
        }
    }

    func testDocumentOnlyForStoredFilesAndSpeakersOnlyForRecordings() throws {
        let context = try TestStore.context()
        // A note with a file attached stays a note: no Document section.
        let withFile = F.note(in: context)
        withFile.attachments = [Attachment(fileName: "a.pdf", name: "a.pdf", kindRaw: "pdf")]
        XCTAssertFalse(kinds(withFile).contains(.document))
        XCTAssertFalse(kinds(F.note(in: context)).contains(.speakers))
        XCTAssertTrue(kinds(F.meeting(in: context)).contains(.speakers))

        // Edit Pages… in the header of a PDF's Document section, not of an image's.
        let pdf = F.pdf(in: context)
        XCTAssertEqual(EntryDetails.sections(for: pdf, context: EntryContext()).first { $0.kind == .document }?.action, .editPages)
        XCTAssertNil(EntryDetails.sections(for: F.image(in: context), context: EntryContext()).first { $0.kind == .document }?.action)

        // Amount only for kinds that have one; no payment rows (documents keep no payment status).
        let letter = F.pdf(document: DocumentInfo(kind: .letter), in: context)
        XCTAssertEqual(rows(letter, .document), [.documentKind, .sender, .dated])
        let invoice = F.pdf(document: DocumentInfo(kind: .invoice), in: context)
        XCTAssertEqual(rows(invoice, .document), [.documentKind, .sender, .dated, .amount])
    }

    func testDueAndRepeatOnlyForTodos() throws {
        let context = try TestStore.context()
        let note = F.note(in: context)
        XCTAssertEqual(rows(note, .organize), [.type, .bowl, .tags])
        let todo = F.todo(due: F.day(3), in: context)
        XCTAssertEqual(rows(todo, .organize), [.type, .bowl, .due, .repeat, .tags])
        // A note that was a to-do keeps its day stored without showing it.
        Todos.setTodo(false, todo, in: context)
        XCTAssertEqual(rows(todo, .organize), [.type, .bowl, .tags])
    }

    func testSuggestedBowlOnlyInTheInbox() throws {
        let context = try TestStore.context()
        let bills = F.bowl("House & Bills", in: context)
        let old = F.bowl("Old", in: context)
        old.archivedAt = Date()
        let pdf = F.pdf(in: context)
        pdf.suggestedProjectIDs = [Projects.key(old), Projects.key(bills)]
        let state = EntryContext(bowls: [bills, old])
        XCTAssertEqual(rows(pdf, .organize, state), [.type, .bowl, .suggestedBowl, .tags])
        XCTAssertEqual(EntryDetails.suggestion(for: pdf, context: state)?.id, bills.id, "an archived bowl is no suggestion")
        F.file(pdf, into: bills)
        XCTAssertEqual(rows(pdf, .organize, state), [.type, .bowl, .tags])
    }

    func testAppointmentActivityAndOrigin() throws {
        let context = try TestStore.context()
        let meeting = F.meeting(in: context)
        XCTAssertEqual(rows(meeting, .appointment), [.appointment])
        XCTAssertEqual(rows(meeting, .sharingActivity), [.sharing, .origin])
        var state = EntryContext()
        state.appointment = AppointmentRef(CalendarAppointment.fixture(title: "Design Review"))
        state.activityLine = "Changed by Anna"
        XCTAssertEqual(rows(meeting, .appointment, state), [.appointment, .sameAppointment])
        XCTAssertEqual(rows(meeting, .sharingActivity, state), [.sharing, .activity, .origin])
    }

    func testLockedInViewOnlyAndTrash() throws {
        let context = try TestStore.context()
        let note = F.todo(in: context)
        func allLocked(_ state: EntryContext) -> Bool {
            EntryDetails.sections(for: note, context: state).flatMap(\.rows).allSatisfy(\.isLocked)
        }
        func noneLocked(_ state: EntryContext) -> Bool {
            EntryDetails.sections(for: note, context: state).flatMap(\.rows).allSatisfy { !$0.isLocked }
        }
        XCTAssertTrue(noneLocked(EntryContext()))
        XCTAssertTrue(EntryDetails.canSwitchTodo(note, context: EntryContext()))

        var viewOnly = EntryContext()
        viewOnly.isReadOnly = true
        XCTAssertTrue(allLocked(viewOnly))
        XCTAssertFalse(EntryDetails.canSwitchTodo(note, context: viewOnly))
        XCTAssertNil(EntryDetails.sections(for: note, context: viewOnly).first { $0.kind == .appointment }?.action)

        NoteStore.trash(note, in: context)
        XCTAssertTrue(allLocked(EntryContext()))
        XCTAssertFalse(EntryDetails.canSwitchTodo(note, context: EntryContext()))

        // A link never becomes a to-do here (`Note.canBeTodo`).
        XCTAssertFalse(EntryDetails.canSwitchTodo(F.link(in: context), context: EntryContext()))
    }

    func testSeveralEntriesShowOnlyTheirCommonFields() throws {
        let context = try TestStore.context()
        let a = F.pdf("A", document: DocumentInfo(kind: .invoice), in: context)
        let b = F.pdf("B", document: DocumentInfo(kind: .letter), in: context)
        let c = F.pdf("C", in: context)
        // Three PDFs in the Inbox: bowl, later, the document fields, merge, delete (no paid mark).
        XCTAssertEqual(EntryDetails.commonFields(for: [a, b, c], isReadOnly: { _ in false }), [
            .bowl, .later, .documentKind, .sender(count: 3), .mergePDFs(count: 3), .delete(count: 3),
        ])
        // With a note among them: no document fields, no merge; filed, no later.
        let note = F.note(in: context)
        let work = F.bowl("Work", in: context)
        F.file(note, into: work)
        XCTAssertEqual(EntryDetails.commonFields(for: [a, note], isReadOnly: { _ in false }), [.bowl, .delete(count: 2)])
        // Two to-dos share a due day.
        let t1 = F.todo(in: context), t2 = F.todo(in: context)
        XCTAssertEqual(EntryDetails.commonFields(for: [t1, t2], isReadOnly: { _ in false }), [.bowl, .later, .due, .delete(count: 2)])
        // Entries that cannot change leave nothing.
        NoteStore.trash(t1, in: context)
        XCTAssertEqual(EntryDetails.commonFields(for: [t1], isReadOnly: { _ in false }), [])
        XCTAssertEqual(EntryDetails.commonFields(for: [t2], isReadOnly: { _ in true }), [])
    }
}

extension CalendarAppointment {
    /// An appointment today at ten for 45 minutes.
    static func fixture(title: String) -> CalendarAppointment {
        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
        return CalendarAppointment(
            id: UUID().uuidString, title: title, start: start, end: start.addingTimeInterval(45 * 60), isAllDay: false, calendarName: "Work"
        )
    }
}
