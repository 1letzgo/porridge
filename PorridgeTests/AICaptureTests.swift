import SwiftData
import XCTest
@testable import Porridge

/// Task detection in notes, splitting a note into a bowl, and bundling inbox entries into a new bowl.
@MainActor
final class AICaptureTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "AICaptureTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: Task detection

    func testFindsTasksInPlainLinesAndListsButNotInProse() {
        let text = """
        Einkauf und Kram
        - Milch kaufen
        - Anna anrufen
        TODO: Angebot an Müller schicken
        I need to book the flight to Lisbon.
        Call the dentist about Friday
        Wir haben gestern lange über das Budget gesprochen und das war gut.
        - [ ] already a checkbox
        ## Ideen
        Is this a task?
        """
        let found = TaskDetection.detect(in: text)
        XCTAssertEqual(found.map(\.text), [
            "Milch kaufen", "Anna anrufen", "Angebot an Müller schicken", "I need to book the flight to Lisbon", "Call the dentist about Friday",
        ])
        XCTAssertEqual(found.map(\.line), [1, 2, 3, 4, 5])
    }

    func testStatementsAreNoTasks() {
        for line in ["Wir haben das Projekt abgeschlossen", "Ich habe das schon gemacht", "Das war ein schöner Tag", "The meeting was fine", "x"] {
            XCTAssertNil(TaskDetection.taskText(of: line), line)
        }
    }

    func testEachTaskOnceAndDueDayFromItsWords() {
        let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 22))!
        let found = TaskDetection.detect(in: "- Rechnung bezahlen bis 28.11.\n- Rechnung bezahlen bis 28.11.", now: now, calendar: utc)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.dueDay, "2026-11-28")
    }

    func testNeverForLinksOrSavedFiles() {
        let link = Note()
        link.url = "https://example.com"
        link.text = "- Milch kaufen"
        XCTAssertFalse(TaskDetection.applies(to: link))
        XCTAssertTrue(TaskDetection.pending(for: link, defaults: defaults).isEmpty)

        let shared = Note()
        shared.source = .share
        shared.text = "- Anna anrufen"
        XCTAssertFalse(TaskDetection.applies(to: shared))

        let mine = Note()
        mine.text = "- Anna anrufen"
        XCTAssertTrue(TaskDetection.applies(to: mine))
        XCTAssertEqual(TaskDetection.pending(for: mine, defaults: defaults).count, 1)
    }

    func testMakeTodoTurnsLinesIntoSubtasks() throws {
        let context = try TestStore.context()
        let note = Note()
        note.text = "Samstag\n- Milch kaufen\n  Anna anrufen\nSchönes Wetter heute."
        context.insert(note)
        let tasks = TaskDetection.detect(in: note.text)
        XCTAssertEqual(tasks.count, 2)
        TaskDetection.makeTodo(note, with: tasks, in: context)
        XCTAssertTrue(note.isTodo)
        XCTAssertEqual(note.text, "Samstag\n- [ ] Milch kaufen\n  - [ ] Anna anrufen\nSchönes Wetter heute.")
        XCTAssertEqual(Todos.subtasks(in: note.text).map(\.text), ["Milch kaufen", "Anna anrufen"])
        // Nothing left to offer.
        XCTAssertTrue(TaskDetection.detect(in: note.text).isEmpty)
    }

    func testAddAsSubtasksKeepsTheNoteAndLeavesChangedLinesAlone() throws {
        let context = try TestStore.context()
        let note = Note()
        note.text = "- Milch kaufen\n- Anna anrufen"
        context.insert(note)
        let tasks = TaskDetection.detect(in: note.text)
        // The second line was changed after it was read.
        note.text = "- Milch kaufen\n- Wetter war schön"
        TaskDetection.addAsSubtasks(note, tasks, in: context)
        XCTAssertFalse(note.isTodo)
        XCTAssertEqual(note.text, "- [ ] Milch kaufen\n- Wetter war schön")
    }

    func testDismissedTasksAreNotOfferedAgain() {
        let note = Note()
        note.text = "- Milch kaufen\n- Anna anrufen"
        let tasks = TaskDetection.pending(for: note, defaults: defaults)
        TaskDetection.dismiss([tasks[0]], for: note, defaults: defaults)
        XCTAssertEqual(TaskDetection.pending(for: note, defaults: defaults).map(\.text), ["Anna anrufen"])
        XCTAssertEqual(TaskDetection.label(count: 1), "1 possible to-do")
        XCTAssertEqual(TaskDetection.label(count: 2), "2 possible to-dos")
    }

    // MARK: Splitting a note

    private let meetingNotes = """
    ## Budget
    We agreed on 12k for the first quarter.
    Marketing gets a bit more.
    - [ ] Send the budget to Anna
    ## Hiring
    Two developers start in January.
    Call the agency about the third one
    ## Office
    - [x] Keys handed over
    """

    func testStructuralSplitByHeadingsWithTasksAsTodos() {
        let proposal = NoteSplitter.structural(title: "Team Sync", text: meetingNotes)
        XCTAssertEqual(proposal.bowlName, "Team Sync")
        XCTAssertEqual(proposal.entries.filter { !$0.isTodo }.map(\.title), ["Budget", "Hiring", "Office"])
        XCTAssertEqual(proposal.entries.first?.text, "We agreed on 12k for the first quarter.\nMarketing gets a bit more.")
        XCTAssertEqual(proposal.entries.filter(\.isTodo).map(\.title), ["Send the budget to Anna", "Call the agency about the third one"])
        // A ticked line is done: it stays in its section.
        XCTAssertEqual(proposal.entries.first { $0.title == "Office" }?.text, "- [x] Keys handed over")
    }

    func testStructuralSplitWithoutHeadingsByParagraphs() {
        let text = "First topic is about the garden.\nMore on the garden.\n\nSecond topic: the car needs tyres.\n\nBuy new tyres"
        let proposal = NoteSplitter.structural(title: "", text: text)
        XCTAssertEqual(proposal.entries.filter { !$0.isTodo }.count, 2)
        XCTAssertEqual(proposal.entries.filter(\.isTodo).map(\.title), ["Buy new tyres"])
        XCTAssertEqual(proposal.bowlName, "First topic is about the garden.")
    }

    func testParsesTheModelsAnswer() {
        let answer = """
        BOWL: Team Sync Q1
        ## Budget
        12k for Q1.
        ## Hiring
        Two developers in January.
        TODO: Send the budget to Anna
        TODO: Send the budget to Anna
        - [ ] Call the agency
        """
        let proposal = NoteSplitter.parse(answer, fallbackName: "x")
        XCTAssertEqual(proposal?.bowlName, "Team Sync Q1")
        XCTAssertEqual(proposal?.entries.map(\.title), ["Budget", "Hiring", "Send the budget to Anna", "Call the agency"])
        XCTAssertEqual(proposal?.entries.map(\.isTodo), [false, false, true, true])
        XCTAssertNil(NoteSplitter.parse("Sorry, I can't.", fallbackName: "x")?.entries.first { $0.isTodo })
        XCTAssertNil(NoteSplitter.parse("", fallbackName: "x"))
    }

    func testOnlyLongOwnNotesCanBeSplit() {
        let short = Note()
        short.text = "Short"
        XCTAssertFalse(NoteSplitter.canSplit(short))
        let long = Note()
        long.text = meetingNotes
        XCTAssertTrue(NoteSplitter.canSplit(long))
        let link = Note()
        link.url = "https://example.com"
        link.text = meetingNotes
        XCTAssertFalse(NoteSplitter.canSplit(link))
    }

    func testApplyMakesBowlAndEntriesAndUndoTakesThemBack() throws {
        let context = try TestStore.context()
        let note = Note()
        note.title = "Team Sync"
        note.text = meetingNotes
        context.insert(note)
        try context.save()
        var proposal = NoteSplitter.structural(title: note.title, text: note.text)
        proposal.entries[1].isIncluded = false

        let change = try XCTUnwrap(NoteSplitter.apply(proposal, from: note, moveSource: true, in: context))
        let bowls = try context.fetch(FetchDescriptor<NoteFolder>())
        XCTAssertEqual(bowls.map(\.name), ["Team Sync"])
        let key = Projects.key(bowls[0])
        let all = try context.fetch(FetchDescriptor<Note>())
        let made = all.filter { $0.id != note.id }
        XCTAssertEqual(made.count, proposal.entries.count - 1)
        XCTAssertTrue(made.allSatisfy { $0.projectIDs == [key] })
        XCTAssertEqual(made.filter(\.isTodo).count, 2)
        XCTAssertTrue(made.filter(\.isTodo).allSatisfy { $0.todoSourceID == note.id.uuidString })
        // The note is in the bowl too, unchanged otherwise, and never archived.
        XCTAssertEqual(note.projectIDs, [key])
        XCTAssertEqual(note.text, meetingNotes)
        XCTAssertNil(note.archivedAt)

        BowlMaking.undo(change, in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).map(\.id), [note.id])
        XCTAssertTrue(try context.fetch(FetchDescriptor<NoteFolder>()).isEmpty)
        XCTAssertTrue(note.isInInbox)
    }

    func testApplyUsesAnExistingBowlOfThatName() throws {
        let context = try TestStore.context()
        let existing = NoteFolder(name: "Team Sync")
        context.insert(existing)
        let note = Note()
        note.text = meetingNotes
        context.insert(note)
        var proposal = NoteSplitter.structural(title: "team sync", text: note.text)
        proposal.bowlName = "team sync"
        let change = try XCTUnwrap(NoteSplitter.apply(proposal, from: note, moveSource: false, in: context))
        XCTAssertFalse(change.createdBowl)
        XCTAssertEqual(change.bowlID, existing.id)
        XCTAssertTrue(note.isInInbox)
        BowlMaking.undo(change, in: context)
        // The bowl was there before: it stays.
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteFolder>()).count, 1)
    }

    // MARK: Inbox bundling

    private func vector(_ values: [Float]) -> [Float] {
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return values.map { $0 / norm }
    }

    func testClustersCloseVectorsAndLeavesTheRest() {
        let ids = (0..<8).map { _ in UUID() }
        var vectors: [UUID: [Float]] = [:]
        // Three about gardening, three about cars, two alone; all share a large common part, as sentence vectors do.
        let base: [Float] = [5, 5, 5, 5, 0, 0, 0, 0]
        func with(_ extra: [Float]) -> [Float] { vector(zip(base, extra).map(+)) }
        vectors[ids[0]] = with([0, 0, 0, 0, 2, 0, 0, 0.1])
        vectors[ids[1]] = with([0, 0, 0, 0, 2.1, 0, 0.1, 0])
        vectors[ids[2]] = with([0, 0, 0, 0, 1.9, 0.1, 0, 0])
        vectors[ids[3]] = with([0, 0, 0, 0, 0, 2, 0, 0])
        vectors[ids[4]] = with([0, 0, 0, 0, 0.1, 2, 0, 0])
        vectors[ids[5]] = with([0, 0, 0, 0, 0, 1.9, 0.1, 0])
        vectors[ids[6]] = with([0, 0, 0, 0, 0, 0, 2, 0])
        vectors[ids[7]] = with([0, 0, 0, 0, 0, 0, 0, 2])
        let clusters = InboxBundler.clusters(vectors).map(Set.init)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertTrue(clusters.contains(Set(ids[0...2])))
        XCTAssertTrue(clusters.contains(Set(ids[3...5])))
    }

    func testTooFewEntriesGiveNoCluster() {
        let a = UUID(), b = UUID()
        XCTAssertTrue(InboxBundler.clusters([a: [1, 0], b: [1, 0]]).isEmpty)
    }

    func testNamesTheGroupByASharedTagOrTitleWord() {
        XCTAssertEqual(InboxBundler.name(for: [("Roses", ["garden"]), ("Lawn", ["garden"]), ("Fence", ["home"])]), "Garden")
        XCTAssertEqual(InboxBundler.name(for: [("Tyres for the car", []), ("Car insurance", []), ("Car wash", [])]), "Car")
        XCTAssertEqual(InboxBundler.name(for: [("A", []), ("B", []), ("C", [])]), "New Bowl")
    }

    func testDismissedGroupsStayAwayAlsoWhenSlightlyDifferent() {
        let ids = (0..<4).map { _ in UUID() }
        InboxBundler.dismiss(InboxBundle(noteIDs: Array(ids[0...2]), name: "X"), defaults: defaults)
        let dismissed = InboxBundler.dismissedGroups(defaults)
        XCTAssertTrue(InboxBundler.isDismissed(Array(ids[0...2]), dismissed: dismissed))
        XCTAssertTrue(InboxBundler.isDismissed(Array(ids[0...3]), dismissed: dismissed))
        XCTAssertFalse(InboxBundler.isDismissed([ids[3], UUID(), UUID()], dismissed: dismissed))
    }

    func testSuggestionSkipsEntriesWithASuggestedBowlAndFallsBackToTags() throws {
        let context = try TestStore.context()
        let bowl = NoteFolder(name: "Garden")
        context.insert(bowl)
        var notes: [Note] = []
        for title in ["Roses", "Lawn", "Hedge", "Tomatoes"] {
            let note = Note()
            note.title = title
            note.labels = ["garden"]
            context.insert(note)
            notes.append(note)
        }
        // One of them already has a bowl suggested: it is left out.
        notes[3].suggestedProjectIDs = [Projects.key(bowl)]
        let suggestion = try XCTUnwrap(InboxBundler.suggestion(inbox: notes, vectors: [:], dismissed: [], existingNames: ["Garden"]))
        XCTAssertEqual(Set(suggestion.noteIDs), Set(notes[0...2].map(\.id)))
        XCTAssertEqual(suggestion.name, "Garden")
        XCTAssertTrue(suggestion.isExistingBowl)

        // Dismissed, it is gone.
        XCTAssertNil(InboxBundler.suggestion(inbox: notes, vectors: [:], dismissed: [suggestion.noteIDs.map(\.uuidString)]))
    }

    func testApplyMovesChosenEntriesAndUndoPutsThemBack() throws {
        let context = try TestStore.context()
        var notes: [Note] = []
        for title in ["Roses", "Lawn", "Hedge"] {
            let note = Note()
            note.title = title
            context.insert(note)
            notes.append(note)
        }
        try context.save()
        let change = try XCTUnwrap(InboxBundler.apply(name: "Garden", noteIDs: notes.prefix(2).map(\.id), notes: notes, in: context))
        XCTAssertTrue(change.createdBowl)
        XCTAssertEqual(notes.filter(\.isInInbox).map(\.title), ["Hedge"])
        XCTAssertEqual(notes[0].projectIDs, [change.bowlID.uuidString])
        XCTAssertEqual(change.summary, "Bowl “Garden” made: 2 entries")

        BowlMaking.undo(change, in: context)
        XCTAssertTrue(notes.allSatisfy(\.isInInbox))
        XCTAssertNil(notes[0].filedAt)
        XCTAssertTrue(try context.fetch(FetchDescriptor<NoteFolder>()).isEmpty)
    }
}
