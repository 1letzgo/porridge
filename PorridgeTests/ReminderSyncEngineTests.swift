import SwiftData
import XCTest
@testable import Porridge

/// Reminders of one device in memory: its lists and reminders. Two of them can be synced with each other, as iCloud
/// syncs Reminders between devices (deletions included).
@MainActor
final class FakeReminderDB {
    var lists: [String: ReminderListInfo] = [:]
    var reminders: [String: ReminderItem] = [:]
    var defaultListID: String?
    var deletedLists: Set<String> = []
    var deletedReminders: Set<String> = []

    init(defaultList: String? = "L-default", title: String = "Reminders") {
        if let defaultList {
            lists[defaultList] = ReminderListInfo(id: defaultList, title: title, account: "icloud")
            defaultListID = defaultList
        }
    }

    func sync(with other: FakeReminderDB) {
        let goneLists = deletedLists.union(other.deletedLists)
        let goneReminders = deletedReminders.union(other.deletedReminders)
        for db in [self, other] {
            db.deletedLists = goneLists
            db.deletedReminders = goneReminders
        }
        var allLists = lists.merging(other.lists) { a, _ in a }
        var allReminders = reminders.merging(other.reminders) { a, _ in a }
        goneLists.forEach { allLists[$0] = nil }
        goneReminders.forEach { allReminders[$0] = nil }
        allReminders = allReminders.filter { goneLists.contains($0.value.listID) == false }
        lists = allLists
        reminders = allReminders
        other.lists = allLists
        other.reminders = allReminders
    }

    func reminders(inList title: String) -> [ReminderItem] {
        guard let id = lists.values.first(where: { $0.title == title })?.id else { return [] }
        return reminders.values.filter { $0.listID == id }.sorted { $0.title < $1.title }
    }
}

/// `ReminderStore` over a `FakeReminderDB`: what the tests use instead of the real Reminders.
@MainActor
final class FakeReminderStore: ReminderStore {
    let db: FakeReminderDB
    let prefix: String
    var access: ReminderAccess = .granted
    private var counter = 0

    init(_ db: FakeReminderDB, prefix: String = "A") {
        self.db = db
        self.prefix = prefix
    }

    private func nextID(_ kind: String) -> String {
        counter += 1
        return "\(prefix)-\(kind)\(counter)"
    }

    func requestAccess() async -> Bool { access == .granted }
    func lists() -> [ReminderListInfo] { db.lists.values.sorted { $0.id < $1.id } }
    func defaultListID() -> String? { db.defaultListID }

    func createList(title: String) throws -> ReminderListInfo {
        let list = ReminderListInfo(id: nextID("L"), title: title, account: "icloud")
        db.lists[list.id] = list
        return list
    }

    func renameList(_ id: String, to title: String) throws {
        guard db.lists[id] != nil else { throw ReminderStoreError.noList }
        db.lists[id]?.title = title
    }

    func deleteList(_ id: String) throws {
        db.lists[id] = nil
        db.deletedLists.insert(id)
        for (key, item) in db.reminders where item.listID == id { db.reminders[key] = nil }
    }

    func reminders(in listIDs: [String]) async -> [ReminderItem] {
        db.reminders.values.filter { listIDs.contains($0.listID) }.sorted { $0.localID < $1.localID }
    }

    func reminder(externalID: String) -> ReminderItem? {
        db.reminders.values.first { $0.externalID == externalID }
    }

    func save(_ write: ReminderWrite) throws -> ReminderItem {
        guard db.lists[write.listID] != nil else { throw ReminderStoreError.noList }
        var item: ReminderItem
        if let id = write.localID {
            guard let existing = db.reminders[id] else { throw ReminderStoreError.notFound }
            item = existing
        } else {
            let id = nextID("R")
            item = ReminderItem(localID: id, externalID: "ext-" + id, listID: write.listID, title: "", notes: "", isDone: false, created: Date())
        }
        item.listID = write.listID
        item.title = write.title
        item.notes = write.notes
        item.isDone = write.isDone
        item.due = write.due
        item.url = write.url
        db.reminders[item.localID] = item
        return item
    }

    func deleteReminder(localID: String) throws {
        db.reminders[localID] = nil
        db.deletedReminders.insert(localID)
    }
}

/// Whole runs of the sync (stage 2: Porridge into Reminders) against the stand-in, with an in-memory store.
@MainActor
final class ReminderSyncEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func engine(_ db: FakeReminderDB, device: String = "A", lists: ReminderLists? = nil) -> ReminderSyncEngine {
        ReminderSyncEngine(store: FakeReminderStore(db, prefix: device), lists: lists ?? ReminderLists(), device: device, stateURL: nil)
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

    func testFirstRunBringsTheOpenTodosIntoTheirLists() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        let errand = todo("Buy milk", due: "2026-12-01", context: context)
        let report = todo("Write report", in: work, text: "- [ ] Intro\n- [x] Data", context: context)
        todo("Old thing", in: work, done: true, context: context)
        _ = bowl("Empty", context: context)
        try context.save()

        let db = FakeReminderDB()
        let sync = engine(db)
        let state = await sync.run(context: context, storeUnavailable: false, now: t0)

        XCTAssertNil(state.pause)
        XCTAssertEqual(db.reminders(inList: "Reminders").map(\.title), ["Buy milk"])
        XCTAssertEqual(db.reminders(inList: "Reminders").first?.due, DateComponents(year: 2026, month: 12, day: 1))
        let inWork = db.reminders(inList: "Work")
        XCTAssertEqual(inWork.map(\.title), ["Write report"])
        XCTAssertEqual(inWork.first?.notes, "☐ Intro\n☑ Data")
        XCTAssertEqual(inWork.first?.url, ReminderMapping.url(for: report.id))
        // No list for a bowl without open to-dos, done to-dos stay out.
        XCTAssertEqual(Set(db.lists.values.map(\.title)), ["Reminders", "Work"])
        XCTAssertEqual(state.items.count, 2)
        XCTAssertEqual(errand.reminderLink, db.reminders(inList: "Reminders").first?.externalID)
        XCTAssertEqual(sync.lists.ledger.lists[Projects.key(work)]?.createdByPorridge, true)

        // A second run changes nothing.
        let before = db.reminders
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        XCTAssertEqual(db.reminders, before)
        XCTAssertEqual(db.lists.count, 2)
    }

    func testChangesInPorridgeFollowIntoReminders() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        let home = bowl("Home", context: context)
        let note = todo("Call Anna", in: work, context: context)
        let other = todo("Fix the door", in: home, context: context)
        let gone = todo("Old idea", context: context)
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db)
        await sync.run(context: context, storeUnavailable: false, now: t0)

        note.title = "Call Anna back"
        note.todoState = .done
        Inbox.file(note, into: Projects.key(home), in: context)
        Projects.rename(work, to: "Office", in: context)
        other.deletedAt = Date()
        gone.todoState = TodoState.none
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))

        XCTAssertEqual(db.reminders(inList: "Home").map(\.title), ["Call Anna back"])
        XCTAssertEqual(db.reminders(inList: "Home").first?.isDone, true)
        XCTAssertTrue(db.reminders(inList: "Reminders").isEmpty)
        XCTAssertEqual(Set(db.lists.values.map(\.title)), ["Reminders", "Office", "Home"])
        XCTAssertNil(gone.reminderLink)
        XCTAssertEqual(sync.state.items.count, 1)
    }

    func testRepeatingTodoMovesOnAndItsReminderFollows() async throws {
        let context = try TestStore.context()
        let note = todo("Water plants", due: "2026-12-01", context: context)
        note.todoRepeat = .weekly
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db)
        await sync.run(context: context, storeUnavailable: false, now: t0)
        Todos.rollOver(note, now: Todos.dueDate("2026-12-01")!)
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        let reminder = try XCTUnwrap(db.reminders(inList: "Reminders").first)
        XCTAssertFalse(reminder.isDone)
        XCTAssertEqual(reminder.due, DateComponents(year: 2026, month: 12, day: 8))
        XCTAssertEqual(note.reminderLink, reminder.externalID)
        XCTAssertNotNil(note.todoRepeat)
    }

    func testTimeOfTheReminderStaysOnTheSameDay() async throws {
        let context = try TestStore.context()
        let note = todo("Dentist", due: "2026-12-01", context: context)
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db)
        await sync.run(context: context, storeUnavailable: false, now: t0)
        let id = try XCTUnwrap(db.reminders.keys.first)
        db.reminders[id]?.due = DateComponents(year: 2026, month: 12, day: 1, hour: 9)
        note.title = "Dentist at nine"
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        XCTAssertEqual(db.reminders[id]?.due, DateComponents(year: 2026, month: 12, day: 1, hour: 9))
        XCTAssertEqual(db.reminders[id]?.title, "Dentist at nine")
    }

    func testChangesInRemindersAreNotReadYetAndADeletedReminderIsNotMadeAgain() async throws {
        let context = try TestStore.context()
        let note = todo("Call Anna", context: context)
        let other = todo("Pay rent", context: context)
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db)
        await sync.run(context: context, storeUnavailable: false, now: t0)

        let first = try XCTUnwrap(db.reminders.values.first { $0.title == "Call Anna" })
        db.reminders[first.localID]?.title = "Call Anna tomorrow"
        db.reminders[first.localID]?.isDone = true
        let second = try XCTUnwrap(db.reminders.values.first { $0.title == "Pay rent" })
        db.reminders[second.localID] = nil
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))

        XCTAssertEqual(note.title, "Call Anna")
        XCTAssertFalse(note.isDone)
        XCTAssertNil(other.deletedAt)
        XCTAssertEqual(db.reminders[first.localID]?.title, "Call Anna tomorrow")
        XCTAssertEqual(db.reminders.count, 1)
        // A change in Porridge later still wins.
        note.title = "Call Anna now"
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(db.reminders[first.localID]?.title, "Call Anna now")
    }

    func testArchivedBowlIsLeftAloneUntilItIsBack() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        let note = todo("Call Anna", in: work, context: context)
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db)
        await sync.run(context: context, storeUnavailable: false, now: t0)

        Archive.set(true, work, in: context)
        note.title = "Changed while archived"
        note.deletedAt = Date()
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        XCTAssertEqual(db.reminders(inList: "Work").map(\.title), ["Call Anna"])

        Archive.set(false, work, in: context)
        note.deletedAt = nil
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(db.reminders(inList: "Work").map(\.title), ["Changed while archived"])
        XCTAssertEqual(db.lists.values.filter { $0.title == "Work" }.count, 1)
    }

    func testDeletedBowlsRemindersMoveAndItsEmptyListGoes() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        let home = bowl("Home", context: context)
        todo("Call Anna", in: work, context: context)
        todo("Fix the door", in: home, context: context)
        try context.save()
        let db = FakeReminderDB()
        let lists = ReminderLists()
        let sync = engine(db, lists: lists)
        await sync.run(context: context, storeUnavailable: false, now: t0)
        // A reminder of the user's own in Home keeps that list.
        let homeID = try XCTUnwrap(db.lists.values.first { $0.title == "Home" }?.id)
        db.reminders["mine"] = ReminderItem(localID: "mine", externalID: "ext-mine", listID: homeID, title: "Mine", notes: "", isDone: false)

        for folder in [work, home] {
            Projects.delete(folder, in: context)
            lists.bowlWasDeleted(Projects.key(folder))
        }
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))

        XCTAssertEqual(db.reminders(inList: "Reminders").map(\.title), ["Call Anna", "Fix the door"])
        XCTAssertNil(db.lists.values.first { $0.title == "Work" })
        XCTAssertNotNil(db.lists[homeID])
        XCTAssertTrue(sync.state.detachedListIDs.contains(homeID))
        // The list left standing never becomes a bowl, and the next run leaves everything as it is.
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(db.reminders(inList: "Home").map(\.title), ["Mine"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteFolder>()).count, 0)
    }

    func testMissingBowlWithoutTombstoneKeepsItsList() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        todo("Call Anna", in: work, context: context)
        try context.save()
        let db = FakeReminderDB()
        let lists = ReminderLists()
        let sync = engine(db, lists: lists)
        await sync.run(context: context, storeUnavailable: false, now: t0)
        // Gone from the store without `bowlWasDeleted` (another device, a store that lost it).
        context.delete(work)
        try context.save()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        XCTAssertEqual(db.reminders(inList: "Work").map(\.title), ["Call Anna"])
    }

    func testBrakesHoldUntilResumed() async throws {
        let context = try TestStore.context()
        for n in 1...6 { todo("Task \(n)", context: context) }
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db)
        await sync.run(context: context, storeUnavailable: false, now: t0)
        XCTAssertEqual(db.reminders.count, 6)

        // The store did not open: nothing at all.
        let paused = await sync.run(context: context, storeUnavailable: true, now: t0.addingTimeInterval(30))
        XCTAssertEqual(paused.pause, .storeUnavailable)

        // Every to-do gone from the store at once: their reminders stay.
        for note in try context.fetch(FetchDescriptor<Note>()) { context.delete(note) }
        try context.save()
        let gone = await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        XCTAssertEqual(gone.pause, .todosMissing(6))
        XCTAssertEqual(db.reminders.count, 6)
        // It stays paused…
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(90))
        XCTAssertEqual(db.reminders.count, 6)
        // …until "Resume".
        sync.resume()
        let resumed = await sync.run(context: context, storeUnavailable: false, acceptOnce: true, now: t0.addingTimeInterval(120))
        XCTAssertNil(resumed.pause)
        XCTAssertEqual(db.reminders.count, 0)
    }

    func testNoAccountPausesAndAccessIsNeeded() async throws {
        let context = try TestStore.context()
        todo("Call Anna", context: context)
        try context.save()
        let empty = FakeReminderDB(defaultList: nil)
        let paused = await engine(empty).run(context: context, storeUnavailable: false, now: t0)
        XCTAssertEqual(paused.pause, .noAccount)

        let db = FakeReminderDB()
        let store = FakeReminderStore(db)
        store.access = .denied
        let denied = ReminderSyncEngine(store: store, lists: ReminderLists(), device: "A", stateURL: nil)
        await denied.run(context: context, storeUnavailable: false, now: t0)
        XCTAssertTrue(db.reminders.isEmpty)
    }

    func testListGoneInRemindersLeavesTheBowlAndIsNotMadeAgain() async throws {
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        let note = todo("Call Anna", in: work, context: context)
        try context.save()
        let db = FakeReminderDB()
        let sync = engine(db)
        await sync.run(context: context, storeUnavailable: false, now: t0)
        let workID = try XCTUnwrap(db.lists.values.first { $0.title == "Work" }?.id)
        try FakeReminderStore(db).deleteList(workID)

        let state = await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        XCTAssertNil(state.pause)
        XCTAssertEqual(state.goneListTitles, ["Work"])
        XCTAssertNil(note.deletedAt)
        XCTAssertEqual(try context.fetch(FetchDescriptor<NoteFolder>()).count, 1)
        XCTAssertNil(db.lists.values.first { $0.title == "Work" })

        // Turned on anew: the bowl takes part again.
        sync.turnedOn()
        await sync.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        XCTAssertEqual(db.reminders(inList: "Work").map(\.title), ["Call Anna"])
    }

    func testTwoDevicesEndWithOneListAndOneReminderEach() async throws {
        // One store of notes (the iCloud sync is instant here), Reminders and the ledger per device.
        let context = try TestStore.context()
        let work = bowl("Work", context: context)
        todo("Call Anna", in: work, context: context)
        try context.save()
        let dbA = FakeReminderDB(), dbB = FakeReminderDB()
        dbB.sync(with: dbA)
        let listsA = ReminderLists(), listsB = ReminderLists()
        let a = engine(dbA, device: "A", lists: listsA)
        let b = engine(dbB, device: "B", lists: listsB)

        // Both run before either sees the other's Reminders or ledger.
        await a.run(context: context, storeUnavailable: false, now: t0)
        await b.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(20))
        XCTAssertEqual(dbA.reminders.count, 1)
        // B waits for the reminder A made (the to-do names it), but made its own list.
        XCTAssertTrue(dbB.reminders.isEmpty)
        XCTAssertEqual(dbB.lists.values.filter { $0.title == "Work" }.count, 1)

        // iCloud brings Reminders and the ledger together.
        dbA.sync(with: dbB)
        listsA.receive(listsB.ledger)
        listsB.receive(listsA.ledger)
        XCTAssertEqual(listsA.ledger, listsB.ledger)
        XCTAssertEqual(dbA.lists.values.filter { $0.title == "Work" }.count, 2)

        await a.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(60))
        await b.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(80))
        dbA.sync(with: dbB)
        await a.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(120))
        await b.run(context: context, storeUnavailable: false, now: t0.addingTimeInterval(140))
        dbA.sync(with: dbB)

        XCTAssertEqual(dbA.lists.values.filter { $0.title == "Work" }.count, 1)
        XCTAssertEqual(dbA.reminders(inList: "Work").map(\.title), ["Call Anna"])
        XCTAssertEqual(dbA.reminders.count, 1)
        XCTAssertEqual(a.state.items.count, 1)
        XCTAssertEqual(b.state.items.count, 1)
    }
}
