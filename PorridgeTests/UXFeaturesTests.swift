import SwiftData
import XCTest
@testable import Porridge

/// The command bar's fuzzy matching, the throttling of the daily hint, the weekly review's numbers, the conflicts of
/// global shortcuts and the undo of deleting, moving and clearing.
@MainActor
final class UXFeaturesTests: XCTestCase {
    // MARK: Fuzzy matching

    func testFuzzyMatchFindsLettersInOrderIgnoringCaseAndAccents() {
        XCTAssertNotNil(FuzzyMatch.score("rcm", in: "Record Meeting"))
        XCTAssertNotNil(FuzzyMatch.score("uber", in: "Über den Wolken"))
        XCTAssertNotNil(FuzzyMatch.score("MEET", in: "Record meeting"))
        XCTAssertNil(FuzzyMatch.score("mcr", in: "Record Meeting"), "the letters must come in order")
        XCTAssertNil(FuzzyMatch.score("xyz", in: "Record Meeting"))
        // Every word of the query has to match.
        XCTAssertNotNil(FuzzyMatch.score("move work", in: "Move to Work"))
        XCTAssertNil(FuzzyMatch.score("move home", in: "Move to Work"))
        // A match that needs a later letter falls back to the plain order.
        XCTAssertNotNil(FuzzyMatch.score("xy", in: "zx y x"))
        XCTAssertEqual(FuzzyMatch.score("", in: "anything"), 0)
    }

    func testFuzzyMatchRanksWordStartsAndWholeWordsFirst() throws {
        let titles = ["Notes from the dentist", "New Note", "Annotate the contract", "Inbox"]
        let ranked = FuzzyMatch.rank(titles, query: "note") { $0 }
        // The whole word first, then the word that starts with it, then the one that holds it.
        XCTAssertEqual(ranked, ["New Note", "Notes from the dentist", "Annotate the contract"])
        // A run of letters beats letters scattered through the text.
        let run = try XCTUnwrap(FuzzyMatch.score("set", in: "Settings"))
        let scattered = try XCTUnwrap(FuzzyMatch.score("set", in: "Save the text"))
        XCTAssertGreaterThan(run, scattered)
        // Initials of words beat letters inside a word.
        let initials = try XCTUnwrap(FuzzyMatch.score("rcm", in: "Record Meeting"))
        let inside = try XCTUnwrap(FuzzyMatch.score("rcm", in: "Recommended"))
        XCTAssertGreaterThan(initials, inside)
    }

    // MARK: Daily hint

    private func hint(_ kind: DailyHint.Kind = .inbox) -> DailyHint {
        DailyHint(kind: kind, message: "12 entries in the Inbox", systemImage: "tray")
    }

    func testAtMostOneHintADayAndTheSameOneMayShowAgain() {
        let inbox = hint(.inbox), overdue = hint(.overdue)
        var (shown, ledger) = HintLedger.choose([inbox, overdue], ledger: HintLedger(), today: "2026-11-22")
        XCTAssertEqual(shown, inbox)
        XCTAssertEqual(ledger.day, "2026-11-22")
        // Later the same day (or on another device with the synced ledger): the same hint, never another one.
        (shown, ledger) = HintLedger.choose([inbox, overdue], ledger: ledger, today: "2026-11-22")
        XCTAssertEqual(shown, inbox)
        (shown, ledger) = HintLedger.choose([overdue], ledger: ledger, today: "2026-11-22")
        XCTAssertNil(shown)
        // Closed: nothing more today, and its kind waits a few days.
        ledger = ledger.closed(inbox, today: "2026-11-22")
        XCTAssertNil(HintLedger.choose([inbox, overdue], ledger: ledger, today: "2026-11-22").hint)
        XCTAssertEqual(HintLedger.choose([inbox, overdue], ledger: ledger, today: "2026-11-23").hint, overdue)
        XCTAssertEqual(HintLedger.choose([inbox], ledger: ledger, today: "2026-11-25").hint, inbox)
    }

    func testIgnoredHintsGoToSleep() {
        var ledger = HintLedger()
        var day = "2026-11-01"
        for _ in 0..<DailyHint.ignoredLimit {
            let result = HintLedger.choose([hint()], ledger: ledger, today: day)
            XCTAssertNotNil(result.hint)
            ledger = result.ledger
            day = HintLedger.day(day, plus: 1)
        }
        // Three days left alone: a week of quiet.
        let asleep = HintLedger.choose([hint()], ledger: ledger, today: day)
        XCTAssertNil(asleep.hint)
        XCTAssertEqual(asleep.ledger.sleepsUntil, HintLedger.day(day, plus: DailyHint.sleepDays))
        XCTAssertNil(HintLedger.choose([hint()], ledger: asleep.ledger, today: HintLedger.day(day, plus: 3)).hint)
        XCTAssertNotNil(HintLedger.choose([hint()], ledger: asleep.ledger, today: HintLedger.day(day, plus: DailyHint.sleepDays)).hint)

        // An opened hint keeps them awake.
        var awake = HintLedger()
        day = "2026-11-01"
        for _ in 0..<5 {
            let result = HintLedger.choose([hint()], ledger: awake, today: day)
            XCTAssertNotNil(result.hint)
            awake = result.ledger.opened(today: day)
            day = HintLedger.day(day, plus: 1)
        }
        XCTAssertEqual(awake.ignoredStreak, 0)
    }

    func testLedgersOfTwoDevicesMerge() {
        var phone = HintLedger(day: "2026-11-22", hintID: "inbox")
        let mac = HintLedger(day: "2026-11-21", hintID: "overdue")
        XCTAssertEqual(HintLedger.newer(phone, mac).day, "2026-11-22")
        XCTAssertEqual(HintLedger.newer(mac, phone).day, "2026-11-22")
        var closedOnMac = phone
        closedOnMac.touched = true
        phone.touched = false
        XCTAssertTrue(HintLedger.newer(phone, closedOnMac).touched)
        XCTAssertEqual(HintLedger.day("2026-12-30", plus: 3), "2027-01-02")
    }

    func testHintCandidatesComeFromTheEntries() throws {
        let context = try TestStore.context()
        let now = DocumentInfo.date(fromDay: "2026-11-22")!.addingTimeInterval(10 * 3600)
        for _ in 0..<DailyHint.inboxThreshold {
            let note = Note()
            context.insert(note)
        }
        let late = Note()
        late.todoState = .open
        late.todoDueDay = "2026-11-20"
        late.projectIDs = ["X"]
        context.insert(late)
        let notes = try context.fetch(FetchDescriptor<Note>())
        let kinds = DailyHint.candidates(notes: notes, now: now).map(\.kind)
        XCTAssertEqual(kinds, [.overdue, .inbox])
        XCTAssertTrue(DailyHint.candidates(notes: Array(notes.filter { !$0.isTodo }.prefix(3)), now: now).isEmpty)
    }

    // MARK: Weekly review

    func testWeeklyReviewCountsWhatCameInThisWeek() throws {
        let context = try TestStore.context()
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        let now = DocumentInfo.date(fromDay: "2026-11-20")!.addingTimeInterval(12 * 3600)  // a Friday
        let week = WeeklyReview.week(containing: now, calendar: calendar)
        let inWeek = week.start.addingTimeInterval(3600 * 30)
        let before = week.start.addingTimeInterval(-3600 * 30)

        let work = NoteFolder(name: "Work"), home = NoteFolder(name: "Home")
        [work, home].forEach(context.insert)

        let meeting = Note()
        meeting.createdAt = inWeek
        meeting.audioFileName = "a.m4a"
        meeting.projectIDs = [Projects.key(work)]
        meeting.filedAt = inWeek
        let note = Note()
        note.createdAt = inWeek
        let link = Note()
        link.createdAt = inWeek
        link.url = "https://example.com"
        link.projectIDs = [Projects.key(work)]
        link.filedAt = inWeek
        let old = Note()
        old.createdAt = before
        old.projectIDs = [Projects.key(home)]
        old.filedAt = before
        let deleted = Note()
        deleted.createdAt = inWeek
        deleted.deletedAt = inWeek
        let dueTodo = Note()
        dueTodo.createdAt = before
        dueTodo.todoState = .open
        dueTodo.todoDueDay = Todos.dueKey(week.start.addingTimeInterval(86_400 * 2), calendar: calendar)
        let laterTodo = Note()
        laterTodo.createdAt = before
        laterTodo.todoState = .open
        laterTodo.todoDueDay = Todos.dueKey(week.end.addingTimeInterval(86_400 * 3), calendar: calendar)
        let done = Note()
        done.createdAt = before
        done.todoState = .done
        done.todoDoneAt = inWeek
        [meeting, note, link, old, deleted, dueTodo, laterTodo, done].forEach(context.insert)

        let notes = try context.fetch(FetchDescriptor<Note>())
        let review = WeeklyReview.make(notes: notes, bowls: [work, home], week: week, now: now, calendar: calendar)
        XCTAssertEqual(review.total, 3)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: review.counts.map { ($0.kind, $0.count) }), [.meetings: 1, .notes: 1, .links: 1])
        XCTAssertEqual(review.meetings.map(\.id), [meeting.id])
        XCTAssertEqual(review.openTodos.map(\.id), [dueTodo.id], "only to-dos due by the end of the week")
        XCTAssertEqual(review.doneTodos, 1)
        XCTAssertEqual(review.bowls.map(\.name), ["Work"])
        XCTAssertEqual(review.bowls.first?.added, 2)
        XCTAssertFalse(review.prompt(notes: notes).isEmpty)

        // Last week holds only the old note.
        let last = WeeklyReview.make(notes: notes, bowls: [work, home], week: WeeklyReview.week(containing: now, offset: -1, calendar: calendar), now: now, calendar: calendar)
        XCTAssertEqual(last.total, 4, "the old note and the three to-dos made before this week")
        XCTAssertEqual(last.bowls.map(\.name), ["Home"])
    }

    // MARK: Shortcut conflicts

    func testShortcutConflicts() {
        let dictation = ShortcutConflicts.Taken(owner: "Dictation", key: ShortcutKey(keyCode: 0x31, modifiers: ShortcutKey.option, label: "Space"))
        let menu = [ShortcutConflicts.Taken(owner: "File › New Note", key: ShortcutKey(keyCode: -1, modifiers: ShortcutKey.command, label: "N"))]

        // Another of Porridge's global shortcuts.
        let same = ShortcutKey(keyCode: 0x31, modifiers: ShortcutKey.option, label: "Space")
        XCTAssertEqual(ShortcutConflicts.conflicts(for: same, others: [dictation]).first?.owner, "Dictation")
        XCTAssertTrue(ShortcutConflicts.message(for: same, others: [dictation])?.contains("Dictation") == true)
        // macOS: Spotlight.
        let spotlight = ShortcutKey(keyCode: 0x31, modifiers: ShortcutKey.command, label: "Space")
        XCTAssertEqual(ShortcutConflicts.conflicts(for: spotlight, others: []).first?.owner, "Spotlight")
        // A menu command, known only by its character.
        let newNote = ShortcutKey(keyCode: 0x2D, modifiers: ShortcutKey.command, label: "N")
        XCTAssertEqual(ShortcutConflicts.conflicts(for: newNote, others: [], menu: menu).first?.owner, "File › New Note")
        // Other modifiers: free.
        let free = ShortcutKey(keyCode: 0x0F, modifiers: ShortcutKey.control | ShortcutKey.option, label: "R")
        XCTAssertNil(ShortcutConflicts.message(for: free, others: [dictation], menu: menu))
        XCTAssertFalse(ShortcutKey(keyCode: 0x2D, modifiers: ShortcutKey.command | ShortcutKey.shift, label: "N").collides(with: menu[0].key))

        // What may be a global shortcut at all.
        XCTAssertFalse(ShortcutConflicts.isAllowed(ShortcutKey(keyCode: 0x00, modifiers: 0, label: "A"), allowsModifierOnly: true))
        XCTAssertFalse(ShortcutConflicts.isAllowed(ShortcutKey(keyCode: 0x00, modifiers: ShortcutKey.shift, label: "A"), allowsModifierOnly: true))
        XCTAssertTrue(ShortcutConflicts.isAllowed(ShortcutKey(keyCode: 0x60, modifiers: 0, label: "F5"), allowsModifierOnly: false))
        let rightOption = ShortcutKey(keyCode: 0x3D, modifiers: 0, label: "Right ⌥")
        XCTAssertTrue(ShortcutConflicts.isAllowed(rightOption, allowsModifierOnly: true))
        XCTAssertFalse(ShortcutConflicts.isAllowed(rightOption, allowsModifierOnly: false))
        XCTAssertEqual(free.display, "⌃⌥ R")
    }

    // MARK: Undo

    func testUndoBringsBackWhatWasDeletedMovedOrCleared() throws {
        let context = try TestStore.context()
        let toast = UndoToast()
        let work = NoteFolder(name: "Work")
        context.insert(work)
        let a = Note(), b = Note()
        a.isPinned = true
        a.labels = ["keep", "drop"]
        [a, b].forEach(context.insert)
        try context.save()

        // Deleted, then back.
        Undoable.run("Deleted", notes: [a], in: context, toast: toast) { NoteStore.trash(a, in: context) }
        XCTAssertTrue(a.isDeleted)
        XCTAssertNotNil(toast.current)
        toast.undo()
        XCTAssertFalse(a.isDeleted)
        XCTAssertTrue(a.isPinned, "the pin comes back too")
        XCTAssertNil(toast.current)

        // Moved into a bowl, then back to the inbox; an edit in between is kept.
        Undoable.run("Moved", notes: [a, b], in: context, toast: toast) {
            Documents.apply(.move(toBowl: Projects.key(work)), to: [a, b], in: context)
        }
        XCTAssertEqual(b.projectIDs, [Projects.key(work)])
        b.labels = ["new"]
        toast.undo()
        XCTAssertTrue(a.isInInbox)
        XCTAssertTrue(b.isInInbox)
        XCTAssertEqual(b.labels, ["new"])

        // A tag taken off comes back.
        Undoable.run("Removed", notes: [a], in: context, toast: toast) { a.labels.removeAll { $0 == "drop" } }
        toast.undo()
        XCTAssertEqual(a.labels, ["keep", "drop"])

        // Nothing changed: no toast.
        Undoable.run("Nothing", notes: [a], in: context, toast: toast) {}
        XCTAssertNil(toast.current)
    }

    func testUndoToastRegistersWithTheUndoManagerOnce() {
        let toast = UndoToast()
        let manager = UndoManager()
        manager.groupsByEvent = false
        toast.undoManagerProvider = { manager }
        var undone = 0
        manager.beginUndoGrouping()
        toast.offer("Moved") { undone += 1 }
        manager.endUndoGrouping()
        XCTAssertTrue(manager.canUndo)
        // From the toast: the manager forgets it, so ⌘Z does not run it a second time.
        toast.undo()
        XCTAssertEqual(undone, 1)
        if manager.canUndo { manager.undo() }
        XCTAssertEqual(undone, 1)

        manager.beginUndoGrouping()
        toast.offer("Deleted") { undone += 1 }
        manager.endUndoGrouping()
        manager.undo()
        XCTAssertEqual(undone, 2)
        XCTAssertNil(toast.current)
        toast.undo()
        XCTAssertEqual(undone, 2, "runs once")
    }
}
