import SwiftData
import XCTest
@testable import Porridge

/// The widgets' copy of the notes, the ticks queued in a widget, the `porridge://` links and the shortcuts' logic.
@MainActor
final class WidgetDataTests: XCTestCase {
    private var root: URL!
    private let calendar = Calendar(identifier: .gregorian)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WidgetDataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        WidgetStore.rootOverride = root
        ShareInbox.rootOverride = root
    }

    override func tearDown() async throws {
        WidgetStore.rootOverride = nil
        ShareInbox.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ key: String) -> Date {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 10))!
    }

    @discardableResult
    private func todo(_ title: String, due: String? = nil, done: Bool = false, in context: ModelContext) -> Note {
        let note = Note()
        note.title = title
        note.todoState = done ? .done : .open
        note.todoDueDay = due
        context.insert(note)
        return note
    }

    // MARK: Links

    func testLinksRoundTrip() {
        let id = UUID()
        let actions: [QuickAction] = [.newNote, .startMeeting, .openInbox, .openTodos, .search("Q3 plan & budget"), .openNote(id)]
        for action in actions {
            XCTAssertEqual(QuickAction(url: action.url), action, action.url.absoluteString)
        }
        // Entries are linked like the links between entries; the older `note/` form still opens them.
        XCTAssertEqual(QuickAction.openNote(id).url, PorridgeURL.entry(id))
        XCTAssertEqual(QuickAction.openNote(id).url.absoluteString, "porridge://entry/\(id.uuidString)")
        XCTAssertEqual(QuickAction(url: URL(string: "porridge://note/\(id.uuidString)")!), .openNote(id))
        XCTAssertNil(QuickAction(url: URL(string: "porridge://entry/\(id.uuidString)/more")!))
        XCTAssertNil(QuickAction(url: URL(string: "porridge://elsewhere")!))
        XCTAssertNil(QuickAction(url: URL(string: "https://inbox")!))
        XCTAssertNil(QuickAction(url: URL(string: "porridge://note/not-an-id")!))
    }

    // MARK: Building the snapshot

    func testSnapshotHasTheInboxAndTheOpenTodosByDueDay() throws {
        let context = try TestStore.context()
        let filed = Note()
        filed.title = "Filed"
        filed.projectIDs = [UUID().uuidString]
        context.insert(filed)
        let deleted = Note()
        deleted.title = "Deleted"
        deleted.deletedAt = Date()
        context.insert(deleted)
        let older = Note()
        older.title = "Older"
        older.createdAt = Date(timeIntervalSinceNow: -100)
        context.insert(older)
        todo("Later", due: "2026-11-30", in: context)
        todo("Undated", in: context)
        todo("Overdue", due: "2026-11-20", in: context)
        todo("Done", due: "2026-11-20", done: true, in: context)
        let repeating = todo("Plants", due: "2026-11-22", in: context)
        repeating.todoRepeat = .weekly
        let gone = todo("Gone", due: "2026-11-22", in: context)
        gone.deletedAt = Date()
        try context.save()

        let notes = try context.fetch(FetchDescriptor<Note>())
        let snapshot = WidgetSync.snapshot(notes, isReadOnly: { $0.title == "Later" }, now: date("2026-11-22"))

        XCTAssertEqual(snapshot.openTodoCount, 4)
        XCTAssertEqual(snapshot.todos.map(\.title), ["Overdue", "Plants", "Later", "Undated"])
        XCTAssertEqual(snapshot.todos.first { $0.title == "Plants" }?.isRepeating, true)
        XCTAssertEqual(snapshot.todos.first { $0.title == "Later" }?.isReadOnly, true)
        XCTAssertEqual(snapshot.todos.first { $0.title == "Overdue" }?.isReadOnly, false)
        // The inbox: everything in no bowl and not deleted, newest first; to-dos are entries too.
        XCTAssertEqual(snapshot.inboxCount, 6)
        XCTAssertFalse(snapshot.inbox.contains { $0.title == "Filed" || $0.title == "Deleted" })
        XCTAssertEqual(snapshot.inbox.last?.title, "Older")
        XCTAssertEqual(snapshot.inbox.first { $0.title == "Overdue" }?.symbol, "checklist")
    }

    func testEntriesPutAwayForLaterAreNotCountedUntilTheyComeBack() throws {
        let context = try TestStore.context()
        let now = date("2026-11-22")
        let waiting = Note()
        waiting.title = "Waiting"
        waiting.createdAt = now.addingTimeInterval(-300)
        context.insert(waiting)
        let snoozed = Note()
        snoozed.title = "Snoozed"
        snoozed.createdAt = now.addingTimeInterval(-60)
        snoozed.snoozedUntil = now.addingTimeInterval(3600)
        context.insert(snoozed)
        let back = Note()
        back.title = "Back"
        back.createdAt = now.addingTimeInterval(-600)
        back.snoozedUntil = now.addingTimeInterval(-60)
        context.insert(back)
        try context.save()

        let snapshot = WidgetSync.snapshot(try context.fetch(FetchDescriptor<Note>()), isReadOnly: { _ in false }, now: now)
        XCTAssertEqual(snapshot.inboxCount, 2)
        XCTAssertEqual(snapshot.inbox.map(\.title), ["Waiting", "Back"])
        XCTAssertEqual(snapshot.later.map(\.entry.title), ["Snoozed"])
        XCTAssertEqual(snapshot.laterReturns(after: now), [now.addingTimeInterval(3600)])
        // Before its time nothing changes; from then on it is counted, in its place by creation.
        XCTAssertEqual(snapshot.at(now.addingTimeInterval(3599)), snapshot)
        let later = snapshot.at(now.addingTimeInterval(3600))
        XCTAssertEqual(later.inboxCount, 3)
        XCTAssertEqual(later.inbox.map(\.title), ["Snoozed", "Waiting", "Back"])
        XCTAssertTrue(later.later.isEmpty)
        XCTAssertTrue(later.laterReturns(after: now).isEmpty)
    }

    func testDueTodayPutsOverdueFirstAndLeavesOutLaterAndUndated() {
        let snapshot = WidgetSnapshot(openTodoCount: 5, todos: [
            .init(id: "A", title: "Today 1", due: "2026-11-22"),
            .init(id: "B", title: "Late", due: "2026-11-21"),
            .init(id: "C", title: "Later", due: "2026-11-23"),
            .init(id: "D", title: "Undated"),
            .init(id: "E", title: "Very late", due: "2026-10-01"),
        ])
        let now = date("2026-11-22")
        XCTAssertEqual(snapshot.dueToday(now: now, calendar: calendar).map(\.id), ["E", "B", "A"])
        XCTAssertEqual(snapshot.overdueCount(now: now, calendar: calendar), 2)
        XCTAssertTrue(WidgetSnapshot.isOverdue(snapshot.todos[1], now: now, calendar: calendar))
        XCTAssertFalse(WidgetSnapshot.isOverdue(snapshot.todos[0], now: now, calendar: calendar))
        // The next day, today's become overdue.
        XCTAssertEqual(snapshot.overdueCount(now: date("2026-11-23"), calendar: calendar), 3)
        XCTAssertEqual(WidgetSnapshot.dueLabel("2026-11-21", now: now, calendar: calendar), "Yesterday")
    }

    func testTicksWaitingForTheAppLeaveTheListAndTheCount() {
        let snapshot = WidgetSnapshot(openTodoCount: 10, todos: [
            .init(id: "A", title: "Once", due: "2026-11-22"),
            .init(id: "B", title: "Weekly", due: "2026-11-22", isRepeating: true),
            .init(id: "C", title: "Other", due: "2026-11-22"),
        ])
        let after = snapshot.applying([.init(id: "A", due: "2026-11-22"), .init(id: "B", due: "2026-11-22")])
        XCTAssertEqual(after.todos.map(\.id), ["C"])
        // A repeating one stays open (it only moves on): only the other leaves the count.
        XCTAssertEqual(after.openTodoCount, 9)
        XCTAssertEqual(GetOpenTodosIntent.titles(snapshot, pending: [.init(id: "C")]), ["Once", "Weekly"])
        XCTAssertEqual(GetOpenTodosIntent.titles(nil, pending: []), [])
    }

    // MARK: The files in the app group

    func testSnapshotIsOnlyWrittenWhenItChanged() {
        XCTAssertNil(WidgetStore.snapshot())
        var snapshot = WidgetSnapshot(inboxCount: 2)
        XCTAssertTrue(WidgetStore.write(snapshot))
        XCTAssertEqual(WidgetStore.snapshot()?.inboxCount, 2)
        // Only a newer time: nothing to reload.
        snapshot.generatedAt = Date(timeIntervalSinceNow: 60)
        XCTAssertFalse(WidgetStore.write(snapshot))
        snapshot.inboxCount = 3
        XCTAssertTrue(WidgetStore.write(snapshot))
    }

    func testQueuedTicksReplaceEachOtherAndCanBeTakenOut() {
        WidgetStore.queueCompletion(.init(id: "A", due: "2026-11-21"))
        WidgetStore.queueCompletion(.init(id: "B"))
        WidgetStore.queueCompletion(.init(id: "A", due: "2026-11-22"))
        XCTAssertEqual(WidgetStore.pendingCompletions().map(\.id), ["B", "A"])
        XCTAssertEqual(WidgetStore.pendingCompletions().last?.due, "2026-11-22")
        let handled = WidgetStore.pendingCompletions()
        // Ticked again while the app was applying the others: that tick stays.
        WidgetStore.queueCompletion(.init(id: "B", date: Date(timeIntervalSinceNow: 5)))
        WidgetStore.removeCompletions(handled)
        XCTAssertEqual(WidgetStore.pendingCompletions().map(\.id), ["B"])
        WidgetStore.removeCompletions(WidgetStore.pendingCompletions())
        XCTAssertTrue(WidgetStore.pendingCompletions().isEmpty)
    }

    // MARK: Applying a tick

    func testATickIsDoneLikeInTheApp() throws {
        let context = try TestStore.context()
        let note = todo("Invoice", due: "2026-11-20", in: context)
        note.text = "- [ ] Print\n- [ ] Send"
        try context.save()

        XCTAssertTrue(WidgetSync.apply(.init(id: note.id.uuidString, due: "2026-11-20"), in: context))
        XCTAssertTrue(note.isDone)
        XCTAssertNotNil(note.todoDoneAt)
        XCTAssertEqual(Todos.progress(note.text).done, 2, "done ticks every subtask")
        // Done already: nothing more happens.
        XCTAssertFalse(WidgetSync.apply(.init(id: note.id.uuidString, due: "2026-11-20"), in: context))
    }

    func testARepeatingTodoMovesOnOnceAndNotForAStaleTick() throws {
        let context = try TestStore.context()
        let today = Todos.dueKey(Date())
        let note = todo("Plants", due: today, in: context)
        note.todoRepeat = .daily
        try context.save()

        XCTAssertTrue(WidgetSync.apply(.init(id: note.id.uuidString, due: today), in: context))
        XCTAssertFalse(note.isDone, "a repeating to-do stays open")
        XCTAssertNotNil(note.todoDue)
        XCTAssertGreaterThan(note.todoDue!, today)
        let next = note.todoDue
        // The same tick again (it showed the old due day): no second occurrence skipped.
        XCTAssertFalse(WidgetSync.apply(.init(id: note.id.uuidString, due: today), in: context))
        XCTAssertEqual(note.todoDue, next)
    }

    func testViewOnlyDeletedAndUnknownEntriesStayAsTheyAre() throws {
        let context = try TestStore.context()
        let shared = todo("Shared", in: context)
        let deleted = todo("Deleted", in: context)
        deleted.deletedAt = Date()
        let plain = Note()
        context.insert(plain)
        try context.save()

        XCTAssertFalse(WidgetSync.apply(.init(id: shared.id.uuidString), in: context, isReadOnly: { _ in true }))
        XCTAssertFalse(shared.isDone)
        XCTAssertFalse(WidgetSync.apply(.init(id: deleted.id.uuidString), in: context))
        XCTAssertFalse(deleted.isDone)
        XCTAssertFalse(WidgetSync.apply(.init(id: plain.id.uuidString), in: context))
        XCTAssertNil(plain.todoState)
        XCTAssertFalse(WidgetSync.apply(.init(id: UUID().uuidString), in: context))
        XCTAssertFalse(WidgetSync.apply(.init(id: "nonsense"), in: context))
    }

    func testATickFromBeforeTheToDoChangedIsNotApplied() throws {
        let context = try TestStore.context()
        let note = todo("Reopened", in: context)
        let tick = WidgetStore.Completion(id: note.id.uuidString, date: Date(timeIntervalSinceNow: -60))
        note.updatedAt = Date()
        try context.save()
        XCTAssertFalse(WidgetSync.apply(tick, in: context))
        XCTAssertFalse(note.isDone)
        XCTAssertTrue(WidgetSync.apply(.init(id: note.id.uuidString), in: context))
    }

    func testPendingTicksAreAppliedAndTheQueueEmptied() throws {
        let context = try TestStore.context()
        let a = todo("A", in: context)
        let b = todo("B", in: context)
        try context.save()
        WidgetStore.queueCompletion(.init(id: a.id.uuidString))
        WidgetStore.queueCompletion(.init(id: b.id.uuidString))
        WidgetStore.queueCompletion(.init(id: UUID().uuidString))

        XCTAssertEqual(WidgetSync.applyPending(in: context, isReadOnly: { $0.title == "B" }), 1)
        XCTAssertTrue(a.isDone)
        XCTAssertFalse(b.isDone)
        XCTAssertTrue(WidgetStore.pendingCompletions().isEmpty, "what cannot be applied is dropped, not kept")
    }

    // MARK: Add to Inbox

    func testAddToInboxBecomesANoteOfTheUsersOwn() throws {
        try WidgetSync.addToInbox("  Buy a new kettle \n")
        try WidgetSync.addToInbox("   ")
        let pending = ShareInbox.pending()
        XCTAssertEqual(pending.map(\.text), ["Buy a new kettle"])
        XCTAssertEqual(pending.first?.source, ShareInbox.Entry.ownWords)

        let context = try TestStore.context()
        ShareImport.importInbox(context: context, processing: ProcessingService(container: context.container))
        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.map(\.text), ["Buy a new kettle"])
        XCTAssertEqual(notes.first?.source, .note)
        XCTAssertTrue(notes.first?.isInInbox ?? false)
        XCTAssertTrue(notes.first?.canBeTodo ?? false, "own words can become a to-do, unlike shared text")
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }
}
