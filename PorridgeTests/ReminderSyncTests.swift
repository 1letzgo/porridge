import XCTest
@testable import Porridge

/// The to-do ↔ reminder mapping, the `@reminder` link on the note, the three-way plan of one to-do, its brakes, and
/// the ledger of lists merged between devices. Pure: no EventKit, no store.
@MainActor
final class ReminderSyncTests: XCTestCase {
    private func fields(_ title: String = "Call Anna", notes: String = "", done: Bool = false, due: String? = nil) -> ReminderFields {
        ReminderFields(title: title, notes: notes, isDone: done, dueDay: due)
    }

    private func base(_ f: ReminderFields, list: String = "inbox") -> ReminderBase {
        ReminderBase(reminderID: "ext-1", localID: "loc-1", fields: f, listKey: list)
    }

    // MARK: Mapping

    func testChecklistBecomesBoxesInTheNotesAndBack() {
        let text = "Before the call\n- [ ] Agenda\n  - [x] Room\n```\n- [ ] code\n```"
        let notes = ReminderMapping.notes(fromText: text)
        XCTAssertEqual(notes, "Before the call\n☐ Agenda\n  ☑ Room\n```\n- [ ] code\n```")
        XCTAssertEqual(ReminderMapping.text(fromNotes: notes), "Before the call\n- [ ] Agenda\n  - [x] Room\n```\n- [ ] code\n```")
        // Ticks made in Reminders read back as ticks.
        XCTAssertEqual(ReminderMapping.text(fromNotes: "✓ Done thing"), "- [x] Done thing")
    }

    func testFieldsOfATodo() {
        let f = ReminderMapping.fields(title: "  Taxes ", text: "- [ ] Receipts\n\n", isDone: false, dueDay: "2026-12-01")
        XCTAssertEqual(f, ReminderFields(title: "Taxes", notes: "☐ Receipts", isDone: false, dueDay: "2026-12-01"))
        // Without a title the first line is the title and is not repeated.
        let untitled = ReminderMapping.fields(title: "", text: "Buy milk\n- [ ] Oat", isDone: true, dueDay: "none")
        XCTAssertEqual(untitled, ReminderFields(title: "Buy milk", notes: "☐ Oat", isDone: true, dueDay: nil))
        // A first line that is a subtask stays in the notes.
        XCTAssertEqual(ReminderMapping.fields(title: "", text: "- [ ] Oat", isDone: false, dueDay: nil).notes, "☐ Oat")
    }

    func testDueDayKeepsATimeOnTheSameDay() {
        let withTime = DateComponents(year: 2026, month: 12, day: 1, hour: 9, minute: 30)
        XCTAssertEqual(ReminderMapping.dueComponents(day: "2026-12-01", keeping: withTime), withTime)
        XCTAssertEqual(ReminderMapping.dueComponents(day: "2026-12-02", keeping: withTime), DateComponents(year: 2026, month: 12, day: 2))
        XCTAssertNil(ReminderMapping.dueComponents(day: nil, keeping: withTime))
        XCTAssertEqual(ReminderMapping.dueDay(from: withTime), "2026-12-01")
        XCTAssertNil(ReminderMapping.dueDay(from: DateComponents(hour: 9)))
    }

    func testURLLeadsBackToTheEntry() {
        let id = UUID()
        XCTAssertEqual(ReminderMapping.url(for: id).absoluteString, "porridge://entry/\(id.uuidString)")
        XCTAssertEqual(ReminderMapping.noteID(from: ReminderMapping.url(for: id)), id)
        XCTAssertNil(ReminderMapping.noteID(from: URL(string: "https://example.com/entry/\(id.uuidString)")))
    }

    func testNamesCompareWithoutCaseAndAccents() {
        XCTAssertEqual(ReminderMapping.normalized("  Café Plans "), ReminderMapping.normalized("cafe plans"))
    }

    // MARK: The link on the note

    func testReminderLinkKeepsTheOtherKeysAndOffersNothing() {
        let note = Note()
        note.todoState = .open
        note.reminderLink = "ext-1"
        XCTAssertEqual(note.reminderLink, "ext-1")
        // A to-do that had no object does not count as offered suggestions.
        note.todoState = TodoState.none
        note.summary = "Something"
        XCTAssertFalse(note.offersTodoSuggestions)
        note.todoState = .open
        note.todoRepeat = .weekly
        XCTAssertEqual(note.reminderLink, "ext-1")
        note.todoRepeat = nil
        XCTAssertEqual(note.reminderLink, "ext-1")
        note.reminderLink = nil
        XCTAssertNil(note.todoSuggestionsRaw)

        // An object with states keeps them, and keeps meaning "offered".
        let meeting = Note()
        meeting.todoSuggestionsRaw = TodoSuggestions.encode(["send offer": TodoSuggestions.taken])
        meeting.reminderLink = "ext-2"
        meeting.reminderLink = nil
        XCTAssertEqual(TodoSuggestions.states(meeting.todoSuggestionsRaw), ["send offer": TodoSuggestions.taken])
    }

    // MARK: One to-do

    func testOpenTodoIsCreatedDoneOneIsNot() {
        let input = ReminderSyncPlan.Input(porridge: .todo(fields(), listKey: "inbox"))
        XCTAssertEqual(ReminderSyncPlan.decide(input), .create(fields(), listKey: "inbox"))
        let done = ReminderSyncPlan.Input(porridge: .todo(fields(done: true), listKey: "inbox"))
        XCTAssertEqual(ReminderSyncPlan.decide(done), .nothing)
        var waiting = input
        waiting.targetReady = false
        XCTAssertEqual(ReminderSyncPlan.decide(waiting), .wait)
        waiting.targetReady = true
        waiting.waitForOtherDevice = true
        XCTAssertEqual(ReminderSyncPlan.decide(waiting), .wait)
    }

    func testPorridgeChangeIsWritten() {
        let old = fields()
        let new = fields("Call Anna today", due: "2026-12-01")
        let input = ReminderSyncPlan.Input(porridge: .todo(new, listKey: "B1"), reminder: ReminderNow(fields: old, listKey: "inbox"), base: base(old))
        guard case .update(let update) = ReminderSyncPlan.decide(input) else { return XCTFail() }
        XCTAssertEqual(update.toReminder, new)
        XCTAssertEqual(update.moveTo, "B1")
        XCTAssertNil(update.toPorridge)
        XCTAssertEqual(update.base, new)
        XCTAssertEqual(update.baseListKey, "B1")
    }

    func testNothingChanged() {
        let f = fields()
        let input = ReminderSyncPlan.Input(porridge: .todo(f, listKey: "inbox"), reminder: ReminderNow(fields: f, listKey: "inbox"), base: base(f))
        XCTAssertEqual(ReminderSyncPlan.decide(input), .nothing)
    }

    func testChangeInRemindersIsTakenOverBothWaysOnly() {
        let f = fields()
        var theirs = f
        theirs.title = "Call Anna back"
        theirs.isDone = true
        var input = ReminderSyncPlan.Input(porridge: .todo(f, listKey: "inbox"), reminder: ReminderNow(fields: theirs, listKey: "B2"), base: base(f))
        guard case .update(let both) = ReminderSyncPlan.decide(input) else { return XCTFail() }
        XCTAssertNil(both.toReminder)
        XCTAssertEqual(both.toPorridge?.title, "Call Anna back")
        XCTAssertEqual(both.toPorridge?.isDone, true)
        XCTAssertEqual(both.toPorridge?.listKey, "B2")
        XCTAssertEqual(both.base, theirs)

        // Stage 2: nothing is taken over, the reminder keeps its change, the base stays (so it is no conflict later).
        input.direction = .toReminders
        XCTAssertEqual(ReminderSyncPlan.decide(input), .nothing)

        // A bowl shared with me to view only: Porridge's fields go back.
        input.direction = .both
        input.porridgeWins = true
        guard case .update(let back) = ReminderSyncPlan.decide(input) else { return XCTFail() }
        XCTAssertEqual(back.toReminder, f)
        XCTAssertEqual(back.moveTo, "inbox")
        XCTAssertNil(back.toPorridge)
    }

    func testBothChangedPorridgeWinsTicksJoin() {
        let b = fields(notes: "☐ Agenda\n☐ Room")
        let mine = fields("Call Anna (prep)", notes: "☐ Agenda\n☐ Room\n☐ Slides")
        let theirs = fields("Call Anna!", notes: "☐ Agenda\n☑ Room")
        let input = ReminderSyncPlan.Input(porridge: .todo(mine, listKey: "inbox"), reminder: ReminderNow(fields: theirs, listKey: "inbox"), base: base(b))
        guard case .update(let update) = ReminderSyncPlan.decide(input) else { return XCTFail() }
        XCTAssertEqual(update.toReminder?.title, "Call Anna (prep)")
        XCTAssertEqual(update.toReminder?.notes, "☐ Agenda\n☑ Room\n☐ Slides")
        XCTAssertEqual(update.toPorridge?.ticks, .init(base: "- [ ] Agenda\n- [ ] Room", theirs: "- [ ] Agenda\n- [x] Room"))
        XCTAssertNil(update.toPorridge?.title)
        XCTAssertEqual(update.base.notes, "☐ Agenda\n☑ Room\n☐ Slides")
    }

    func testRemovalAndDeletion() {
        let f = fields()
        let found = ReminderNow(fields: f, listKey: "inbox")
        XCTAssertEqual(ReminderSyncPlan.decide(.init(porridge: .trashed, reminder: found, base: base(f))), .deleteReminder(missingNote: false))
        XCTAssertEqual(ReminderSyncPlan.decide(.init(porridge: .notTodo, reminder: found, base: base(f))), .deleteReminder(missingNote: false))
        XCTAssertEqual(ReminderSyncPlan.decide(.init(porridge: .missing, reminder: found, base: base(f))), .deleteReminder(missingNote: true))
        XCTAssertEqual(ReminderSyncPlan.decide(.init(porridge: .trashed, reminder: nil, base: base(f))), .forget)
        // The reminder deleted in Reminders: an open one takes its to-do to Recently Deleted, a done one only the link.
        XCTAssertEqual(ReminderSyncPlan.decide(.init(porridge: .todo(f, listKey: "inbox"), reminder: nil, base: base(f))), .trashTodo)
        XCTAssertEqual(ReminderSyncPlan.decide(.init(porridge: .todo(f, listKey: "inbox"), reminder: nil, base: base(fields(done: true)))), .unlink)
        // Viewing only: it is made again.
        var readOnly = ReminderSyncPlan.Input(porridge: .todo(f, listKey: "B1"), reminder: nil, base: base(f))
        readOnly.porridgeWins = true
        XCTAssertEqual(ReminderSyncPlan.decide(readOnly), .create(f, listKey: "B1"))
    }

    func testArchivedBowlIsLeftAlone() {
        var input = ReminderSyncPlan.Input(porridge: .todo(fields("New"), listKey: "B1"), reminder: ReminderNow(fields: fields(), listKey: "B1"), base: base(fields(), list: "B1"))
        input.targetPaused = true
        XCTAssertEqual(ReminderSyncPlan.decide(input), .skip)
        input.reminder = nil
        XCTAssertEqual(ReminderSyncPlan.decide(input), .skip)
    }

    func testFirstLinkPorridgeHolds() {
        let mine = fields("Mine")
        let input = ReminderSyncPlan.Input(porridge: .todo(mine, listKey: "B1"), reminder: ReminderNow(fields: fields("Theirs"), listKey: "B1"))
        guard case .update(let update) = ReminderSyncPlan.decide(input) else { return XCTFail() }
        XCTAssertEqual(update.toReminder, mine)
        XCTAssertNil(update.moveTo)
        XCTAssertEqual(update.baseListKey, "B1")
    }

    func testMoveWaitsForItsList() {
        let f = fields()
        var input = ReminderSyncPlan.Input(porridge: .todo(f, listKey: "B9"), reminder: ReminderNow(fields: f, listKey: "inbox"), base: base(f))
        input.targetReady = false
        XCTAssertEqual(ReminderSyncPlan.decide(input), .nothing)
        input.targetReady = true
        guard case .update(let update) = ReminderSyncPlan.decide(input) else { return XCTFail() }
        XCTAssertEqual(update.moveTo, "B9")
    }

    // MARK: Brakes and duplicates

    func testManyGoneAtOncePause() {
        XCTAssertNil(ReminderSyncPlan.brake(Array(repeating: .trashTodo, count: 4)))
        XCTAssertEqual(ReminderSyncPlan.brake(Array(repeating: .trashTodo, count: 5)), .remindersGone(5))
        XCTAssertEqual(ReminderSyncPlan.brake(Array(repeating: .deleteReminder(missingNote: true), count: 6)), .todosMissing(6))
        // Trashed to-dos are a choice: no brake.
        XCTAssertNil(ReminderSyncPlan.brake(Array(repeating: .deleteReminder(missingNote: false), count: 30)))
        XCTAssertTrue(ReminderPause.listsGone(2).canResume)
        XCTAssertFalse(ReminderPause.storeUnavailable.canResume)
    }

    func testDuplicatesKeepTheNamedOne() {
        let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
        let both = [ReminderSyncPlan.Candidate(id: "a", created: late), .init(id: "b", created: early)]
        XCTAssertEqual(ReminderSyncPlan.duplicates(both, preferred: "a")?.keep, "a")
        XCTAssertEqual(ReminderSyncPlan.duplicates(both, preferred: nil)?.keep, "b")
        XCTAssertEqual(ReminderSyncPlan.duplicates(both, preferred: nil)?.remove, ["a"])
        XCTAssertNil(ReminderSyncPlan.duplicates([both[0]], preferred: nil))
    }

    // MARK: Ledger

    func testLedgerLaterChangeWinsEarlierClaimWinsAtTheSameTime() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let a = ReminderListLedger().claiming("B1", title: "Work", device: "A", now: t0)
        let b = ReminderListLedger().claiming("B1", title: "Work", device: "B", now: t0.addingTimeInterval(30))
        XCTAssertEqual(ReminderListLedger.merged(a, b).lists["B1"]?.claimDevice, "A")
        XCTAssertEqual(ReminderListLedger.merged(b, a), ReminderListLedger.merged(a, b))
        // Same moment: the smaller device id.
        let c = ReminderListLedger().claiming("B1", title: "Work", device: "C", now: t0)
        XCTAssertEqual(ReminderListLedger.merged(c, a).lists["B1"]?.claimDevice, "A")
        // A claim long after an old one is a new start: the later one wins.
        let late = ReminderListLedger().claiming("B1", title: "Work", device: "B", now: t0.addingTimeInterval(3600))
        XCTAssertEqual(ReminderListLedger.merged(a, late).lists["B1"]?.claimDevice, "B")
        // A tombstone after the claim wins.
        let deleted = a.unlinking("B1", reason: .bowlDeleted, now: t0.addingTimeInterval(60))
        XCTAssertEqual(ReminderListLedger.merged(b, deleted).lists["B1"]?.isTombstone, true)
    }

    func testLedgerPrunesOldTombstonesAndRevivesGoneLists() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = ReminderListLedger().linking("B1", title: "Work", now: t0).linking("B2", title: "Home", now: t0)
        ledger = ledger.unlinking("B1", reason: .bowlDeleted, now: t0).unlinking("B2", reason: .listGone, now: t0)
        XCTAssertEqual(ledger.pruned(now: t0.addingTimeInterval(400 * 86400)).lists.count, 0)
        XCTAssertEqual(ledger.pruned(now: t0.addingTimeInterval(10 * 86400)).lists.count, 2)
        let revived = ledger.revivingGoneLists(now: t0.addingTimeInterval(1))
        XCTAssertEqual(revived.lists["B2"]?.state, .linked)
        XCTAssertEqual(revived.lists["B1"]?.isTombstone, true)
        // No entry: nothing to unlink.
        XCTAssertEqual(ReminderListLedger().unlinking("B3", reason: .bowlDeleted), ReminderListLedger())
    }
}
