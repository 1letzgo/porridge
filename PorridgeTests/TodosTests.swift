import SwiftData
import XCTest
@testable import Porridge

/// To-dos: notes with a done state whose subtasks are the checklist lines of their text.
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

    func testDoneTodosStayInTheirBucketOrTheInboxAndOnlyBucketsAreArchived() throws {
        let context = try TestStore.context()
        let bucket = NoteFolder(name: "Garden"), old = NoteFolder(name: "Old")
        [bucket, old].forEach(context.insert)
        Archive.set(true, old, in: context)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())
        let filed = Note(), loose = Note(), open = Note()
        for note in [filed, loose] {
            note.todoState = .done
            note.todoDoneAt = yesterday
        }
        filed.projectIDs = [Projects.key(bucket)]
        open.todoState = .open
        open.projectIDs = [Projects.key(bucket)]
        [filed, loose, open].forEach(context.insert)
        let all = [filed, loose, open]

        // Done yesterday: out of the to-dos folder's "Done Today", but nowhere archived.
        XCTAssertTrue(filed.isPutAway)
        XCTAssertTrue(Todos.folder(all).doneToday.isEmpty)
        // In its bowl, like every note there, in every list of it.
        let content = ProjectContent(of: bucket, notes: all)
        XCTAssertEqual(Set(content.list(.all).map(\.id)), [filed.id, open.id])
        XCTAssertEqual(Set(content.list(.todos).map(\.id)), [filed.id, open.id])
        XCTAssertEqual(ProjectContent.byProject(all)[Projects.key(bucket)]?.count(.todos), 2)
        // Without a bowl it stays in the inbox.
        XCTAssertTrue(loose.isInInbox)
        XCTAssertFalse(filed.isInInbox)
        XCTAssertEqual(Inbox.notes(all).map(\.id), [loose.id])
        // The archive holds bowls only.
        XCTAssertEqual(HomeList.archivedProjects([bucket, old]).map(\.name), ["Old"])
        XCTAssertEqual(HomeList.activeProjects([bucket, old]).map(\.name), ["Garden"])
        // Un-ticking still works as before.
        Todos.setDone(false, filed, in: context)
        XCTAssertEqual(filed.todoState, .open)
    }

    /// The home list shows the pinned bowls and the latest changed others up to the limit from the settings; 0 shows all.
    func testHomeListBowlLimit() throws {
        let bowls = (0..<8).map { NoteFolder(name: "B\($0)") }
        bowls[7].isPinned = true
        let date: (NoteFolder) -> Date = { Date(timeIntervalSince1970: Double(Int($0.name.dropFirst())!)) }
        let three = HomeList.shownProjects(bowls, showAll: false, limit: 3, lastChange: date)
        XCTAssertEqual(three.shown.map(\.name), ["B7", "B6", "B5", "B4"])
        XCTAssertEqual(three.hidden, 4)
        let all = HomeList.shownProjects(bowls, showAll: false, limit: 0, lastChange: date)
        XCTAssertEqual(all.shown.count, 8)
        XCTAssertEqual(all.hidden, 0)
        let expanded = HomeList.shownProjects(bowls, showAll: true, limit: 3, lastChange: date)
        XCTAssertEqual(expanded.shown.count, 8)
        XCTAssertEqual(expanded.hidden, 4)
    }

    /// The bowls by last change, by creation or by name; the pinned ones first in the same order.
    func testHomeListBowlOrder() throws {
        let a = NoteFolder(name: "Alpha"), b = NoteFolder(name: "beta"), c = NoteFolder(name: "Gamma")
        a.createdAt = Date(timeIntervalSince1970: 3)
        b.createdAt = Date(timeIntervalSince1970: 1)
        c.createdAt = Date(timeIntervalSince1970: 2)
        c.isPinned = true
        let changed: [String: Double] = ["Alpha": 1, "beta": 3, "Gamma": 2]
        let date: (NoteFolder) -> Date = { Date(timeIntervalSince1970: changed[$0.name]!) }
        func names(_ order: HomeList.BowlOrder) -> [String] {
            HomeList.shownProjects([a, b, c], showAll: true, limit: 0, order: order, lastChange: date).shown.map(\.name)
        }
        XCTAssertEqual(names(.lastChange), ["Gamma", "beta", "Alpha"])
        XCTAssertEqual(names(.created), ["Gamma", "Alpha", "beta"])
        XCTAssertEqual(names(.name), ["Gamma", "Alpha", "beta"])
        c.isPinned = false
        XCTAssertEqual(names(.name), ["Alpha", "beta", "Gamma"])
    }

    func testNotesArchivedByEarlierVersionsComeBackWithoutAChange() throws {
        let context = try TestStore.context()
        let bucket = NoteFolder(name: "Garden")
        context.insert(bucket)
        let changed = Date(timeIntervalSince1970: 1_700_000_000)
        let filed = Note(), loose = Note()
        filed.projectIDs = [Projects.key(bucket)]
        for note in [filed, loose] {
            note.archivedAt = changed
            note.updatedAt = changed
            context.insert(note)
        }
        try context.save()
        // Even before the cleanup the lists ignore the field.
        XCTAssertTrue(loose.isInInbox)
        XCTAssertEqual(ProjectContent(of: bucket, notes: [filed, loose]).list(.all).map(\.id), [filed.id])

        XCTAssertEqual(Archive.clearArchivedNotes(in: context), 2)
        XCTAssertNil(filed.archivedAt)
        XCTAssertNil(loose.archivedAt)
        XCTAssertEqual(filed.updatedAt, changed, "the cleanup is no edit")
        XCTAssertEqual(loose.updatedAt, changed)
        // Once is enough: a second start finds nothing.
        XCTAssertEqual(Archive.clearArchivedNotes(in: context), 0)
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

// MARK: - Due day

extension TodosTests {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func at(_ text: String, _ calendar: Calendar) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func todo(due: String?, done: Bool = false) -> Note {
        let note = Note()
        note.todoState = done ? .done : .open
        note.todoDueDay = due
        return note
    }

    func testDueKeyIsTheDayOfTheCalendarWithoutTime() {
        let calendar = berlin
        // Late in the evening it is still that day here, while UTC is already on the next.
        XCTAssertEqual(Todos.dueKey(at("2026-11-20 23:30", calendar), calendar: calendar), "2026-11-20")
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        // The same stored day starts at midnight wherever the device is.
        XCTAssertEqual(Todos.dueKey(Todos.dueDate("2026-11-20", calendar: tokyo)!, calendar: tokyo), "2026-11-20")
        XCTAssertTrue(Todos.isDueKey("2026-01-05"))
        XCTAssertFalse(Todos.isDueKey("none"))
        XCTAssertFalse(Todos.isDueKey(nil))
        XCTAssertNil(Todos.dueDate("none"))
    }

    func testDueLabelsRelativeToToday() {
        let calendar = berlin
        let now = at("2026-11-20 10:00", calendar)  // a Friday
        let gb = Locale(identifier: "en_GB")
        func label(_ key: String) -> String { Todos.dueLabel(key, now: now, calendar: calendar, locale: gb) }
        XCTAssertEqual(label("2026-11-20"), "Today")
        XCTAssertEqual(label("2026-11-21"), "Tomorrow")
        XCTAssertEqual(label("2026-11-19"), "Yesterday")
        XCTAssertEqual(label("2026-11-24"), "Tue")
        XCTAssertEqual(label("2026-11-26"), "Thu")
        XCTAssertEqual(label("2026-11-27"), "27 Nov")
        XCTAssertEqual(label("2026-12-12"), "12 Dec")
        XCTAssertEqual(label("2026-11-10"), "10 Nov")
        XCTAssertEqual(label("2027-01-05"), "5 Jan 2027")
    }

    func testOverdueStartsAtMidnightAfterTheDueDay() {
        let calendar = berlin
        XCTAssertEqual(Todos.dueStatus("2026-11-20", now: at("2026-11-20 23:59", calendar), calendar: calendar), .today)
        XCTAssertEqual(Todos.dueStatus("2026-11-20", now: at("2026-11-21 00:00", calendar), calendar: calendar), .overdue)
        XCTAssertEqual(Todos.dueStatus("2026-11-21", now: at("2026-11-20 12:00", calendar), calendar: calendar), .later)
        XCTAssertNil(Todos.dueStatus("none"))
    }

    func testQuickChoices() {
        let calendar = berlin
        let now = at("2026-11-20 22:00", calendar)
        XCTAssertEqual(Todos.dueKey(for: .today, now: now, calendar: calendar), "2026-11-20")
        XCTAssertEqual(Todos.dueKey(for: .tomorrow, now: now, calendar: calendar), "2026-11-21")
        // The week starts on Monday here.
        XCTAssertEqual(Todos.dueKey(for: .nextWeek, now: now, calendar: calendar), "2026-11-23")
    }

    func testOpenTodosSortByDueUndatedLastDoneAfter() {
        let late = todo(due: "2026-11-01"), soon = todo(due: "2026-11-25"), none = todo(due: nil)
        let cleared = todo(due: "none"), done = todo(due: "2026-10-01", done: true)
        let sorted = Todos.byDue([none, done, soon, cleared, late])
        XCTAssertEqual(sorted.map(\.id), [late, soon, none, cleared, done].map(\.id))
    }

    func testOpenTodosGroupByDue() {
        let calendar = berlin
        let now = at("2026-11-20 10:00", calendar)
        let overdue = todo(due: "2026-11-19"), today = todo(due: "2026-11-20"), later = todo(due: "2027-01-01"), none = todo(due: nil)
        let groups = Todos.dueGroups([none, later, today, overdue], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Overdue", "Today", "Upcoming", "No Due Date"])
        XCTAssertEqual(groups.map { $0.notes.map(\.id) }, [[overdue.id], [today.id], [later.id], [none.id]])
        XCTAssertEqual(Todos.dueGroups([none], now: now, calendar: calendar).map(\.title), ["No Due Date"])
    }

    func testSettingAndClearingTheDueDay() throws {
        let context = try TestStore.context()
        let note = todo(due: nil)
        context.insert(note)
        // Clearing what was never set writes nothing.
        Todos.setDue(nil, note, in: context)
        XCTAssertNil(note.todoDueDay)
        Todos.setDue("2026-12-12", note, in: context)
        XCTAssertEqual(note.todoDue, "2026-12-12")
        Todos.setDue(nil, note, in: context)
        XCTAssertEqual(note.todoDueDay, "none")
        XCTAssertNil(note.todoDue)

        // Turned back into a note it keeps the day without showing it.
        Todos.setDue("2026-12-12", note, in: context)
        Todos.setTodo(false, note, in: context)
        XCTAssertEqual(note.todoDueDay, "2026-12-12")
        XCTAssertNil(note.todoDue)
        XCTAssertFalse(note.isOverdue)
    }

    func testOnlyOpenTodosAreOverdue() {
        XCTAssertTrue(todo(due: "2000-01-01").isOverdue)
        XCTAssertFalse(todo(due: "2000-01-01", done: true).isOverdue)
        XCTAssertFalse(todo(due: "2999-01-01").isOverdue)
    }

    func testChatLineAndExportNameTheDueDay() {
        let calendar = berlin
        let note = todo(due: "2026-12-12")
        note.title = "Send the offer"
        XCTAssertEqual(ChatRetrieval.todoLine(note, now: at("2026-11-20 10:00", calendar), calendar: calendar),
                       "To-do, open, due 12 December 2026: Send the offer")
        XCTAssertEqual(ChatRetrieval.todoLine(note, now: at("2026-12-13 10:00", calendar), calendar: calendar),
                       "To-do, open, due 12 December 2026, overdue: Send the offer")
        XCTAssertTrue(note.exportText.contains("[ ] To-do, due 12 December 2026"))
        // The passage is dated by the due day, so "what is due this week" finds it.
        let chunk = ChatRetrieval.chunks(from: [note]).first { $0.text.hasPrefix("To-do") }
        XCTAssertEqual(chunk.map { Todos.dueKey($0.date) }, "2026-12-12")
    }
}

// MARK: - The to-dos folder

extension TodosTests {
    func testFolderHoldsEveryOpenTodoByDueDayThenThoseDoneToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
        func todo(_ title: String, due: String? = nil, done: Date? = nil) -> Note {
            let note = Note()
            note.title = title
            note.todoState = done == nil ? .open : .done
            note.todoDoneAt = done
            note.todoDueDay = due
            return note
        }
        let late = todo("late", due: "2026-11-19")
        let today = todo("today", due: "2026-11-20")
        let later = todo("later", due: "2026-12-01")
        let undated = todo("undated")
        let filed = todo("filed in a bowl", due: "2026-11-02")
        filed.projectIDs = ["B1"]
        let doneToday = todo("done today", done: calendar.date(byAdding: .hour, value: -1, to: now))
        let doneEarlier = todo("done yesterday", done: calendar.date(byAdding: .day, value: -1, to: now))
        let deleted = todo("deleted", due: "2026-11-01")
        deleted.deletedAt = now
        let plain = Note()
        plain.title = "a note"

        let folder = Todos.folder([undated, later, plain, doneEarlier, today, deleted, late, doneToday, filed], now: now, calendar: calendar)
        XCTAssertEqual(folder.groups.map(\.title), ["Overdue", "Today", "Upcoming", "No Due Date"])
        XCTAssertEqual(folder.groups.map { $0.notes.map(\.title) }, [["filed in a bowl", "late"], ["today"], ["later"], ["undated"]])
        XCTAssertEqual(folder.doneToday.map(\.title), ["done today"])
        XCTAssertEqual(folder.open, 5)
        XCTAssertEqual(folder.overdue, 2)
        XCTAssertFalse(folder.isEmpty)

        // At midnight what was due today is late; yesterday's done one was gone already.
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21))!
        let next = Todos.folder([late, today, later, doneToday], now: midnight, calendar: calendar)
        XCTAssertEqual(next.overdue, 2)
        XCTAssertTrue(next.doneToday.isEmpty)
        XCTAssertEqual(next.groups.map(\.title), ["Overdue", "Upcoming"])

        XCTAssertTrue(Todos.folder([plain, doneEarlier], now: now, calendar: calendar).isEmpty)

        // `archivedAt` of earlier versions does not count: notes are never archived.
        let formerlyArchived = todo("formerly archived")
        formerlyArchived.archivedAt = now
        XCTAssertEqual(Todos.folder([formerlyArchived], now: now, calendar: calendar).open, 1)
    }
}

