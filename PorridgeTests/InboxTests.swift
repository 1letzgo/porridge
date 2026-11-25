import SwiftData
import XCTest
@testable import Porridge

/// The inbox: what waits in it, how a note leaves it, and how a suggested bowl is read from a model's answer.
@MainActor
final class InboxTests: XCTestCase {
    func testANoteStaysInTheInboxUntilItIsInABucketAndComesBackOutOfIt() throws {
        let context = try TestStore.context()
        let project = NoteFolder(name: "Trip to Goa")
        context.insert(project)
        let old = Note(), a = Note(), c = Note()
        old.createdAt = Date(timeIntervalSince1970: 1_000_000)
        // Dropping a suggestion or having been filed once does not take a note out: only a bowl does.
        old.filedAt = old.createdAt
        a.createdAt = Date(timeIntervalSince1970: 2_000_000)
        c.createdAt = Date(timeIntervalSince1970: 3_000_000)
        [old, a, c].forEach(context.insert)
        a.suggestedProjectIDs = [Projects.key(project)]
        // Newest on top.
        XCTAssertEqual(Inbox.notes([old, a, c]).map(\.id), [c.id, a.id, old.id])

        Inbox.file(a, into: Projects.key(project), in: context)
        Projects.toggle(project, on: c, in: context)
        XCTAssertEqual(Inbox.notes([old, a, c]).map(\.id), [old.id])
        XCTAssertEqual(a.projectIDs, [Projects.key(project)])
        XCTAssertTrue(a.suggestedProjectIDs.isEmpty)

        // Taken out of its only bowl, a note is back in the inbox; trashed it is not in it. Notes are never
        // archived: an `archivedAt` left by an earlier version keeps nothing out.
        Projects.toggle(project, on: c, in: context)
        XCTAssertTrue(c.isInInbox)
        c.archivedAt = Date()
        old.deletedAt = Date()
        XCTAssertEqual(Inbox.notes([old, a, c]).map(\.id), [c.id])
    }

    func testAnEntryIsInOneBowlAtMost() throws {
        let context = try TestStore.context()
        let home = NoteFolder(name: "Home"), work = NoteFolder(name: "Work"), trip = NoteFolder(name: "Trip")
        [home, work, trip].forEach(context.insert)
        let note = Note()
        context.insert(note)

        // Filing, accepting a suggestion and the menus replace the bowl, they never add a second.
        Inbox.file(note, into: Projects.key(home), in: context)
        Inbox.file(note, into: Projects.key(work), in: context)
        XCTAssertEqual(note.projectIDs, [Projects.key(work)])
        Projects.toggle(trip, on: note, in: context)
        XCTAssertEqual(note.projectIDs, [Projects.key(trip)])
        Projects.toggle(trip, on: note, in: context)
        XCTAssertTrue(note.isInInbox)
        Documents.apply(.move(toBowl: Projects.key(home)), to: [note], in: context)
        XCTAssertEqual(note.projectIDs, [Projects.key(home)])
        XCTAssertEqual(Projects.assigned("X"), ["X"])

        // An entry from before in several bowls keeps them; taking it out of one leaves the others, and putting it
        // into a bowl moves it there.
        let old = Note()
        old.projectIDs = [Projects.key(home), Projects.key(work)]
        context.insert(old)
        Projects.remove(home, from: old, in: context)
        XCTAssertEqual(old.projectIDs, [Projects.key(work)])
        old.projectIDs = [Projects.key(home), Projects.key(work)]
        Projects.toggle(trip, on: old, in: context)
        XCTAssertEqual(old.projectIDs, [Projects.key(trip)])
    }

    func testTheSuggestedBucketIsReadOffTheAnswer() {
        let projects = [NoteFolder(name: "Trip to Goa"), NoteFolder(name: "Küche")]
        let line = Inbox.promptLine(projects)
        XCTAssertTrue(line.contains("Trip to Goa | Küche"))
        XCTAssertEqual(Inbox.promptLine([]), "")

        let answer = "## Summary\nFlights are booked.\n\nTAGS: travel, flights\nPROJECT: \"trip to goa\""
        let (text, project) = Inbox.splitProject(answer, projects: projects)
        XCTAssertEqual(project?.name, "Trip to Goa")
        XCTAssertEqual(text, "## Summary\nFlights are booked.\n\nTAGS: travel, flights")

        // "none" and a bowl the model made up are no suggestion; the line still goes.
        for name in ["none", "Holidays"] {
            let (rest, made) = Inbox.splitProject("Text\nPROJECT: \(name)", projects: projects)
            XCTAssertNil(made)
            XCTAssertEqual(rest, "Text")
        }
        XCTAssertEqual(Inbox.splitProject("No line", projects: projects).text, "No line")
    }

    func testOnlyANoteInNoBucketGetsBucketsOffered() throws {
        let context = try TestStore.context()
        let active = NoteFolder(name: "Work"), archived = NoteFolder(name: "Old")
        archived.archivedAt = Date()
        [active, archived].forEach(context.insert)
        let note = Note()
        context.insert(note)
        XCTAssertEqual(Inbox.candidates(for: note).map(\.name), ["Work"])
        Inbox.file(note, into: Projects.key(active), in: context)
        XCTAssertTrue(Inbox.candidates(for: note).isEmpty)
    }

    // MARK: Triage and filing (stage 6)

    func testTriageGoesThroughWhatIsNewInTheInboxesOrder() throws {
        let context = try TestStore.context()
        let bowl = NoteFolder(name: "Reading")
        context.insert(bowl)
        let first = Note(), second = Note(), third = Note(), filed = Note()
        for (index, note) in [third, second, first].enumerated() {
            note.createdAt = Date(timeIntervalSince1970: Double(1_000_000 * (index + 1)))
        }
        filed.projectIDs = [Projects.key(bowl)]
        let all = [first, second, third, filed]
        all.forEach(context.insert)

        // Newest first, only what waits (not what is filed).
        var triage = InboxTriage(notes: all)
        XCTAssertEqual(triage.total, 3)
        XCTAssertEqual(triage.current(in: all)?.note.id, first.id)
        XCTAssertEqual(triage.number(in: all), 1)
        XCTAssertEqual(triage.upcoming(in: all).map(\.id), [second.id, third.id])

        // Skip moves on; the skipped one still waits in the Inbox.
        triage.advance(in: all)
        XCTAssertEqual(triage.current(in: all)?.note.id, second.id)
        XCTAssertEqual(triage.number(in: all), 2)
        XCTAssertTrue(first.isInInbox)

        // An entry that left the Inbox (filed here or on another device) is passed over without a step.
        Inbox.file(second, into: Projects.key(bowl), in: context)
        XCTAssertEqual(triage.current(in: all)?.note.id, third.id)
        XCTAssertEqual(triage.number(in: all), 3, "counted by its place at the start")
        // Brought back (Undo), it is in front again.
        second.projectIDs = []
        XCTAssertEqual(triage.current(in: all)?.note.id, second.id)

        triage.advance(in: all)
        triage.advance(in: all)
        XCTAssertTrue(triage.isFinished(in: all))
        XCTAssertNil(triage.current(in: all))
        XCTAssertTrue(triage.upcoming(in: all).isEmpty)
    }

    func testFileIntoTheSuggestionWithUndo() throws {
        let context = try TestStore.context()
        let toast = UndoToast.shared
        let reading = NoteFolder(name: "Reading"), old = NoteFolder(name: "Old")
        old.archivedAt = Date()
        [reading, old].forEach(context.insert)
        let link = Note(), other = Note()
        link.title = "The Case for Slow Software"
        // An archived bowl is passed over: the first suggestion that can take the entry wins.
        link.suggestedProjectIDs = [Projects.key(old), Projects.key(reading)]
        [link, other].forEach(context.insert)
        try context.save()
        let bowls = [reading, old]

        XCTAssertEqual(EntryMeta.suggestion(for: link, bowls: bowls)?.id, reading.id)
        XCTAssertNil(EntryMeta.suggestion(for: other, bowls: bowls), "nothing suggested, no ✦ word")
        XCTAssertFalse(InboxTriage.file(other, bowls: bowls, in: context), "without a suggestion the bowl list opens")
        XCTAssertTrue(other.isInInbox)

        XCTAssertTrue(InboxTriage.file(link, bowls: bowls, in: context))
        XCTAssertEqual(link.projectIDs, [Projects.key(reading)])
        XCTAssertTrue(link.suggestedProjectIDs.isEmpty)
        XCTAssertNil(EntryMeta.suggestion(for: link, bowls: bowls), "filed, it has no suggestion any more")
        XCTAssertEqual(toast.current?.message, "Moved to “Reading”")
        toast.undo()
        XCTAssertTrue(link.isInInbox)
        XCTAssertEqual(link.suggestedProjectIDs, [Projects.key(old), Projects.key(reading)], "Undo brings the suggestion back")
        XCTAssertEqual(EntryMeta.suggestion(for: link, bowls: bowls)?.id, reading.id)
    }

    func testTheBundleCardIsOneLine() {
        let ids = [UUID(), UUID(), UUID()]
        XCTAssertEqual(InboxBundle(noteIDs: ids, name: "Berlin Trip").line, "New bowl “Berlin Trip” for 3 entries?")
        XCTAssertEqual(InboxBundle(noteIDs: ids, name: "Reading", isExistingBowl: true).line, "3 entries for “Reading”?")
    }

    func testTriageIsAGoToCommand() {
        let found = SearchAsk.goTo("triage", in: SearchAsk.places())
        XCTAssertEqual(found.first?.destination, .triage)
        XCTAssertEqual(found.first?.title, "Triage Inbox")
    }
}
