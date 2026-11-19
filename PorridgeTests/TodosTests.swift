import SwiftData
import XCTest
@testable import Porridge

/// To-dos: notes with a done state whose subtasks are the checklist lines of their text. Android's `TodosTest`
/// has to give the same answers.
@MainActor
final class TodosTests: XCTestCase {
    private let text = """
    Before the trip
    - [ ] Passport
    - [x] Tickets
      - [ ] Seat **window**
    - [ ]
    - plain bullet
    ```
    - [ ] in code
    ```
    """

    // MARK: Parsing

    func testSubtasksAreTheChecklistLinesWithText() {
        let items = Todos.subtasks(in: text)
        XCTAssertEqual(items.map(\.text), ["Passport", "Tickets", "Seat **window**"])
        XCTAssertEqual(items.map(\.line), [1, 2, 3])
        XCTAssertEqual(items.map(\.done), [false, true, false])
        XCTAssertEqual(items.map(\.indent), [0, 0, 1])
        XCTAssertEqual(Todos.subtasks(in: "* [X] Upper\n+ [ ] Plus").map(\.done), [true, false])
    }

    func testProgress() {
        let progress = Todos.progress(text)
        XCTAssertEqual(progress, Todos.Progress(done: 1, total: 3))
        XCTAssertEqual(progress.label, "1/3")
        XCTAssertFalse(progress.isComplete)
        XCTAssertEqual(Todos.progress("Just text").label, "")
        XCTAssertFalse(Todos.progress("").isComplete)
        XCTAssertTrue(Todos.progress("- [x] a\n- [X] b").isComplete)
    }

    // MARK: Editing

    func testToggleChangesOnlyThatLine() {
        let toggled = Todos.toggleLine(1, in: text)
        XCTAssertTrue(toggled.contains("- [x] Passport"))
        XCTAssertEqual(toggled.components(separatedBy: "\n").count, text.components(separatedBy: "\n").count)
        XCTAssertEqual(Todos.toggleLine(3, in: text).components(separatedBy: "\n")[3], "  - [x] Seat **window**")
        // Not a subtask: nothing changes.
        XCTAssertEqual(Todos.toggleLine(0, in: text), text)
        XCTAssertEqual(Todos.toggleLine(7, in: text), text)
        XCTAssertEqual(Todos.toggleLine(99, in: text), text)
    }

    func testSetAllTicksEverySubtask() {
        XCTAssertTrue(Todos.progress(Todos.setAll(true, in: text)).isComplete)
        XCTAssertEqual(Todos.progress(Todos.setAll(false, in: text)).done, 0)
        // The code block stays as it is.
        XCTAssertTrue(Todos.setAll(true, in: text).contains("- [ ] in code"))
    }

    func testAddMoveRemove() {
        XCTAssertEqual(Todos.appendingSubtask("Milk", to: ""), "- [ ] Milk")
        XCTAssertEqual(Todos.appendingSubtask("Milk", to: "Shop\n\n"), "Shop\n- [ ] Milk")
        // An empty checklist line at the end is reused, not doubled.
        XCTAssertEqual(Todos.appendingSubtask(to: "- [x] a\n- [ ] "), "- [x] a\n- [ ] ")
        let list = "- [ ] a\n- [ ] b\n- [ ] c"
        XCTAssertEqual(Todos.moveLine(2, by: -1, in: list), "- [ ] a\n- [ ] c\n- [ ] b")
        XCTAssertEqual(Todos.moveLine(0, by: 1, in: list), "- [ ] b\n- [ ] a\n- [ ] c")
        XCTAssertEqual(Todos.moveLine(0, by: -1, in: list), list)
        XCTAssertEqual(Todos.removeLine(1, in: list), "- [ ] a\n- [ ] c")
    }

    // MARK: Done rules

    func testTickingTheLastOpenSubtaskFinishesTheTodo() {
        let old = "- [x] a\n- [ ] b"
        XCTAssertEqual(Todos.stateAfterEdit(old: old, new: "- [x] a\n- [x] b", state: .open), .done)
        XCTAssertNil(Todos.stateAfterEdit(old: "- [ ] a\n- [ ] b", new: "- [x] a\n- [ ] b", state: .open))
    }

    func testAnOpenSubtaskReopensADoneTodo() {
        let done = "- [x] a\n- [x] b"
        // Unticked.
        XCTAssertEqual(Todos.stateAfterEdit(old: done, new: "- [x] a\n- [ ] b", state: .done), .open)
        // Added.
        XCTAssertEqual(Todos.stateAfterEdit(old: done, new: done + "\n- [ ] c", state: .done), .open)
        // Text edited, boxes alike: stays.
        XCTAssertNil(Todos.stateAfterEdit(old: done, new: "- [x] a!\n- [x] b", state: .done))
    }

    func testReopenedByHandWithEverythingTickedStaysOpen() {
        let done = "- [x] a\n- [x] b"
        XCTAssertNil(Todos.stateAfterEdit(old: done, new: done + "\nmore words", state: .open))
    }

    func testDoneTicksAllAndTogglingFollows() throws {
        let context = try TestStore.context()
        let note = Note()
        note.text = "- [ ] a\n- [ ] b"
        context.insert(note)
        Todos.setTodo(true, note, in: context)
        XCTAssertEqual(note.todoState, .open)
        XCTAssertTrue(note.isTodo)

        Todos.toggleSubtask(line: 0, of: note, in: context)
        XCTAssertFalse(note.isDone)
        Todos.toggleSubtask(line: 1, of: note, in: context)
        XCTAssertTrue(note.isDone)
        XCTAssertNotNil(note.todoDoneAt)

        Todos.toggleSubtask(line: 1, of: note, in: context)
        XCTAssertFalse(note.isDone)
        XCTAssertNil(note.todoDoneAt)

        Todos.setDone(true, note, in: context)
        XCTAssertTrue(note.todoProgress.isComplete)
        // Opening it again leaves the subtasks ticked.
        Todos.setDone(false, note, in: context)
        XCTAssertTrue(note.todoProgress.isComplete)
        XCTAssertFalse(note.isDone)

        // Back to a note: "none" is kept so the other devices learn of it, the text stays.
        Todos.setTodo(false, note, in: context)
        XCTAssertEqual(note.todoStateRaw, "none")
        XCTAssertFalse(note.isTodo)
        XCTAssertEqual(note.text, "- [x] a\n- [x] b")
    }

    func testDoneTodosAreArchivedFromTheNextDay() throws {
        let context = try TestStore.context()
        let note = Note()
        note.todoState = .done
        note.todoDoneAt = Date()
        context.insert(note)
        XCTAssertFalse(note.isArchived)
        XCTAssertTrue(note.isInInbox)

        note.todoDoneAt = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        XCTAssertTrue(note.isPutAway)
        XCTAssertTrue(note.isArchived)
        XCTAssertFalse(note.isInInbox)
        XCTAssertEqual(HomeList.archivedNotes([note]).map(\.id), [note.id])

        // Taken out of the archive it is open again.
        Archive.set(false, note, in: context)
        XCTAssertEqual(note.todoState, .open)
        XCTAssertFalse(note.isArchived)
    }

    func testSummaryTaskBecomesATodoInTheSameBuckets() throws {
        let context = try TestStore.context()
        let meeting = Note()
        meeting.projectIDs = ["B1"]
        meeting.summary = "## Action Items\n- [ ] Send the offer"
        context.insert(meeting)
        let todo = try XCTUnwrap(Todos.create(fromTask: "Send the offer", of: meeting, in: context))
        XCTAssertEqual(todo.title, "Send the offer")
        XCTAssertEqual(todo.todoState, .open)
        XCTAssertEqual(todo.projectIDs, ["B1"])
        XCTAssertEqual(todo.todoSourceID, meeting.id.uuidString)
        XCTAssertEqual(Todos.madeFrom(meeting, among: [meeting, todo]).map(\.id), [todo.id])

        let link = Note()
        link.url = "https://example.com"
        context.insert(link)
        XCTAssertNil(Todos.create(fromTask: "Read it", of: link, in: context))
        XCTAssertFalse(link.canBeTodo)
    }

    // MARK: Sync

    func testRecordsKeepTheTodoAndOlderRecordsDoNotErase() throws {
        let context = try TestStore.context()
        let plain = Note()
        context.insert(plain)
        // A note that never was a to-do writes no to-do fields.
        XCTAssertNil(SyncRecords.record(plain)["todoStateRaw"])

        let todo = Note()
        todo.text = "- [x] a"
        todo.todoState = .done
        todo.todoDoneAt = Date(timeIntervalSince1970: 1_000)
        todo.todoSourceID = "S"
        context.insert(todo)
        let record = SyncRecords.record(todo)
        XCTAssertEqual(record["todoStateRaw"] as? String, "done")
        XCTAssertEqual(record["todoDoneAt"] as? Int64, 1_000_000)
        XCTAssertEqual(record["todoSourceID"] as? String, "S")

        let copy = Note()
        context.insert(copy)
        SyncRecords.apply(record, to: copy)
        XCTAssertTrue(copy.isDone)
        XCTAssertEqual(copy.todoDoneAt, todo.todoDoneAt)
        XCTAssertEqual(copy.todoSourceID, "S")

        // A version without to-dos edited the note: its record has no to-do fields, the to-do stays here.
        var old = record
        old["todoStateRaw"] = nil
        old["todoDoneAt"] = nil
        old["todoSourceID"] = nil
        old["text"] = "- [x] a\nedited elsewhere"
        SyncRecords.apply(old, to: copy)
        XCTAssertEqual(copy.text, "- [x] a\nedited elsewhere")
        XCTAssertTrue(copy.isDone)
        XCTAssertEqual(copy.todoSourceID, "S")

        // Turned back into a note elsewhere.
        var none = record
        none["todoStateRaw"] = "none"
        none["todoDoneAt"] = nil
        SyncRecords.apply(none, to: copy)
        XCTAssertFalse(copy.isTodo)
        XCTAssertNil(copy.todoDoneAt)
    }

    func testMergeTicksKeepsBothDevicesTicks() {
        let base = "- [ ] a\n- [ ] b\n- [ ] c"
        let merged = Todos.mergeTicks(base: base, winner: "- [x] a\n- [ ] b\n- [ ] c", loser: "- [ ] a\n- [ ] b\n- [x] c")
        XCTAssertEqual(merged, "- [x] a\n- [ ] b\n- [x] c")
        // The newer side's own change wins over the other's on the same subtask.
        XCTAssertEqual(Todos.mergeTicks(base: "- [x] a", winner: "- [x] a", loser: "- [ ] a"), "- [ ] a")
        XCTAssertEqual(Todos.mergeTicks(base: "- [ ] a", winner: "- [ ] a", loser: "- [x] a"), "- [x] a")
        // Lines found by their words, also after the newer side reordered and added some.
        XCTAssertEqual(
            Todos.mergeTicks(base: base, winner: "- [ ] new\n- [ ] c\n- [ ] a\n- [ ] b", loser: "- [x] a\n- [ ] b\n- [ ] c"),
            "- [ ] new\n- [ ] c\n- [x] a\n- [ ] b"
        )
    }

    private func todoRecord(_ text: String, _ updatedAt: Int64, state: String = "open") -> SyncRecord {
        ["id": "T", "text": text, "updatedAt": NSNumber(value: updatedAt), "todoStateRaw": state]
    }

    func testTwoDevicesTickDifferentSubtasks() {
        let base = todoRecord("- [ ] a\n- [ ] b\n- [ ] c", 1)
        let baseState = SyncBase(local: SyncMerge.hash(base), remote: SyncMerge.hash(base), text: base["text"] as? String)
        // Here "a" was ticked; on the other device, later, "b".
        let here = todoRecord("- [x] a\n- [ ] b\n- [ ] c", 5)
        let there = todoRecord("- [ ] a\n- [x] b\n- [ ] c", 7)
        let result = SyncMerge.merge(
            local: ["T": SyncMerge.Local(record: here, updatedAt: 5)], remote: ["T": there], tombstones: [:],
            base: ["T": baseState], now: 10)
        XCTAssertEqual(result.merged["T"]?["text"] as? String, "- [x] a\n- [x] b\n- [ ] c")
        XCTAssertEqual(result.toApply["T"]?["text"] as? String, "- [x] a\n- [x] b\n- [ ] c")
        XCTAssertEqual(result.merged["T"]?["todoStateRaw"] as? String, "open")

        // The last open one ticked on the other device: the merged to-do is done.
        let both = SyncMerge.merge(
            local: ["T": SyncMerge.Local(record: todoRecord("- [x] a\n- [x] b\n- [ ] c", 5), updatedAt: 5)],
            remote: ["T": todoRecord("- [ ] a\n- [ ] b\n- [x] c", 7)], tombstones: [:], base: ["T": baseState], now: 10)
        XCTAssertEqual(both.merged["T"]?["text"] as? String, "- [x] a\n- [x] b\n- [x] c")
        XCTAssertEqual(both.merged["T"]?["todoStateRaw"] as? String, "done")
        XCTAssertEqual(both.merged["T"]?["todoDoneAt"] as? NSNumber, 10)
    }

    func testWithoutBaseTextTheNewerSideWinsAsBefore() {
        let base = todoRecord("- [ ] a\n- [ ] b", 1)
        let result = SyncMerge.merge(
            local: ["T": SyncMerge.Local(record: todoRecord("- [x] a\n- [ ] b", 5), updatedAt: 5)],
            remote: ["T": todoRecord("- [ ] a\n- [x] b", 7)], tombstones: [:],
            base: ["T": SyncBase(local: SyncMerge.hash(base), remote: SyncMerge.hash(base))], now: 10)
        XCTAssertEqual(result.merged["T"]?["text"] as? String, "- [ ] a\n- [x] b")
    }

    func testSearchFilterFindsOpenTodosOnly() {
        let open = Note()
        open.todoState = .open
        let done = Note()
        done.todoState = .done
        done.todoDoneAt = Date()
        let plain = Note()
        XCTAssertTrue(SearchKind.todos.matches(open))
        XCTAssertFalse(SearchKind.todos.matches(done))
        XCTAssertFalse(SearchKind.todos.matches(plain))
        XCTAssertFalse(SearchKind.notes.matches(open))
        XCTAssertTrue(SearchKind.notes.matches(plain))
    }
}

extension TodosTests {
    func testChatKnowsATodoAndItsState() {
        let note = Note()
        note.title = "Pack"
        note.text = "- [x] a\n- [ ] b"
        note.todoState = .open
        XCTAssertEqual(ChatRetrieval.todoLine(note), "To-do, open, 1 of 2 subtasks done: Pack")
        XCTAssertTrue(ChatRetrieval.chunks(from: [note]).contains { $0.text.hasPrefix("To-do, open") })
        XCTAssertFalse(ChatRetrieval.chunks(from: [Note()]).contains { $0.text.hasPrefix("To-do") })
    }
}
