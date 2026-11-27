import SwiftData
import XCTest
@testable import Porridge

/// The way back (stages 3 and 4): Reminders into Porridge, with the stand-in for Reminders and an in-memory store;
/// two devices simulated where it matters.
@MainActor
final class ReminderWayBackTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var settled: Date { t0.addingTimeInterval(ReminderListPlan.adoptSettle + 1) }

    private func engine(_ db: FakeReminderDB, device: String = "A", lists: ReminderLists) -> ReminderSyncEngine {
        ReminderSyncEngine(store: FakeReminderStore(db, prefix: device), lists: lists, device: device, stateURL: nil)
    }

    private func importedLists(at date: Date? = nil) -> ReminderLists {
        let lists = ReminderLists()
        lists.update(lists.ledger.markingImported(now: date ?? t0.addingTimeInterval(-3600)))
        return lists
    }

    @discardableResult
    private func todo(_ title: String, in bowl: NoteFolder? = nil, done: Bool = false, due: String? = nil, text: String = "", context: ModelContext) -> Note {
        let note = Note()
        note.title = title
        note.text = text
        note.todoState = done ? .done : .open
        note.todoDueDay = due
        if let bowl { note.projectIDs = [Projects.key(bowl)] }
        context.insert(note)
        return note
    }

    private func bowl(_ name: String, context: ModelContext) -> NoteFolder {
        let folder = NoteFolder(name: name)
        context.insert(folder)
        return folder
    }

    /// A reminder the user made in Reminders (no URL).
    @discardableResult
    private func reminder(_ title: String, in listID: String = "L-default", db: FakeReminderDB, notes: String = "", done: Bool = false,
                          due: DateComponents? = nil, url: URL? = nil, created: Date? = nil) -> ReminderItem {
        let id = "U-\(db.reminders.count + 1)-\(title)"
        let item = ReminderItem(localID: id, externalID: "ext-" + id, listID: listID, title: title, notes: notes, isDone: done,
                                due: due, url: url, created: created ?? Date(timeIntervalSince1970: 1_700_000_000))
        db.reminders[id] = item
        return item
    }

    private func list(_ title: String, db: FakeReminderDB) -> String {
        let id = "L-" + title
        db.lists[id] = ReminderListInfo(id: id, title: title, account: "icloud")
        return id
    }

    private func todos(_ context: ModelContext) throws -> [Note] {
        try context.fetch(FetchDescriptor<Note>()).filter { $0.isTodo && !$0.isDeleted }.sorted { $0.title < $1.title }
    }

    // MARK: The first import

    func testNothingComesInBeforeTheImportAndThePreviewSaysWhat() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        todo("Call Anna", in: work, context: context)
        try context.save()
        let db = FakeReminderDB()
        reminder("Buy milk", db: db)
        reminder("Old done one", db: db, done: true)
        let garden = list("Garden", db: db)
        reminder("Cut hedge", in: garden, db: db)
        reminder("Water roses", in: garden, db: db)
        _ = list("Empty", db: db)
        let sync = engine(db, lists: ReminderLists())

        await sync.run(context: context, storeUnavailable: false, now: t0)
        await sync.run(context: context, storeUnavailable: false, now: settled)

        XCTAssertEqual(try todos(context).map(\.title), ["Call Anna"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteFolder>()).count, 1)
        XCTAssertEqual(db.reminders(inList: "Work").map(\.title), ["Call Anna"])
        let preview = try XCTUnwrap(sync.preview)
        XCTAssertEqual(preview.entries.map(\.title), ["Reminders", "Empty", "Garden"])
        let all = Set(preview.entries.map(\.listID))
        XCTAssertEqual(preview.summary(selected: all),
                       "Creates 2 bowls from your lists and adds 3 open reminders as to-dos. 1 of them goes to the Inbox.")
        // Changes in Reminders are not read yet either.
        let call = try XCTUnwrap(db.reminders(inList: "Work").first)
        db.reminders[call.localID]?.title = "Call Anna later"
        await sync.run(context: context, storeUnavailable: false, now: settled.addingTimeInterval(60))
        XCTAssertEqual(try todos(context).map(\.title), ["Call Anna"])
    }

    func testImportBringsOpenRemindersIntoTheInboxAndListsBecomeBowls() async throws {
        let context = try TestStore.context()
        let db = FakeReminderDB()
        reminder("Buy milk", db: db, notes: "☐ Oat\n☑ Soy", due: DateComponents(year: 2026, month: 12, day: 1, hour: 9))
        reminder("Old done one", db: db, done: true)
        reminder("Read this", db: db, url: URL(string: "https://example.com/a"))
        let garden = list("Garden", db: db)
        reminder("Cut hedge", in: garden, db: db)
        _ = list("Empty", db: db)
        let sync = engine(db, lists: importedLists())

        await sync.run(context: context, storeUnavailable: false, now: t0)
        // The Inbox's come in at once; the lists are claimed and become bowls once the claim stood.
        XCTAssertEqual(try todos(context).map(\.title), ["Buy milk", "Read this"])
        XCTAssertTrue(sync.adoptPending)
        await sync.run(context: context, storeUnavailable: false, now: settled)

        let bowls = try context.fetch(FetchDescriptor<NoteFolder>())
        XCTAssertEqual(Set(bowls.map(\.name)), ["Garden", "Empty"])
        let all = try todos(context)
        XCTAssertEqual(all.map(\.title), ["Buy milk", "Cut hedge", "Read this"])
        let milk = all[0]
        XCTAssertEqual(milk.text, "- [ ] Oat\n- [x] Soy")
        XCTAssertEqual(milk.todoDueDay, "2026-12-01")
        XCTAssertTrue(milk.projectIDs.isEmpty)
        XCTAssertEqual(milk.source, .note)
        XCTAssertNotNil(milk.fromReminder)
        XCTAssertFalse(milk.offersTodoSuggestions)
        XCTAssertEqual(all[1].projectIDs, [Projects.key(bowls.first { $0.name == "Garden" }!)])
        // A web address of the reminder is kept in the text.
        XCTAssertTrue(all[2].text.contains("https://example.com/a"))
        // Every reminder taken in points to its to-do now; the time on the due day stays.
        let milkReminder = try XCTUnwrap(db.reminders.values.first { $0.title == "Buy milk" })
        XCTAssertEqual(milkReminder.url, ReminderMapping.url(for: milk.id))
        XCTAssertEqual(milkReminder.due, DateComponents(year: 2026, month: 12, day: 1, hour: 9))
        XCTAssertEqual(milk.reminderLink, milkReminder.externalID)
        // A done reminder never linked stays out.
        XCTAssertNil(all.first { $0.title == "Old done one" })

        // Never twice: the next runs change nothing.
        let before = db.reminders
        await sync.run(context: context, storeUnavailable: false, now: settled.addingTimeInterval(60))
        await sync.run(context: context, storeUnavailable: false, now: settled.addingTimeInterval(120))
        XCTAssertEqual(try todos(context).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteFolder>()).count, 2)
        XCTAssertEqual(db.reminders, before)
    }

    func testListsLeftOutStayOutAndTheDefaultListOnlyBringsNewOnes() async throws {
        let context = try TestStore.context()
        let db = FakeReminderDB()
        reminder("Old errand", db: db, created: t0.addingTimeInterval(-86400))
        let garden = list("Garden", db: db)
        reminder("Cut hedge", in: garden, db: db)
        let lists = importedLists()
        lists.update(lists.ledger
            .excluding(ReminderMapping.inboxKey, title: "Reminders", now: t0.addingTimeInterval(-60))
            .excluding(ReminderListLedger.listKey("Garden"), title: "Garden", now: t0.addingTimeInterval(-60)))
        let sync = engine(db, lists: lists)

        await sync.run(context: context, storeUnavailable: false, now: t0)
        await sync.run(context: context, storeUnavailable: false, now: settled)
        XCTAssertTrue(try todos(context).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<NoteFolder>()).isEmpty)
        XCTAssertEqual(sync.listRows.map(\.isOn), [false, false])

        // Made after the choice: it comes in.
        reminder("New errand", db: db, created: t0)
        await sync.run(context: context, storeUnavailable: false, now: settled.addingTimeInterval(60))
        XCTAssertEqual(try todos(context).map(\.title), ["New errand"])

        // Garden switched on again: it becomes a bowl with its reminder.
        lists.update(lists.ledger.including(ReminderListLedger.listKey("Garden"), title: "Garden", now: settled))
        await sync.run(context: context, storeUnavailable: false, now: settled.addingTimeInterval(120))
        await sync.run(context: context, storeUnavailable: false, now: settled.addingTimeInterval(240))
        XCTAssertEqual(try todos(context).map(\.title), ["Cut hedge", "New errand"])
    }

    // MARK: Changes from Reminders

    func testChangesMadeInRemindersComeIn() async throws {
        let context = try TestStore.context()
        let note = todo("Call Anna", text: "- [ ] Number\n- [ ] Time", context: context)
        let other = todo("Pay rent", due: "2026-12-01", context: context)
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db, lists: importedLists())
        await sync.run(context: context, storeUnavailable: false, now: t0)

        let call = try XCTUnwrap(db.reminders.values.first { $0.title == "Call Anna" })
        db.reminders[call.localID]?.title = "Call Anna back"
        db.reminders[call.localID]?.notes = "☑ Number\n☐ Time"
        let rent = try XCTUnwrap(db.reminders.values.first { $0.title == "Pay rent" })
        db.reminders[rent.localID]?.due = DateComponents(year: 2026, month: 12, day: 3)
        db.reminders[rent.localID]?.isDone = true
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))

        XCTAssertEqual(note.title, "Call Anna back")
        XCTAssertEqual(note.text, "- [x] Number\n- [ ] Time")
        XCTAssertFalse(note.isDone)
        XCTAssertEqual(other.todoDueDay, "2026-12-03")
        XCTAssertTrue(other.isDone)

        // Both changed: Porridge wins, the ticks made in Reminders join.
        note.title = "Call Anna now"
        note.text = "- [x] Number\n- [ ] Time\n- [ ] Notes"
        try context.save()
        db.reminders[call.localID]?.title = "Call Anna tomorrow"
        db.reminders[call.localID]?.notes = "☑ Number\n☑ Time"
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(note.title, "Call Anna now")
        XCTAssertEqual(note.text, "- [x] Number\n- [x] Time\n- [ ] Notes")
        XCTAssertEqual(db.reminders[call.localID]?.title, "Call Anna now")
        XCTAssertEqual(db.reminders[call.localID]?.notes, "☑ Number\n☑ Time\n☐ Notes")

        // Done in Reminders ticks every subtask, and the reminder gets them too.
        db.reminders[call.localID]?.isDone = true
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(180))
        XCTAssertTrue(note.isDone)
        XCTAssertEqual(note.text, "- [x] Number\n- [x] Time\n- [x] Notes")
        XCTAssertEqual(db.reminders[call.localID]?.notes, "☑ Number\n☑ Time\n☑ Notes")
        // Nothing left to do afterwards.
        let before = db.reminders
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(240))
        XCTAssertEqual(db.reminders, before)
    }

    func testRepeatingTodoDoneInRemindersMovesOnAndItsReminderIsOpenAgain() async throws {
        let context = try TestStore.context()
        let note = todo("Water plants", due: "2026-12-01", context: context)
        note.todoRepeat = .weekly
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db, lists: importedLists())
        await sync.run(context: context, storeUnavailable: false, now: t0)
        let id = try XCTUnwrap(db.reminders.keys.first)
        db.reminders[id]?.isDone = true
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))

        XCTAssertFalse(note.isDone)
        XCTAssertEqual(note.todoDueDay, "2026-12-08")
        XCTAssertEqual(db.reminders[id]?.isDone, false)
        XCTAssertEqual(db.reminders[id]?.due, DateComponents(year: 2026, month: 12, day: 8))
    }

    func testMovingAReminderMovesItsTodo() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        let home = bowl("Home", context: context)
        let note = todo("Call Anna", in: work, context: context)
        note.projectIDs = [Projects.key(work), Projects.key(home)]
        let fix = todo("Fix the door", in: home, context: context)
        let other = todo("Pay rent", in: work, context: context)
        try context.save()
        let db = FakeReminderDB()
        db.lists["L-exchange"] = ReminderListInfo(id: "L-exchange", title: "Office", account: "exchange")
        let sync = engine(db, lists: importedLists())
        await sync.run(context: context, storeUnavailable: false, now: t0)
        let homeID = try XCTUnwrap(db.lists.values.first { $0.title == "Home" }?.id)

        let call = try XCTUnwrap(db.reminders.values.first { $0.title == "Call Anna" })
        db.reminders[call.localID]?.listID = homeID
        let door = try XCTUnwrap(db.reminders.values.first { $0.title == "Fix the door" })
        db.reminders[door.localID]?.listID = "L-default"
        let rent = try XCTUnwrap(db.reminders.values.first { $0.title == "Pay rent" })
        db.reminders[rent.localID]?.listID = "L-exchange"
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))

        XCTAssertEqual(note.projectIDs, [Projects.key(home)])
        XCTAssertTrue(fix.projectIDs.isEmpty)
        // Into a list that takes no part: the link goes, the to-do stays, and it is not made again.
        XCTAssertEqual(other.projectIDs, [Projects.key(work)])
        XCTAssertNil(other.reminderLink)
        XCTAssertNil(other.deletedAt)
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(db.reminders.values.filter { $0.title == "Pay rent" }.count, 1)
        XCTAssertEqual(db.reminders[rent.localID]?.listID, "L-exchange")
    }

    func testDeletedRemindersSendOpenTodosToTheTrashAndManyAtOncePause() async throws {
        let context = try TestStore.context()
        let open = todo("Call Anna", context: context)
        let done = todo("Paid rent", context: context)
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db, lists: importedLists())
        await sync.run(context: context, storeUnavailable: false, now: t0)
        done.todoState = .done
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(30))

        for item in db.reminders.values { db.reminders[item.localID] = nil }
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        XCTAssertNotNil(open.deletedAt)
        XCTAssertNil(done.deletedAt)
        XCTAssertNil(done.reminderLink)
        // Still there, in Recently Deleted: put back, it gets a new reminder.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 2)
        open.deletedAt = nil
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(90))
        XCTAssertEqual(db.reminders.values.map(\.title), ["Call Anna"])

        // Five open ones gone at once: nothing goes to the trash, paused.
        for n in 1...5 { todo("Task \(n)", context: context) }
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        for item in db.reminders.values where item.title.hasPrefix("Task") { db.reminders[item.localID] = nil }
        let paused = await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(150))
        XCTAssertEqual(paused.pause, .remindersGone(5))
        XCTAssertTrue(try todos(context).allSatisfy { $0.deletedAt == nil })
        XCTAssertEqual(try todos(context).count, 7)
    }

    func testRenamedListRenamesItsBowlButNotASharedOne() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        let team = bowl("Team", context: context)
        todo("Call Anna", in: work, context: context)
        todo("Plan", in: team, context: context)
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db, lists: importedLists())
        sync.isShared = { $0 == Projects.key(team) }
        await sync.run(context: context, storeUnavailable: false, now: t0)
        for (id, list) in db.lists where list.title == "Work" { db.lists[id]?.title = "Office" }
        for (id, list) in db.lists where list.title == "Team" { db.lists[id]?.title = "Crew" }
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))

        XCTAssertEqual(work.name, "Office")
        XCTAssertEqual(team.name, "Team")
        XCTAssertEqual(Set(db.lists.values.map(\.title)), ["Reminders", "Office", "Team"])
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteFolder>()).count, 2)
    }

    // MARK: Brakes

    func testNothingIsTakenInFromABrokenOrEmptyStore() async throws {
        let context = try TestStore.context()
        for n in 1...6 { todo("Task \(n)", context: context) }
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db, lists: importedLists())
        await sync.run(context: context, storeUnavailable: false, now: t0)
        reminder("Buy milk", db: db)
        _ = list("Garden", db: db)

        let broken = await sync.run(context: context, storeUnavailable: true, now: t0.addingTimeInterval(60))
        XCTAssertEqual(broken.pause, .storeUnavailable)
        XCTAssertTrue(try todos(context).allSatisfy { $0.title.hasPrefix("Task") })
        // The notes gone (not loaded): nothing comes in, nothing is made, nothing deleted.
        for note in try context.fetch(FetchDescriptor<Note>()) { context.delete(note) }
        try context.save()
        let empty = await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(empty.pause, .todosMissing(6))
        await sync.run(context: context, storeUnavailable: false, now: settled.addingTimeInterval(120))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Note>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<NoteFolder>()).isEmpty)
        XCTAssertEqual(db.reminders.count, 7)
    }

    func testRunCutOffAfterTheURLMakesTheTodoNextTime() async throws {
        let context = try TestStore.context()
        let db = FakeReminderDB()
        let item = reminder("Buy milk", db: db)
        let id = UUID()
        db.reminders[item.localID]?.url = ReminderMapping.url(for: id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reminder-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var state = ReminderSyncState()
        state.importing = [id.uuidString: ReminderImporting(localID: item.localID, listKey: ReminderMapping.inboxKey)]
        state.save(to: url)
        let sync = ReminderSyncEngine(store: FakeReminderStore(db), lists: importedLists(), device: "A", stateURL: url)
        await sync.run(context: context, storeUnavailable: false, now: t0)
        let all = try todos(context)
        XCTAssertEqual(all.map(\.id), [id])
        XCTAssertNil(sync.state.importing)
        XCTAssertEqual(db.reminders.count, 1)
    }

    // MARK: Two devices

    func testTwoDevicesMakeOneTodoOfOneReminder() async throws {
        // One store of notes (the iCloud sync is instant here), Reminders per device.
        let context = try TestStore.context()
        let dbA = FakeReminderDB(), dbB = FakeReminderDB()
        reminder("Buy milk", db: dbA)
        dbB.sync(with: dbA)
        let ledger = importedLists().ledger
        let listsA = ReminderLists(), listsB = ReminderLists()
        listsA.update(ledger)
        listsB.update(ledger)
        let a = engine(dbA, device: "A", lists: listsA)
        let b = engine(dbB, device: "B", lists: listsB)

        // A takes it in; B runs before Reminders brought A's URL over: it finds A's to-do and points the reminder there.
        await a.run(context: context, storeUnavailable: false, now: t0)
        await b.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(10))
        XCTAssertEqual(try todos(context).count, 1)
        dbA.sync(with: dbB)
        await a.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        await b.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(70))
        dbA.sync(with: dbB)
        XCTAssertEqual(try todos(context).map(\.title), ["Buy milk"])
        XCTAssertEqual(dbA.reminders.count, 1)
        XCTAssertEqual(dbA.reminders.values.first?.url, ReminderMapping.url(for: try todos(context)[0].id))
    }

    func testTwoTodosOfOneReminderBecomeOneTheOlderStays() async throws {
        // Two devices each made a to-do of the reminder before either saw the other's (separate stores, merged later).
        let context = try TestStore.context()
        let db = FakeReminderDB()
        let item = reminder("Buy milk", db: db)
        let first = ReminderPull.makeTodo(id: UUID(), from: item, bowl: nil, now: t0)
        let second = ReminderPull.makeTodo(id: UUID(), from: item, bowl: nil, now: t0)
        second.createdAt = first.createdAt.addingTimeInterval(1)
        for note in [first, second] {
            note.fromReminder = item.stableID
            note.reminderLink = item.stableID
            context.insert(note)
        }
        try context.save()
        db.reminders[item.localID]?.url = ReminderMapping.url(for: second.id)
        let sync = engine(db, lists: importedLists())
        await sync.run(context: context, storeUnavailable: false, now: t0)

        XCTAssertNil(first.deletedAt)
        XCTAssertNotNil(second.deletedAt)
        XCTAssertNil(second.fromReminder)
        XCTAssertEqual(db.reminders.count, 1)
        XCTAssertEqual(db.reminders[item.localID]?.url, ReminderMapping.url(for: first.id))
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        XCTAssertEqual(db.reminders.count, 1)
        XCTAssertEqual(try todos(context).map(\.id), [first.id])
    }

    func testTwoDevicesMakeOneBowlOfOneList() async throws {
        // Separate stores: the bowl A makes reaches B later than the ledger.
        let contextA = try TestStore.context(), contextB = try TestStore.context()
        let dbA = FakeReminderDB()
        let garden = list("Garden", db: dbA)
        reminder("Cut hedge", in: garden, db: dbA)
        let dbB = FakeReminderDB()
        dbB.sync(with: dbA)
        let ledger = importedLists().ledger
        let listsA = ReminderLists(), listsB = ReminderLists()
        listsA.update(ledger)
        listsB.update(ledger)
        let a = engine(dbA, device: "A", lists: listsA)
        let b = engine(dbB, device: "B", lists: listsB)

        // Both claim before they see each other's claim.
        await a.run(context: contextA, storeUnavailable: false, now: t0)
        await b.run(context: contextB, storeUnavailable: false, now: t0.addingTimeInterval(20))
        listsA.receive(listsB.ledger)
        listsB.receive(listsA.ledger)
        // A's earlier claim wins: A makes the bowl, B does not.
        await a.run(context: contextA, storeUnavailable: false, now: settled)
        await b.run(context: contextB, storeUnavailable: false, now: settled.addingTimeInterval(20))
        XCTAssertEqual(try contextA.fetch(FetchDescriptor<NoteFolder>()).map(\.name), ["Garden"])
        XCTAssertTrue(try contextB.fetch(FetchDescriptor<NoteFolder>()).isEmpty)

        // The ledger with A's bowl arrives, the bowl itself not yet: B still makes none.
        listsB.receive(listsA.ledger)
        dbB.sync(with: dbA)
        await b.run(context: contextB, storeUnavailable: false, now: settled.addingTimeInterval(4000))
        XCTAssertTrue(try contextB.fetch(FetchDescriptor<NoteFolder>()).isEmpty)
        XCTAssertTrue(try contextB.fetch(FetchDescriptor<Note>()).isEmpty)

        // The bowl and its to-do arrive (CloudKit): B takes the list as that bowl's, no second bowl, no second to-do.
        let arrived = NoteFolder(name: "Garden")
        arrived.id = try XCTUnwrap(contextA.fetch(FetchDescriptor<NoteFolder>()).first?.id)
        contextB.insert(arrived)
        let theirs = try XCTUnwrap(try todos(contextA).first)
        let copy = Note()
        copy.id = theirs.id
        copy.title = theirs.title
        copy.todoState = .open
        copy.projectIDs = theirs.projectIDs
        copy.createdAt = theirs.createdAt
        copy.todoSuggestionsRaw = theirs.todoSuggestionsRaw
        contextB.insert(copy)
        try contextB.save()
        await b.run(context: contextB, storeUnavailable: false, now: settled.addingTimeInterval(4060))
        dbA.sync(with: dbB)
        XCTAssertEqual(try contextB.fetch(FetchDescriptor<NoteFolder>()).count, 1)
        XCTAssertEqual(try todos(contextB).count, 1)
        XCTAssertEqual(b.state.lists[Projects.key(arrived)]?.listID, garden)
        XCTAssertEqual(dbA.lists.values.filter { $0.title == "Garden" }.count, 1)
        XCTAssertEqual(dbA.reminders.count, 1)
    }
}
