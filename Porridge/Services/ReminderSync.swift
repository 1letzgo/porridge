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

// MARK: - One run

/// One run of the sync with Reminders: reads the bowls, to-dos, lists and reminders, plans (`ReminderListPlan`,
/// `ReminderSyncPlan`) and carries out what goes into Reminders. With `direction` `.toReminders` (stage 2) nothing
/// that changed in Reminders is taken into Porridge; the brakes and "a list disappeared" act all the same.
@MainActor
final class ReminderSyncEngine {
    let store: ReminderStore
    let lists: ReminderLists
    let device: String
    let stateURL: URL?
    private(set) var state: ReminderSyncState
    var direction: ReminderSyncDirection = .toReminders
    /// The bowl is shared (either way): its entries never carry `@reminder` (the copies of the other person would
    /// carry mine).
    var isShared: (String) -> Bool = { _ in false }
    /// The bowl is shared with me to view only.
    var isReadOnly: (String) -> Bool = { _ in false }
    /// How long a to-do waits for the reminder another device made for it before it gets one here.
    static let waitForOtherDevice: TimeInterval = 86400

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

        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let folders = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        let noteByID = Dictionary(notes.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let bowlKeys = Set(folders.map(Projects.key))

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
            storeUnavailable: storeUnavailable, acceptGoneLists: acceptOnce
        ))
        if let pause = plan.pause {
            state.pause = pause
            state.save(to: stateURL)
            return state
        }
        // The claims go into the ledger before any list is made.
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
            case .createBowl, .renameBowl:
                // The way back (stage 3/4) is not carried out yet.
                break
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
                input.reminder = ReminderNow(fields: Self.fields(of: found), listKey: keyOfList[found.listID])
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
            state.save(to: stateURL)
            return state
        }

        // Into Reminders.
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
                var saved = found
                if update.toReminder != nil || update.moveTo != nil {
                    let fields = update.toReminder ?? Self.fields(of: found)
                    let listID = update.moveTo.flatMap { plan.targets[$0] } ?? found.listID
                    let write = ReminderWrite(
                        localID: found.localID, listID: listID, title: fields.title, notes: fields.notes, isDone: fields.isDone,
                        due: ReminderMapping.dueComponents(day: fields.dueDay, keeping: found.due),
                        url: note.map { ReminderMapping.url(for: $0.id) } ?? found.url ?? ReminderMapping.url(for: UUID())
                    )
                    guard let result = try? store.save(write) else { continue }
                    saved = result
                }
                // The way back (`toPorridge`) is not carried out in stage 2; the plan does not ask for it then.
                state.items[item.id] = ReminderBase(reminderID: saved.stableID, localID: saved.localID, fields: update.base, listKey: update.baseListKey)
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
                state.items[item.id] = nil
                setLink(note, nil, listKey: item.listKey)
            case .trashTodo, .skip, .wait:
                // `trashTodo` is the way back (stage 3): the to-do stays, and so does its base.
                break
            }
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
        state.pause = nil
        state.lastSync = now
        state.save(to: stateURL)
        return state
    }

    static func fields(of item: ReminderItem) -> ReminderFields {
        ReminderFields(title: item.title, notes: item.notes, isDone: item.isDone, dueDay: ReminderMapping.dueDay(from: item.due))
    }
}

// MARK: - The coordinator

/// The sync of to-dos with Apple's Reminders (one list = one bowl; the Inbox's to-dos in the default list). Per
/// device, off until turned on in Settings › General. Runs a moment after every save of the notes (this app's and
/// the iCloud sync's), at launch and when the app comes to the front; only while it is on and Porridge has access,
/// never on a store that failed to open, and never in a test run (test data, an empty store, unit tests: there it is
/// off for good and never touches the real Reminders). Stage 2: Porridge writes into Reminders only.
@MainActor
@Observable
final class ReminderSync {
    static let shared = ReminderSync()
    static let enabledKey = "remindersSyncEnabled"
    static let deviceKey = "remindersSyncDevice"

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
        if runAgain {
            runAgain = false
            syncSoon(after: .seconds(1))
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

    static let betaNote = String(localized: "Beta: changes made in Reminders are not read yet.")
    static let localOnlyNote = String(localized: "iCloud Sync is off: only the to-dos on this device go into Reminders, and turning this on on other devices can make lists twice.")
}
