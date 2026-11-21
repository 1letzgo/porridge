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
}
