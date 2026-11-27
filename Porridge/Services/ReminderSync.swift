import CoreData
import Foundation
import Observation
import SwiftData

// MARK: - The ledger of lists, across devices

/// The ledger of lists (`ReminderListLedger`), kept in iCloud key-value storage as `AppointmentLinks` keeps its own:
/// merged entry by entry with what other devices wrote. Test runs (test data, an empty store, unit tests) keep it in
/// memory only, never in the real key-value storage.
@MainActor
@Observable
final class ReminderLists {
    static let shared = ReminderLists(
        defaults: ReminderSync.isHardDisabled ? nil : .standard,
        cloud: ReminderSync.isHardDisabled ? nil : .default
    )
    static let storageKey = "reminderLists"

    private(set) var ledger = ReminderListLedger()

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults? = nil, cloud: NSUbiquitousKeyValueStore? = nil) {
        self.defaults = defaults
        self.cloud = cloud
        ledger = Self.decode(defaults?.data(forKey: Self.storageKey)) ?? ReminderListLedger()
        if let cloud {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.followCloud() }
            }
            cloud.synchronize()
            followCloud()
        }
    }

    /// Takes the ledger as a run of the sync left it.
    func update(_ changed: ReminderListLedger) {
        guard changed != ledger else { return }
        ledger = changed
        save()
    }

    /// Takes on another device's ledger (what `followCloud` does; tests hand it over themselves).
    func receive(_ other: ReminderListLedger) {
        update(ReminderListLedger.merged(ledger, other))
    }

    /// A bowl was deleted or left: its entry becomes a tombstone, so its list is cleaned up (or left standing) and
    /// never becomes a bowl again. Called on every path that deletes a bowl, whether the sync is on or not.
    func bowlWasDeleted(_ key: String, now: Date = Date()) {
        update(ledger.unlinking(key, reason: .bowlDeleted, now: now))
    }

    private static func decode(_ data: Data?) -> ReminderListLedger? {
        data.flatMap { try? JSONDecoder().decode(ReminderListLedger.self, from: $0) }
    }

    private func save() {
        ledger = ledger.pruned()
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults?.set(data, forKey: Self.storageKey)
        cloud?.set(data, forKey: Self.storageKey)
    }

    private func followCloud() {
        let merged = ReminderListLedger.merged(ledger, Self.decode(cloud?.data(forKey: Self.storageKey)))
        guard merged != ledger else { return }
        ledger = merged
        save()
    }
}

// MARK: - What this device remembers

/// What the sync remembers on this device (`ReminderSyncState.json`, in `DataLocation.applicationSupport`): the lists
/// of the bowls here, the base of every linked to-do, and how the last run went.
struct ReminderSyncState: Codable, Equatable {
    var lists: [String: ReminderLocalList] = [:]
    var detachedListIDs: [String] = []
    /// By note id.
    var items: [String: ReminderBase] = [:]
    /// Since when a to-do names a reminder (made by another device) that is not here.
    var waitingSince: [String: Date] = [:]
    var pause: ReminderPause?
    var lastSync: Date?
    /// The lists that disappeared from Reminders in the last runs (their bowls no longer sync).
    var goneListTitles: [String] = []
    /// Reminders being made into to-dos, by the new to-do's id: written before the reminder gets the to-do's URL,
    /// so that a run cut off between the two makes the to-do the next time. Optional: files of stage 2 lack it.
    var importing: [String: ReminderImporting]?
    /// To-dos whose reminder the user moved into a list that takes no part: they are not brought into Reminders
    /// again (that would copy the reminder).
    var released: [String]?

    static var fileURL: URL { DataLocation.applicationSupport.appendingPathComponent("ReminderSyncState.json") }

    static func load(from url: URL?) -> ReminderSyncState {
        guard let url, let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(ReminderSyncState.self, from: data) else { return ReminderSyncState() }
        return state
    }

    func save(to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Lists that hold linked reminders.
    var listCount: Int { Set(items.values.map(\.listKey)).count }
}

/// A reminder being made into a to-do (`ReminderSyncState.importing`).
struct ReminderImporting: Codable, Equatable {
    var localID: String
    var listKey: String
}

// MARK: - One run

/// One run of the sync with Reminders: reads the bowls, to-dos, lists and reminders, plans (`ReminderListPlan`,
/// `ReminderSyncPlan`) and carries it out both ways. Until the first import was confirmed (`ReminderListLedger.isImported`)
/// only Porridge writes into Reminders and nothing is taken in; the run then only works out what an import would
/// bring (`preview`). The brakes and "a list disappeared" act all the same.
@MainActor
final class ReminderSyncEngine {
    let store: ReminderStore
    let lists: ReminderLists
    let device: String
    let stateURL: URL?
    private(set) var state: ReminderSyncState
    /// Both ways once the first import was confirmed (on any device).
    var direction: ReminderSyncDirection { lists.ledger.isImported ? .both : .toReminders }
    /// The bowl is shared (either way): its entries never carry `@reminder` (the copies of the other person would
    /// carry mine).
    var isShared: (String) -> Bool = { _ in false }
    /// The bowl is shared with me to view only.
    var isReadOnly: (String) -> Bool = { _ in false }
    /// How long a to-do waits for the reminder another device made for it before it gets one here.
    static let waitForOtherDevice: TimeInterval = 86400

    /// What the first import would bring (before it was confirmed; nil when there is nothing).
    private(set) var preview: ReminderImportPreview?
    /// The lists of the default list's account and what they are to Porridge (Settings › Reminders › Lists).
    private(set) var listRows: [ReminderListRow] = []
    /// A claim on a list waits to settle: a run after `ReminderListPlan.adoptSettle` makes its bowl.
    private(set) var adoptPending = false

    init(store: ReminderStore, lists: ReminderLists, device: String, stateURL: URL?) {
        self.store = store
        self.lists = lists
        self.device = device
        self.stateURL = stateURL
        state = ReminderSyncState.load(from: stateURL)
    }

    /// "Resume": the pause is lifted and the next run goes on once over what was counted.
    func resume() {
        state.pause = nil
        state.goneListTitles = []
        state.save(to: stateURL)
    }

    /// The sync is turned on: bowls whose list disappeared take part again.
    func turnedOn() {
        lists.update(lists.ledger.revivingGoneLists())
        state.goneListTitles = []
        state.save(to: stateURL)
    }

    /// One run. `acceptOnce`: the brakes over counts let it go on this time ("Resume").
    @discardableResult
    func run(context: ModelContext, storeUnavailable: Bool, acceptOnce: Bool = false, now: Date = Date()) async -> ReminderSyncState {
        if let pause = state.pause, pause.canResume, !acceptOnce { return state }
        guard store.access == .granted else { return state }

        var notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let folders = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        var noteByID = Dictionary(notes.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        var bowlKeys = Set(folders.map(Projects.key))
        let pulling = direction == .both
        // Nothing is taken in on a store that is empty while this device or the ledger knows linked things (the
        // notes not loaded yet, or lost): the brakes below hold the rest.
        let storeLooksEmpty = notes.isEmpty && folders.isEmpty && (!state.items.isEmpty || lists.ledger.linkedBowlCount > 0)
        let importing = pulling && !storeUnavailable && !storeLooksEmpty

        // Lists and reminders: every list of the default list's account, and the lists known here.
        let allLists = store.lists()
        let defaultID = store.defaultListID()
        let account = allLists.first { $0.id == defaultID }?.account
        let fetchIDs = Set(allLists.filter { $0.account == account }.map(\.id))
            .union(state.lists.values.map(\.listID).filter { id in allLists.contains { $0.id == id } })
        var reminders = await store.reminders(in: fetchIDs.sorted())

        var snapshots = allLists.map {
            ReminderListSnapshot(id: $0.id, title: $0.title, account: $0.account, isWritable: $0.isWritable, isSubscribed: $0.isSubscribed)
        }
        for item in reminders {
            guard let index = snapshots.firstIndex(where: { $0.id == item.listID }) else { continue }
            snapshots[index].reminderCount += 1
            if let id = ReminderMapping.noteID(from: item.url), let note = noteByID[id.uuidString], note.isTodo, !note.isDeleted {
                snapshots[index].porridgeBowls[ReminderMapping.listKey(of: note), default: 0] += 1
            }
        }
        let bowls = folders.map { folder -> ReminderBowlSnapshot in
            let key = Projects.key(folder)
            return ReminderBowlSnapshot(
                key: key, name: folder.name, isArchived: folder.isArchived,
                hasOpenTodos: notes.contains { $0.isTodo && !$0.isDone && !$0.isDeleted && $0.projectIDs.first == key },
                isReadOnly: isReadOnly(key)
            )
        }

        var plan = ReminderListPlan.plan(ReminderListPlan.Input(
            bowls: bowls, ledger: lists.ledger, local: state.lists, detachedListIDs: Set(state.detachedListIDs),
            lists: snapshots, defaultListID: defaultID, device: device, now: now,
            storeUnavailable: storeUnavailable, acceptGoneLists: acceptOnce, adoptLists: importing
        ))
        if let pause = plan.pause {
            state.pause = pause
            state.save(to: stateURL)
            return state
        }
        adoptPending = plan.adoptPending
        // The claims go into the ledger before any list or bowl is made.
        lists.update(plan.ledger)

        // The lists.
        for action in plan.actions {
            switch action {
            case .create(let bowl, let title):
                guard let made = try? store.createList(title: title) else { continue }
                plan.local[bowl] = ReminderLocalList(listID: made.id, title: made.title, createdHere: true)
                plan.targets[bowl] = made.id
                plan.waiting.remove(bowl)
            case .rename(let id, let title):
                try? store.renameList(id, to: title)
            case .join(_, let from, let into):
                var moved = 0
                let inList = reminders.filter { $0.listID == from }
                for item in inList {
                    // Only Porridge's own reminders move; one the user added there keeps the list.
                    guard let url = item.url, ReminderMapping.noteID(from: url) != nil else { continue }
                    let write = ReminderWrite(
                        localID: item.localID, listID: into, title: item.title, notes: item.notes, isDone: item.isDone,
                        due: item.due, url: url
                    )
                    guard let saved = try? store.save(write) else { continue }
                    moved += 1
                    if let index = reminders.firstIndex(where: { $0.localID == item.localID }) { reminders[index] = saved }
                }
                // Made here and empty now: it goes. Anything left (a reminder that could not move) keeps it.
                if moved == inList.count { try? store.deleteList(from) }
            case .createBowl(let listID, let title):
                // A list that is no bowl becomes one (this device's claim settled): an ordinary new bowl, linked.
                guard importing, let folder = Projects.create(title, in: context) else { continue }
                let key = Projects.key(folder)
                bowlKeys.insert(key)
                plan.local[key] = ReminderLocalList(listID: listID, title: title, createdHere: false)
                plan.targets[key] = listID
                plan.ledger = plan.ledger.linking(key, title: title, createdByPorridge: false, now: now)
            case .renameBowl(let key, let title):
                // Renamed in Reminders only. A shared bowl is not renamed from here (that would rename it for the
                // others too): its list gets the bowl's name back.
                guard pulling, let folder = folders.first(where: { Projects.key($0) == key }), let local = plan.local[key] else { continue }
                if isShared(key) || isReadOnly(key) {
                    try? store.renameList(local.listID, to: folder.name)
                    plan.local[key]?.title = folder.name
                    plan.ledger = plan.ledger.linking(key, title: folder.name, now: now)
                } else {
                    Projects.rename(folder, to: title, in: context)
                    plan.local[key]?.title = folder.name
                    plan.ledger = plan.ledger.linking(key, title: folder.name, now: now)
                }
            }
        }
        lists.update(plan.ledger)
        state.lists = plan.local
        state.detachedListIDs = Array(plan.detachedListIDs).sorted()
        func setLink(_ note: Note?, _ value: String?, listKey: String?) {
            guard let note, !(listKey.map { $0 != ReminderMapping.inboxKey && isShared($0) } ?? false) else { return }
            guard note.reminderLink != value else { return }
            // A key of the sync, not an edit: `updatedAt` stays.
            note.reminderLink = value
        }
        if !plan.goneLists.isEmpty {
            state.goneListTitles = Array(Set(state.goneListTitles + plan.goneLists.compactMap { lists.ledger.lists[$0]?.title })).sorted()
            // Their reminders went with them: the to-dos stay as they are, only their links go (a list made anew
            // later gets new reminders).
            for (id, base) in state.items where plan.goneLists.contains(base.listKey) {
                state.items[id] = nil
                setLink(noteByID[id], nil, listKey: base.listKey)
            }
        }

        // Which bowl each list is the list of.
        var keyOfList: [String: String] = [:]
        for (key, local) in plan.local { keyOfList[local.listID] = key }
        if let defaultID { keyOfList[defaultID] = ReminderMapping.inboxKey }
        for (key, id) in plan.targets { keyOfList[id] = key }
        /// The bowl (or `inbox`) a reminder in this list belongs to, when that list takes part now.
        func takingPart(_ listID: String) -> String? {
            guard let key = keyOfList[listID] else { return nil }
            if key == ReminderMapping.inboxKey { return listID == defaultID ? key : nil }
            return plan.targets[key] == listID && !plan.paused.contains(key) && bowlKeys.contains(key) ? key : nil
        }

        // A run cut off between giving a reminder a to-do's URL and making the to-do: the to-do is made now.
        var importingState = state.importing ?? [:]
        for (id, record) in importingState.sorted(by: { $0.key < $1.key }) {
            importingState[id] = nil
            guard noteByID[id] == nil, let uuid = UUID(uuidString: id),
                  let item = reminders.first(where: { $0.localID == record.localID }),
                  ReminderMapping.noteID(from: item.url) == uuid else { continue }
            let bowl = record.listKey == ReminderMapping.inboxKey || !bowlKeys.contains(record.listKey) ? nil : record.listKey
            let note = ReminderPull.makeTodo(id: uuid, from: item, bowl: bowl, now: now)
            note.fromReminder = item.stableID
            context.insert(note)
            notes.append(note)
            noteByID[id] = note
        }
        state.importing = importingState.isEmpty ? nil : importingState

        // Two devices that made a to-do of the same reminder at once: the older to-do stays, the other goes to
        // Recently Deleted (without its link, so its reminder stays), and the reminder points to the one that stays.
        if pulling {
            for group in ReminderPull.duplicates(notes) {
                let keepKey = ReminderMapping.listKey(of: group.keep)
                guard keepKey == ReminderMapping.inboxKey || !isShared(keepKey) else { continue }
                let removed = Set(group.remove.map(\.id))
                for dup in group.remove {
                    state.items[dup.id.uuidString] = nil
                    dup.reminderLink = nil
                    dup.fromReminder = nil
                    NoteStore.trash(dup, in: context)
                }
                let from = group.keep.fromReminder
                for (index, item) in reminders.enumerated() {
                    guard let pointsTo = ReminderMapping.noteID(from: item.url), removed.contains(pointsTo)
                            || (item.stableID == from && pointsTo != group.keep.id) else { continue }
                    let write = ReminderWrite(
                        localID: item.localID, listID: item.listID, title: item.title, notes: item.notes, isDone: item.isDone,
                        due: item.due, url: ReminderMapping.url(for: group.keep.id)
                    )
                    if let saved = try? store.save(write) { reminders[index] = saved }
                }
            }
        }

        let byLocal = Dictionary(reminders.map { ($0.localID, $0) }, uniquingKeysWith: { a, _ in a })
        var byExternal: [String: ReminderItem] = [:]
        var byNote: [String: [ReminderItem]] = [:]
        for item in reminders {
            if let id = item.externalID, !id.isEmpty { byExternal[id] = item }
            if let id = ReminderMapping.noteID(from: item.url) { byNote[id.uuidString, default: []].append(item) }
        }

        // The to-dos: every one linked here, every one naming a reminder, every open one.
        var ids = Set(state.items.keys)
        for note in notes where note.isTodo || note.reminderLink != nil || byNote[note.id.uuidString] != nil {
            ids.insert(note.id.uuidString)
        }
        // To-dos the user took out of Reminders (moved to a list that takes no part) stay out while they are to-dos.
        var released = Set(state.released ?? []).filter { id in noteByID[id].map { $0.isTodo && !$0.isDeleted } ?? false }

        struct Planned {
            var id: String
            var decision: ReminderSyncPlan.Decision
            var found: ReminderItem?
            var listKey: String?
        }
        var planned: [Planned] = []
        var duplicatesToDelete: [String] = []
        var waitingSince = state.waitingSince.filter { ids.contains($0.key) }

        for id in ids.sorted() {
            let note = noteByID[id]
            let base = state.items[id]
            if base == nil, released.contains(id) { continue }
            // A to-do gone from the store counts in the list it was in.
            let listKey = note.map(ReminderMapping.listKey(of:)) ?? base?.listKey
            let shared = listKey.map { $0 != ReminderMapping.inboxKey && isShared($0) } ?? false
            let link = shared ? nil : note?.reminderLink
            let paused = listKey.map {
                plan.paused.contains($0) || ($0 != ReminderMapping.inboxKey && !bowlKeys.contains($0))
            } ?? false

            // The reminder: by the base, by `@reminder`, by its URL; several for one to-do: one stays (not while its
            // bowl is left alone).
            var found = base.flatMap { b in b.localID.flatMap { byLocal[$0] } ?? byExternal[b.reminderID] }
            if found == nil, let link { found = byExternal[link] ?? store.reminder(externalID: link) }
            if found == nil, let base { found = store.reminder(externalID: base.reminderID) }
            let candidates = (byNote[id] ?? []) + (found.map { [$0] } ?? [])
            var unique: [ReminderItem] = []
            for item in candidates where !unique.contains(where: { $0.localID == item.localID }) { unique.append(item) }
            if !paused, let pick = ReminderSyncPlan.duplicates(
                unique.map { .init(id: $0.localID, created: $0.created) },
                preferred: (link.flatMap { l in unique.first { $0.externalID == l } } ?? found)?.localID
            ) {
                found = unique.first { $0.localID == pick.keep }
                duplicatesToDelete += pick.remove
            } else if found == nil {
                found = unique.first
            }

            let side: ReminderPorridgeSide
            if let note {
                if note.isDeleted { side = .trashed }
                else if !note.isTodo { side = .notTodo }
                else { side = .todo(ReminderMapping.fields(of: note), listKey: listKey ?? ReminderMapping.inboxKey) }
            } else {
                side = .missing
            }
            var input = ReminderSyncPlan.Input(porridge: side, base: base, direction: direction)
            if let found {
                // Taking in: a list that takes no part now (an archived or left-out bowl's) counts as none.
                let key = pulling ? takingPart(found.listID) : keyOfList[found.listID]
                input.reminder = ReminderNow(fields: Self.fields(of: found), listKey: key)
            }
            if let listKey {
                input.targetReady = plan.targets[listKey] != nil
                input.targetPaused = paused
                input.porridgeWins = listKey != ReminderMapping.inboxKey && isReadOnly(listKey)
            }
            if base == nil, found == nil, link != nil {
                let since = waitingSince[id] ?? now
                waitingSince[id] = since
                input.waitForOtherDevice = now.timeIntervalSince(since) < Self.waitForOtherDevice
            } else {
                waitingSince[id] = nil
            }
            planned.append(Planned(id: id, decision: ReminderSyncPlan.decide(input), found: found, listKey: listKey))
        }
        state.waitingSince = waitingSince

        if !acceptOnce, let pause = ReminderSyncPlan.brake(planned.map(\.decision)) {
            state.pause = pause
            if context.hasChanges { try? context.save() }
            state.save(to: stateURL)
            return state
        }

        // Carried out.
        for localID in Set(duplicatesToDelete) { try? store.deleteReminder(localID: localID) }

        for item in planned {
            let note = noteByID[item.id]
            switch item.decision {
            case .create(let fields, let listKey):
                guard let note, let listID = plan.targets[listKey] else { continue }
                let write = ReminderWrite(
                    localID: nil, listID: listID, title: fields.title, notes: fields.notes, isDone: fields.isDone,
                    due: ReminderMapping.dueComponents(day: fields.dueDay, keeping: nil), url: ReminderMapping.url(for: note.id)
                )
                guard let saved = try? store.save(write) else { continue }
                state.items[item.id] = ReminderBase(reminderID: saved.stableID, localID: saved.localID, fields: fields, listKey: listKey)
                setLink(note, saved.stableID, listKey: listKey)
            case .update(let update):
                guard let found = item.found else { continue }
                var fields = update.toReminder ?? Self.fields(of: found)
                var listID = update.moveTo.flatMap { plan.targets[$0] } ?? found.listID
                var base = update.base
                var baseListKey = update.baseListKey
                if pulling, let change = update.toPorridge, let note {
                    // Into Porridge, through the app's own calls; then the reminder carries what the to-do has now
                    // (all subtasks ticked when it was done, the next round of a repeating one, the merged ticks).
                    ReminderPull.apply(change, reminderDue: Self.fields(of: found).dueDay, to: note, in: context, now: now)
                    let after = ReminderMapping.fields(of: note)
                    let afterKey = ReminderMapping.listKey(of: note)
                    fields = after
                    base = after
                    if let target = plan.targets[afterKey] {
                        listID = target
                        baseListKey = afterKey
                    }
                }
                var saved = found
                if fields != Self.fields(of: found) || listID != found.listID {
                    let write = ReminderWrite(
                        localID: found.localID, listID: listID, title: fields.title, notes: fields.notes, isDone: fields.isDone,
                        due: ReminderMapping.dueComponents(day: fields.dueDay, keeping: found.due),
                        url: note.map { ReminderMapping.url(for: $0.id) } ?? found.url ?? ReminderMapping.url(for: UUID())
                    )
                    guard let result = try? store.save(write) else { continue }
                    saved = result
                }
                state.items[item.id] = ReminderBase(reminderID: saved.stableID, localID: saved.localID, fields: base, listKey: baseListKey)
                setLink(note, saved.stableID, listKey: item.listKey)
            case .nothing:
                if let found = item.found, var base = state.items[item.id], base.localID != found.localID || base.reminderID != found.stableID {
                    base.localID = found.localID
                    base.reminderID = found.stableID
                    state.items[item.id] = base
                }
                if let found = item.found, state.items[item.id] != nil { setLink(note, found.stableID, listKey: item.listKey) }
            case .deleteReminder:
                if let found = item.found { try? store.deleteReminder(localID: found.localID) }
                state.items[item.id] = nil
                setLink(note, nil, listKey: item.listKey)
            case .unlink, .forget:
                // Moved by the user into a list that takes no part: not brought back into Reminders.
                if item.decision == .unlink, item.found != nil, note?.isTodo == true { released.insert(item.id) }
                state.items[item.id] = nil
                setLink(note, nil, listKey: item.listKey)
            case .trashTodo:
                // The open reminder was deleted in Reminders: the to-do goes to Recently Deleted (it can be put
                // back; then it gets a new reminder). Before the first import it stays as it is.
                guard pulling, let note, !note.isDeleted else { continue }
                NoteStore.trash(note, in: context)
                state.items[item.id] = nil
                setLink(note, nil, listKey: item.listKey)
            case .skip, .wait:
                break
            }
        }
        state.released = released.isEmpty ? nil : released.sorted()

        // New reminders (no to-do's URL, open) in a list that takes part become to-dos: in its bowl, or in the
        // Inbox from the default list (left out by the user: only those made after that).
        if importing {
            importReminders(
                reminders.filter { !duplicatesToDelete.contains($0.localID) }, notes: notes, defaultID: defaultID,
                takingPart: takingPart, context: context, setLink: setLink, now: now
            )
        }

        // Deleted bowls: their lists once their reminders moved with their to-dos.
        for (key, listID) in plan.deletedBowls.sorted(by: { $0.key < $1.key }) {
            let remaining = await store.reminders(in: [listID]).count
            let link = lists.ledger.lists[key]
            switch ReminderListPlan.afterBowlDeleted(remaining: remaining, createdByPorridge: link?.createdByPorridge ?? false, tombstone: link?.isTombstone ?? false) {
            case .delete:
                try? store.deleteList(listID)
            case .detach:
                if !state.detachedListIDs.contains(listID) { state.detachedListIDs.append(listID) }
            }
            state.lists[key] = nil
        }

        if context.hasChanges { try? context.save() }
        describe(plan: plan, allLists: allLists, account: account, defaultID: defaultID, reminders: reminders, folders: folders, pulling: pulling)
        state.pause = nil
        state.lastSync = now
        state.save(to: stateURL)
        return state
    }

    /// Makes to-dos of the reminders that have none. The reminder gets the new to-do's URL first (and that is noted
    /// here before), the to-do is made only once that was saved: another device sees it is taken, and no run ever
    /// takes in a reminder Porridge wrote (they all carry an entry's URL).
    private func importReminders(
        _ reminders: [ReminderItem], notes: [Note], defaultID: String?, takingPart: (String) -> String?,
        context: ModelContext, setLink: (Note?, String?, String?) -> Void, now: Date
    ) {
        let inboxLink = lists.ledger.lists[ReminderMapping.inboxKey]
        let inboxSince = inboxLink?.state == .excluded ? inboxLink?.changedAt : nil
        let knownLocal = Set(state.items.values.compactMap(\.localID))
        let knownStable = Set(state.items.values.map(\.reminderID))
        var claimed: [String: Note] = [:]
        for note in notes where !note.isDeleted {
            if let from = note.fromReminder { claimed[from] = claimed[from] ?? note }
            if let link = note.reminderLink { claimed[link] = claimed[link] ?? note }
        }
        let fresh = reminders
            .filter { !$0.isDone && $0.url.flatMap(ReminderMapping.noteID(from:)) == nil }
            .sorted { ($0.created ?? .distantPast, $0.localID) < ($1.created ?? .distantPast, $1.localID) }
        for item in fresh {
            guard !knownLocal.contains(item.localID), !knownStable.contains(item.stableID),
                  let key = takingPart(item.listID) else { continue }
            if key == ReminderMapping.inboxKey, let inboxSince {
                guard let created = item.created, created > inboxSince else { continue }
            }
            // A bowl shared with me to view only takes nothing in.
            if key != ReminderMapping.inboxKey, isReadOnly(key) { continue }
            // Another device made its to-do already (the URL it wrote is not here yet): it is pointed to that one.
            if let existing = claimed[item.stableID] {
                let fields = Self.fields(of: item)
                _ = try? store.save(ReminderWrite(
                    localID: item.localID, listID: item.listID, title: fields.title, notes: fields.notes, isDone: item.isDone,
                    due: item.due, url: ReminderMapping.url(for: existing.id)
                ))
                continue
            }
            let id = UUID()
            let bowl = key == ReminderMapping.inboxKey ? nil : key
            let note = ReminderPull.makeTodo(id: id, from: item, bowl: bowl, now: now)
            let fields = ReminderMapping.fields(of: note)
            var record = state.importing ?? [:]
            record[id.uuidString] = ReminderImporting(localID: item.localID, listKey: key)
            state.importing = record
            state.save(to: stateURL)
            let write = ReminderWrite(
                localID: item.localID, listID: item.listID, title: fields.title, notes: fields.notes, isDone: false,
                due: ReminderMapping.dueComponents(day: fields.dueDay, keeping: item.due), url: ReminderMapping.url(for: id)
            )
            guard let saved = try? store.save(write) else {
                state.importing?[id.uuidString] = nil
                continue
            }
            note.fromReminder = saved.stableID
            context.insert(note)
            try? context.save()
            state.items[id.uuidString] = ReminderBase(reminderID: saved.stableID, localID: saved.localID, fields: fields, listKey: key)
            setLink(note, saved.stableID, key)
            state.importing?[id.uuidString] = nil
            if state.importing?.isEmpty == true { state.importing = nil }
            claimed[saved.stableID] = note
        }
    }

    /// What the first import would bring (`preview`, only before it) and the lists for Settings (`listRows`).
    private func describe(
        plan: ReminderListPlan.Result, allLists: [ReminderListInfo], account: String?, defaultID: String?,
        reminders: [ReminderItem], folders: [NoteFolder], pulling: Bool
    ) {
        let names = Dictionary(folders.map { (Projects.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let knownLocal = Set(state.items.values.compactMap(\.localID))
        var open: [String: Int] = [:]
        for item in reminders where !item.isDone && item.url.flatMap(ReminderMapping.noteID(from:)) == nil && !knownLocal.contains(item.localID) {
            open[item.listID, default: 0] += 1
        }
        let byID = Dictionary(allLists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var keyOfList: [String: String] = [:]
        for (key, local) in plan.local where names[key] != nil { keyOfList[local.listID] = key }

        if pulling {
            preview = nil
        } else {
            var entries: [ReminderImportPreview.Entry] = []
            if let defaultID, let list = byID[defaultID], let count = open[defaultID], count > 0 {
                entries.append(.init(listID: defaultID, title: list.title, kind: .inbox, openCount: count))
            }
            for (listID, key) in keyOfList.sorted(by: { $0.value < $1.value }) where !plan.paused.contains(key) {
                guard let folder = names[key], let list = byID[listID], let count = open[listID], count > 0 else { continue }
                entries.append(.init(listID: listID, title: list.title, kind: .bowl(key: key, name: folder.name), openCount: count))
            }
            for listID in plan.adoptable {
                guard let list = byID[listID] else { continue }
                entries.append(.init(listID: listID, title: list.title, kind: .newBowl, openCount: open[listID] ?? 0))
            }
            preview = entries.isEmpty ? nil : ReminderImportPreview(entries: entries)
        }

        var rows: [ReminderListRow] = []
        let detached = Set(state.detachedListIDs)
        let ledger = lists.ledger
        for list in allLists where list.account == account && list.isWritable && !list.isSubscribed && !detached.contains(list.id) {
            if list.id == defaultID {
                let on = ledger.lists[ReminderMapping.inboxKey]?.state != .excluded
                rows.append(.init(id: list.id, title: list.title, detail: String(localized: "Inbox"), isOn: on, target: .inbox))
            } else if let key = keyOfList[list.id], let folder = names[key] {
                let on = ledger.lists[key]?.state != .excluded
                let detail = folder.isArchived
                    ? String(localized: "Bowl “\(folder.name)” (archived)")
                    : String(localized: "Bowl “\(folder.name)”")
                rows.append(.init(id: list.id, title: list.title, detail: detail, isOn: on, target: .bowl(key)))
            } else if plan.excludedLists.contains(list.id) {
                rows.append(.init(id: list.id, title: list.title, detail: String(localized: "Not synced"), isOn: false, target: .list(list.title)))
            } else if plan.adoptable.contains(list.id) {
                rows.append(.init(id: list.id, title: list.title, detail: String(localized: "Becomes a bowl"), isOn: true, target: .list(list.title)))
            }
        }
        listRows = rows.sorted { a, b in
            if (a.target == .inbox) != (b.target == .inbox) { return a.target == .inbox }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    static func fields(of item: ReminderItem) -> ReminderFields {
        ReminderFields(title: item.title, notes: item.notes, isDone: item.isDone, dueDay: ReminderMapping.dueDay(from: item.due))
    }
}

// MARK: - The coordinator

/// The sync of to-dos with Apple's Reminders (one list = one bowl; the Inbox's to-dos in the default list). Per
/// device, off until turned on in Settings › General. Runs a moment after every save of the notes (this app's and
/// the iCloud sync's), when Reminders changed, at launch and when the app comes to the front; only while it is on and
/// Porridge has access, never on a store that failed to open, and never in a test run (test data, an empty store,
/// unit tests: there it is off for good and never touches the real Reminders). Both ways once the first import was
/// confirmed ("Bring Reminders into Porridge?", asked once per device; a ledger with the import done asks no more).
@MainActor
@Observable
final class ReminderSync {
    static let shared = ReminderSync()
    static let enabledKey = "remindersSyncEnabled"
    static let deviceKey = "remindersSyncDevice"
    /// This device asked "Bring Reminders into Porridge?" (answered either way).
    static let importAskedKey = "remindersImportAsked"

    /// Test runs never sync with the real Reminders: test data, an empty store, unit tests, and (Debug) UI tests,
    /// which start the app with settings as launch arguments (`-onboardingDone`).
    nonisolated static let isHardDisabled: Bool = {
        if DataLocation.testFolder != nil || UserDefaults.standard.bool(forKey: "emptyStore")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-onboardingDone") { return true }
        #endif
        return false
    }()

    enum Status: Equatable {
        case off
        /// A test run.
        case unavailable
        case denied
        case syncing
        case synced(Date, lists: Int, todos: Int)
        case paused(ReminderPause)
    }

    private(set) var isEnabled: Bool
    private(set) var status: Status = .off
    private(set) var goneListTitles: [String] = []
    /// What the first import would bring; nil once it was confirmed or when there is nothing.
    private(set) var preview: ReminderImportPreview?
    /// The sheet "Bring Reminders into Porridge?" is up (iOS: `ReminderImportHost`; Mac: `ReminderImportSheetController`).
    var isAskingImport = false
    /// The lists in Settings › Reminders.
    private(set) var listRows: [ReminderListRow] = []

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var engine: ReminderSyncEngine?
    @ObservationIgnored private let store = EventKitReminderStore()
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var runAgain = false
    @ObservationIgnored private var acceptOnce = false
    @ObservationIgnored private var lastRunEnded = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        isEnabled = !Self.isHardDisabled && UserDefaults.standard.bool(forKey: Self.enabledKey)
        status = Self.isHardDisabled ? .unavailable : .off
    }

    /// At launch (both apps). Follows the saves of the notes, the iCloud sync's changes and Reminders' own.
    func start(_ container: ModelContainer) {
        guard self.container == nil, !Self.isHardDisabled else { return }
        self.container = container
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon(after: .seconds(3)) }
        })
        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon(after: .seconds(5)) }
        })
        observers.append(center.addObserver(forName: store.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Its own writes come back as changes: not right after a run.
                guard let self, !self.isRunning, Date().timeIntervalSince(self.lastRunEnded) > 5 else { return }
                self.syncSoon(after: .seconds(10))
            }
        })
        refreshStatus()
        syncSoon(after: .seconds(2))
    }

    /// The app came to the front.
    func appBecameActive() {
        refreshStatus()
        syncSoon(after: .seconds(1))
    }

    /// The switch. Turned on: access is asked for, then every open to-do goes into Reminders. Turned off: everything
    /// stays in Reminders as it is.
    /// The first import is not confirmed yet while there is something to bring in ("Reminders not imported yet",
    /// with "Review").
    var isImportPending: Bool { isEnabled && preview != nil && !ReminderLists.shared.ledger.isImported }

    /// "Import": the lists left out go into the ledger as excluded (for every device; the default list left out
    /// brings only reminders made from now on), the import is marked done, and a run takes them in.
    func confirmImport(leavingOut listIDs: Set<String>, now: Date = Date()) {
        UserDefaults.standard.set(true, forKey: Self.importAskedKey)
        isAskingImport = false
        guard let preview else { return }
        var ledger = ReminderLists.shared.ledger
        for entry in preview.entries where listIDs.contains(entry.listID) {
            switch entry.kind {
            case .inbox: ledger = ledger.excluding(ReminderMapping.inboxKey, title: entry.title, now: now)
            case .bowl(let key, _): ledger = ledger.excluding(key, title: entry.title, now: now)
            case .newBowl: ledger = ledger.excluding(ReminderListLedger.listKey(entry.title), title: entry.title, now: now)
            }
        }
        ReminderLists.shared.update(ledger.markingImported(now: now))
        self.preview = nil
        syncSoon(after: .zero)
    }

    /// "Not Now": Porridge goes on writing into Reminders; the status says "Reminders not imported yet" with "Review".
    func declineImport() {
        UserDefaults.standard.set(true, forKey: Self.importAskedKey)
        isAskingImport = false
    }

    /// "Review": the question again.
    func reviewImport() {
        isAskingImport = isImportPending
    }

    /// A list's switch in Settings: left out (its reminders stay out, a bowl's to-dos no longer sync) or taking part
    /// again (a list that is no bowl becomes one). Kept in the ledger: the same on every device.
    func setList(_ row: ReminderListRow, on: Bool, now: Date = Date()) {
        var ledger = ReminderLists.shared.ledger
        let key: String
        switch row.target {
        case .inbox: key = ReminderMapping.inboxKey
        case .bowl(let bowl): key = bowl
        case .list(let title): key = ReminderListLedger.listKey(title)
        }
        ledger = on ? ledger.including(key, title: row.title, now: now) : ledger.excluding(key, title: row.title, now: now)
        ReminderLists.shared.update(ledger)
        if let index = listRows.firstIndex(where: { $0.id == row.id }) { listRows[index].isOn = on }
        syncSoon(after: .seconds(1))
    }

    func setEnabled(_ on: Bool) async {
        guard !Self.isHardDisabled else { return }
        if on {
            if store.access != .granted {
                guard await store.requestAccess() else {
                    isEnabled = false
                    UserDefaults.standard.set(false, forKey: Self.enabledKey)
                    status = .denied
                    return
                }
            }
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            makeEngine()?.turnedOn()
            goneListTitles = []
            syncSoon(after: .zero)
        } else {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            pending?.cancel()
            status = .off
        }
    }

    /// "Resume" after a pause over things gone: the next run goes on once.
    func resume() {
        makeEngine()?.resume()
        goneListTitles = []
        acceptOnce = true
        syncSoon(after: .zero)
    }

    func syncSoon(after delay: Duration) {
        guard container != nil, isEnabled else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    private func makeEngine() -> ReminderSyncEngine? {
        if let engine { return engine }
        guard !Self.isHardDisabled else { return nil }
        let device: String
        if let stored = UserDefaults.standard.string(forKey: Self.deviceKey) {
            device = stored
        } else {
            device = UUID().uuidString
            UserDefaults.standard.set(device, forKey: Self.deviceKey)
        }
        let engine = ReminderSyncEngine(store: store, lists: .shared, device: device, stateURL: ReminderSyncState.fileURL)
        engine.isShared = { BowlSharing.shared.isShared(UUID(uuidString: $0)) }
        engine.isReadOnly = { BowlSharing.shared.isReadOnly(UUID(uuidString: $0)) }
        self.engine = engine
        return engine
    }

    private func run() async {
        guard let container, isEnabled, let engine = makeEngine() else { return }
        guard store.access == .granted else {
            status = .denied
            return
        }
        guard !isRunning else {
            runAgain = true
            return
        }
        isRunning = true
        status = .syncing
        let accept = acceptOnce
        acceptOnce = false
        let state = await engine.run(context: container.mainContext, storeUnavailable: AppContainer.storeError != nil, acceptOnce: accept)
        isRunning = false
        lastRunEnded = Date()
        show(state)
        preview = engine.preview
        listRows = engine.listRows
        // Asked once per device, and not when another device's import is in the ledger.
        if isImportPending, !UserDefaults.standard.bool(forKey: Self.importAskedKey) { isAskingImport = true }
        if runAgain {
            runAgain = false
            syncSoon(after: .seconds(1))
        } else if engine.adoptPending {
            // A claim on a list settles: its bowl is made by the run after.
            syncSoon(after: .seconds(Int(ReminderListPlan.adoptSettle) + 2))
        }
    }

    private func refreshStatus() {
        guard !Self.isHardDisabled else {
            status = .unavailable
            return
        }
        guard isEnabled else {
            status = store.access == .denied ? .denied : .off
            return
        }
        if store.access != .granted {
            status = .denied
        } else if let engine = makeEngine() {
            show(engine.state)
            if preview == nil { preview = engine.preview }
            if listRows.isEmpty { listRows = engine.listRows }
        }
    }

    private func show(_ state: ReminderSyncState) {
        goneListTitles = state.goneListTitles
        if let pause = state.pause {
            status = .paused(pause)
        } else if let last = state.lastSync {
            status = .synced(last, lists: state.listCount, todos: state.items.count)
        } else {
            status = .syncing
        }
    }

    // MARK: Words

    /// The status line under the switch: "Synced just now · 4 lists · 41 to-dos", "Paused: …"; nil while off.
    func statusLine(now: Date = Date()) -> String? {
        switch status {
        case .off: return nil
        case .unavailable: return String(localized: "Not available in test runs.")
        case .denied: return Self.deniedText
        case .syncing: return String(localized: "Syncing…")
        case .paused(let pause): return String(localized: "Paused: \(pause.message).")
        case .synced(let date, let lists, let todos):
            let when = now.timeIntervalSince(date) < 60
                ? String(localized: "just now")
                : date.formatted(.relative(presentation: .named))
            let listWord = lists == 1 ? String(localized: "1 list") : String(localized: "\(lists) lists")
            let todoWord = todos == 1 ? String(localized: "1 to-do") : String(localized: "\(todos) to-dos")
            var line = String(localized: "Synced \(when)") + " · " + listWord + " · " + todoWord
            if isImportPending { line += "\n" + String(localized: "Reminders not imported yet.") }
            if !goneListTitles.isEmpty {
                let names = goneListTitles.map { "“\($0)”" }.joined(separator: ", ")
                line += "\n" + String(localized: "Removed in Reminders, no longer synced: \(names).")
            }
            return line
        }
    }

    /// Whether the status offers "Resume".
    var canResume: Bool {
        if case .paused(let pause) = status { return pause.canResume }
        return false
    }

    static var deniedText: String {
        #if os(macOS)
        String(localized: "Porridge has no access to Reminders. Allow it in System Settings › Privacy & Security › Reminders.")
        #else
        String(localized: "Porridge has no access to Reminders. Allow it in Settings › Apps › Porridge.")
        #endif
    }

    static let localOnlyNote = String(localized: "iCloud Sync is off: only the to-dos on this device go into Reminders, and turning this on on other devices can make lists twice.")
}
