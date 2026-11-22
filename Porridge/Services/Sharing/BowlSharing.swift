import CloudKit
import CoreData
import Foundation
import Observation
import SwiftData

/// What a device knows about its shared bowls and where its sync engines stand, in a file of its own.
struct SharedBowlStore {
    struct Saved: Codable {
        var bowls: [SharedBowlInfo] = []
        var privateEngine: CKSyncEngine.State.Serialization?
        var sharedEngine: CKSyncEngine.State.Serialization?
    }

    let url: URL

    func load() -> Saved {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return Saved() }
        return saved
    }

    func save(_ saved: Saved) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum BowlSharingError: LocalizedError {
    case unavailable
    case notShared
    /// Sharing of the bowl is being stopped (or the bowl left) and the server has not confirmed it yet.
    case ending
    /// The zone could not be deleted now; it is tried again. Until then the others keep their access.
    case stopPending(String)
    /// The shared zone could not be left now; it is tried again. Until then I stay in the bowl.
    case leavePending(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Sharing needs iCloud Sync. Turn it on in Settings › General.")
        case .notShared: String(localized: "This bowl is not shared any more.")
        case .ending: String(localized: "Sharing of this bowl is still being stopped. Try again in a moment.")
        case .stopPending(let reason):
            String(localized: "Porridge could not reach iCloud to stop sharing (\(reason)). Until it does, the people you shared the bowl with keep their access. It tries again by itself.")
        case .leavePending(let reason):
            String(localized: "Porridge could not reach iCloud to leave the bowl (\(reason)). Until it does, you stay in it. It tries again by itself.")
        }
    }
}

/// Shares bowls with other iCloud users (see `SharedBowlModel.swift` for the design).
///
/// Two `CKSyncEngine`s: one on the private database for the bowls I share (their zones are mine), one on the shared
/// database for the bowls shared with me. Changes in the store are looked for after each save (`scan`): what differs
/// from what the zone has is sent; what the zones bring is written into the store. Only with iCloud sync on.
///
/// Sharing never deletes what someone may still want: an entry that leaves a shared bowl goes to the inbox; only
/// copies taken from someone else's bowl are deleted, when that share ends, and never the files of anything.
@MainActor
@Observable
final class BowlSharing {
    static let shared = BowlSharing()

    /// Sharing works with iCloud sync only (and never on test data or on the empty store of a failed launch).
    static var isAvailable: Bool {
        SyncMode.active == .iCloud && DataLocation.testFolder == nil && AppContainer.storeError == nil
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// The shared bowls by their id: mine that I share, and those shared with me.
    private(set) var bowls: [UUID: SharedBowlInfo] = [:]
    /// Bowls whose share is being set up right now.
    private(set) var preparing: Set<UUID> = []
    /// Something to tell the person, e.g. a shared bowl that could not be opened; the app shows it and clears it.
    var notice: String?

    @ObservationIgnored private var modelContainer: ModelContainer?
    @ObservationIgnored private(set) var cloud: CKContainer?
    @ObservationIgnored private var privateEngine: CKSyncEngine?
    @ObservationIgnored private var sharedEngine: CKSyncEngine?
    @ObservationIgnored private var engineDelegates: [SharingEngineDelegate] = []
    @ObservationIgnored private var store: SharedBowlStore?
    @ObservationIgnored private var engineStates: (private: CKSyncEngine.State.Serialization?, shared: CKSyncEngine.State.Serialization?) = (nil, nil)
    /// What was written into records being sent, by "zone/record": becomes what the zone has once they are saved.
    @ObservationIgnored private var inFlight: [String: String] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var downloading: Set<String> = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Shares accepted before the app was ready for them.
    @ObservationIgnored private var waitingShares: [CKShare.Metadata] = []
    /// When the private sync last brought something (in this run): removals wait for it (`SharedBowlMerge.dueRemovals`).
    @ObservationIgnored private var lastImport: Date?
    /// Zone deletions being tried right now, and when each was last tried.
    @ObservationIgnored private var endingAttempts: [UUID: Date] = [:]
    @ObservationIgnored private var endingRunning: Set<UUID> = []
    /// Records whose conflict is being resolved by fetching them whole.
    @ObservationIgnored private var refetching: Set<String> = []

    private var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SharedBowlPayloads", isDirectory: true)
    }

    // MARK: - Asking

    func info(for bowlID: UUID?) -> SharedBowlInfo? {
        bowlID.flatMap { bowls[$0] }
    }

    func isShared(_ bowlID: UUID?) -> Bool { info(for: bowlID) != nil }

    /// Shared with me (not mine).
    func isSharedWithMe(_ bowlID: UUID?) -> Bool { info(for: bowlID)?.role == .participant }

    // MARK: - Start

    /// At launch (both apps): finds the shared bowls of this device and starts following them.
    func start(_ modelContainer: ModelContainer) {
        guard self.modelContainer == nil, Self.isAvailable, !Self.isRunningTests else { return }
        self.modelContainer = modelContainer
        let store = SharedBowlStore(url: DataLocation.applicationSupport.appendingPathComponent("SharedBowls.json"))
        self.store = store
        let saved = store.load()
        bowls = Dictionary(saved.bowls.map { ($0.bowlID, $0) }, uniquingKeysWith: { a, _ in a })
        engineStates = (saved.privateEngine, saved.sharedEngine)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        cloud = CKContainer(identifier: AudioStore.containerIdentifier)
        makeEngines()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BowlSharing.shared.scanSoon() }
        })
        observers.append(center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                BowlSharing.shared.lastImport = Date()
                BowlSharing.shared.scanSoon()
            }
        })
        let waiting = waitingShares
        waitingShares = []
        for metadata in waiting { Task { await accept(metadata) } }
        retryEndings()
        scanSoon(after: .seconds(3))
        Task { await refreshPeople() }
    }

    private func makeEngines() {
        guard let cloud else { return }
        let privateDelegate = SharingEngineDelegate(scope: .private)
        let sharedDelegate = SharingEngineDelegate(scope: .shared)
        engineDelegates = [privateDelegate, sharedDelegate]
        privateEngine = CKSyncEngine(.init(database: cloud.privateCloudDatabase, stateSerialization: engineStates.private, delegate: privateDelegate))
        sharedEngine = CKSyncEngine(.init(database: cloud.sharedCloudDatabase, stateSerialization: engineStates.shared, delegate: sharedDelegate))
    }

    private func engine(for role: SharedBowlRole) -> CKSyncEngine? {
        role == .owner ? privateEngine : sharedEngine
    }

    private func engine(for scope: CKDatabase.Scope) -> CKSyncEngine? {
        scope == .private ? privateEngine : sharedEngine
    }

    /// An engine replaced after an account change may still be finishing: what it says is not listened to.
    func isCurrent(_ engine: CKSyncEngine, scope: CKDatabase.Scope) -> Bool {
        self.engine(for: scope) === engine
    }

    private func database(for role: SharedBowlRole) -> CKDatabase? {
        role == .owner ? cloud?.privateCloudDatabase : cloud?.sharedCloudDatabase
    }

    private var context: ModelContext? { modelContainer?.mainContext }

    /// Stores the bowl's state only when it changed (every change redraws what shows it).
    private func store(_ info: SharedBowlInfo) {
        if bowls[info.bowlID] != info { bowls[info.bowlID] = info }
    }

    // MARK: - Sharing

    /// The share of the bowl, made now if it is not shared yet: the bowl gets its own zone, its entries are copied
    /// into it, and the zone is shared as a whole. Hand the share to the system's sharing sheet.
    func share(_ bowl: NoteFolder) async throws -> CKShare {
        guard let database = cloud?.privateCloudDatabase, privateEngine != nil else { throw BowlSharingError.unavailable }
        let bowlID = bowl.id
        if let info = bowls[bowlID] {
            guard info.endingSince == nil else { throw BowlSharingError.ending }
            return try await fetchShare(info)
        }
        preparing.insert(bowlID)
        defer { preparing.remove(bowlID) }
        let info = SharedBowlInfo(bowlID: bowlID, role: .owner, zoneOwnerName: CKCurrentUserDefaultName, name: bowl.name)
        let zoneID = SharedBowlRecords.zoneID(info)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)

        // Shared already from another of my devices: that share is the one (a second one cannot be made).
        if let existing = try await existingShare(shareID, in: database) { return adopt(existing, info) }

        var madeZone = false
        do {
            _ = try await database.recordZone(for: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            if case .failure(let error)? = zones.saveResults[zoneID] { throw error }
            madeZone = true
        }
        do {
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = bowl.name
            share.publicPermission = .none
            let saved = try await database.modifyRecords(saving: [share], deleting: [])
            guard let result = saved.saveResults[share.recordID] else { throw BowlSharingError.notShared }
            switch result {
            case .success(let record):
                return adopt((record as? CKShare) ?? share, info)
            case .failure(let error):
                // Made at the same moment on another of my devices: that one is taken.
                if (error as? CKError)?.code == .serverRecordChanged, let existing = try await existingShare(shareID, in: database) {
                    return adopt(existing, info)
                }
                throw error
            }
        } catch {
            // Only a zone this call made is taken back; an existing one may be shared and in use.
            if madeZone { _ = try? await database.deleteRecordZone(withID: zoneID) }
            throw error
        }
    }

    private func existingShare(_ id: CKRecord.ID, in database: CKDatabase) async throws -> CKShare? {
        do {
            return try await database.record(for: id) as? CKShare
        } catch let error as CKError where [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code) {
            return nil
        }
    }

    /// The bowl is shared with this share from now on; its entries go into the zone right away.
    private func adopt(_ share: CKShare, _ fresh: SharedBowlInfo) -> CKShare {
        var info = bowls[fresh.bowlID] ?? fresh
        info.people = SharedBowlRecords.people(of: share)
        store(info)
        persist()
        scan()
        let engine = privateEngine
        Task { try? await engine?.sendChanges() }
        return share
    }

    /// The share of a shared bowl as the server has it now; also brings the people of it up to date.
    func fetchShare(_ info: SharedBowlInfo) async throws -> CKShare {
        guard let database = database(for: info.role) else { throw BowlSharingError.unavailable }
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: SharedBowlRecords.zoneID(info))
        guard let share = try await database.record(for: id) as? CKShare else { throw BowlSharingError.notShared }
        updatePeople(info.bowlID, SharedBowlRecords.people(of: share))
        return share
    }

    /// The people of every shared bowl, from the server (who joined, who left). Only a zone the server says is gone
    /// ends a share here; a missing share alone never does (another of my devices may be making it right now).
    func refreshPeople() async {
        for info in bowls.values where info.endingSince == nil {
            do {
                _ = try await fetchShare(info)
            } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {
                if let current = bowls[info.bowlID], current.endingSince == nil { end(current) }
            } catch {
                // No share (yet), offline, or another passing failure: asked again the next time.
            }
        }
    }

    private func updatePeople(_ bowlID: UUID, _ people: [SharedBowlPerson]) {
        guard var info = bowls[bowlID], info.people != people else { return }
        info.people = people
        store(info)
        persist()
    }

    // MARK: - Stopping and leaving

    /// Mine: nobody else sees the bowl any more. Its entries stay here as they are. The bowl counts as shared until
    /// the server confirmed it; if it cannot be reached now, it is tried again and the error says so.
    func stopSharing(_ bowlID: UUID) async throws {
        guard let info = bowls[bowlID], info.role == .owner else { return }
        try await deleteZone(of: beginEnding(info))
    }

    /// Shared with me: I leave it, and the copies of its entries are removed from my devices (what I made myself
    /// goes to my inbox). The owner keeps everything.
    func leave(_ bowlID: UUID) async throws {
        guard let info = bowls[bowlID], info.role == .participant else { return }
        try await deleteZone(of: beginEnding(info))
    }

    /// The bowl is being deleted here: its sharing ends first (and is tried again until it did), so its entries do
    /// not leave the zone one by one while the bowl is taken apart.
    func bowlWillBeDeleted(_ bowlID: UUID) {
        guard let info = bowls[bowlID] else { return }
        let ending = beginEnding(info)
        Task { try? await deleteZone(of: ending) }
    }

    /// From now on nothing is sent or taken for the bowl: its pending changes are dropped.
    private func beginEnding(_ original: SharedBowlInfo) -> SharedBowlInfo {
        var info = original
        if info.endingSince == nil { info.endingSince = Date() }
        dropPending(info)
        store(info)
        persist()
        return info
    }

    /// Deletes the bowl's zone (mine) or leaves it (someone else's). Only once the server confirmed it (or the zone
    /// is gone already) is the share forgotten here.
    private func deleteZone(of info: SharedBowlInfo) async throws {
        guard let database = database(for: info.role) else { throw BowlSharingError.unavailable }
        endingRunning.insert(info.bowlID)
        endingAttempts[info.bowlID] = Date()
        defer { endingRunning.remove(info.bowlID) }
        do {
            _ = try await database.deleteRecordZone(withID: SharedBowlRecords.zoneID(info))
        } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {
            // Gone already.
        } catch {
            throw info.role == .owner
                ? BowlSharingError.stopPending(error.localizedDescription)
                : BowlSharingError.leavePending(error.localizedDescription)
        }
        if let current = bowls[info.bowlID] { end(current) }
    }

    /// Zone deletions that did not go through yet are tried again (at launch, then at most once a minute).
    private func retryEndings() {
        let now = Date()
        for info in bowls.values where info.endingSince != nil && !endingRunning.contains(info.bowlID) {
            if let last = endingAttempts[info.bowlID], now.timeIntervalSince(last) < 60 { continue }
            Task { try? await deleteZone(of: info) }
        }
    }

    private func dropPending(_ info: SharedBowlInfo) {
        guard let engine = engine(for: info.role) else { return }
        let zoneID = SharedBowlRecords.zoneID(info)
        let pending = engine.state.pendingRecordZoneChanges.filter { change in
            switch change {
            case .saveRecord(let id), .deleteRecord(let id): id.zoneID == zoneID
            @unknown default: false
            }
        }
        if !pending.isEmpty { engine.state.remove(pendingRecordZoneChanges: pending) }
    }

    /// The share ended (stopped, left, or gone on the server): it is forgotten here and nothing more is sent for it.
    /// Of a bowl shared with me, the copies go (`SharedBowlMerge.shareEnd`).
    private func end(_ info: SharedBowlInfo) {
        bowls[info.bowlID] = nil
        dropPending(info)
        removeLocalCopy(info)
        persist()
    }

    private func removeLocalCopy(_ info: SharedBowlInfo) {
        guard info.role == .participant, let context else { return }
        let key = SharedBowlNames.bowlKey(info.bowlID)
        for note in (try? context.fetch(FetchDescriptor<Note>())) ?? [] where note.projectIDs.contains(key) {
            switch SharedBowlMerge.shareEnd(role: info.role, isCopy: note.shareCopyToken != nil) {
            case .deleteCopy: context.delete(note)
            case .moveToInbox: note.projectIDs.removeAll { $0 == key }
            case .none: break
            }
        }
        let bowlID = info.bowlID
        for folder in (try? context.fetch(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == bowlID }))) ?? []
        where folder.shareCopyToken != nil {
            context.delete(folder)
        }
        try? context.save()
    }

    // MARK: - Accepting

    /// Someone's invitation was opened (a link in Messages or Mail): the bowl joins the list.
    func accept(_ metadata: CKShare.Metadata) async {
        guard Self.isAvailable else {
            notice = String(localized: "To open bowls others share with you, turn on iCloud Sync in Settings › General.")
            return
        }
        guard let cloud, let sharedEngine else {
            waitingShares.append(metadata)
            return
        }
        guard metadata.containerIdentifier == AudioStore.containerIdentifier else { return }
        // My own bowl's link: it is in the list already.
        guard metadata.participantRole != .owner else { return }
        do {
            _ = try await cloud.accept(metadata)
            let zoneID = metadata.share.recordID.zoneID
            if let bowlID = SharedBowlNames.bowlID(fromZoneName: zoneID.zoneName), bowls[bowlID] == nil {
                let title = (metadata.share[CKShare.SystemFieldKey.title] as? String) ?? ""
                var info = SharedBowlInfo(bowlID: bowlID, role: .participant, zoneOwnerName: zoneID.ownerName, name: title)
                info.people = SharedBowlRecords.people(of: metadata.share)
                store(info)
                persist()
            }
            try await sharedEngine.fetchChanges()
        } catch {
            notice = String(localized: "The shared bowl could not be opened. \(error.localizedDescription)")
        }
    }

    // MARK: - Looking for changes in the store

    func scanSoon(after delay: Duration = .seconds(2)) {
        guard modelContainer != nil, !bowls.isEmpty else { return }
        scanTask?.cancel()
        scanTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            scan()
        }
    }

    /// Works out for every shared bowl what has to be sent (`SharedBowlPlanner`) and hands it to its engine; takes out
    /// of the bowl what the zone dropped once the private sync spoke; and keeps one of every entry that is in the
    /// store twice.
    private func scan() {
        guard let context, !bowls.isEmpty else { return }
        retryEndings()
        var notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let folders = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        var changed = false
        var removed = Set<ObjectIdentifier>()
        for (bowlID, original) in bowls where original.endingSince == nil {
            var info = original
            let key = SharedBowlNames.bowlKey(bowlID)
            let bowlFolders = folders.filter { $0.id == bowlID }
            for extra in SharedBowlMerge.duplicatesToDelete(bowlFolders, token: \.shareCopyToken) {
                context.delete(extra)
                removed.insert(ObjectIdentifier(extra))
                changed = true
            }
            let inBowl = notes.filter { $0.projectIDs.contains(key) }
            for group in Dictionary(grouping: inBowl, by: \.id).values where group.count > 1 {
                for extra in SharedBowlMerge.duplicatesToDelete(group, token: \.shareCopyToken) {
                    context.delete(extra)
                    removed.insert(ObjectIdentifier(extra))
                    changed = true
                }
            }
            // What the zone dropped leaves the bowl (to the inbox) once the private sync brought something newer.
            // Its last change stays, so a move another of my devices made (and that is still on its way) wins.
            for id in SharedBowlMerge.dueRemovals(info.pendingRemovals, lastImport: lastImport) {
                info.pendingRemovals[id] = nil
                guard info.noteHashes[id] == nil else { continue }
                for note in inBowl where note.id.uuidString == id && !removed.contains(ObjectIdentifier(note)) {
                    if SharedBowlMerge.removal(isInBowl: note.projectIDs.contains(key)) == .moveToInbox {
                        note.projectIDs.removeAll { $0 == key }
                        changed = true
                    }
                }
            }
            notes.removeAll { removed.contains(ObjectIdentifier($0)) }
            let folder = bowlFolders.first { !removed.contains(ObjectIdentifier($0)) }
            if let folder, info.name != folder.name { info.name = folder.name }
            // The bowl is not in the store (yet, on a device the private sync has not reached): nothing is sent.
            if let folder {
                let kinds = Self.fileKinds(notes.filter { $0.projectIDs.contains(key) })
                let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: folder.name, info: info, notes: notes) { name in
                    AudioStore.exists(name, kind: kinds[name] ?? .recording)
                }
                if !plan.fileOwners.isEmpty {
                    info.fileOwners = (info.fileOwners ?? [:]).merging(plan.fileOwners) { _, new in new }
                }
                enqueue(plan, info: info)
                for name in plan.filesToDownload where !downloading.contains(name) && AudioStore.isInCloud(name, kind: kinds[name] ?? .recording) {
                    downloading.insert(name)
                    let kind = kinds[name] ?? .recording
                    Task {
                        _ = try? await AudioStore.download(name, kind: kind)
                        downloading.remove(name)
                        scanSoon()
                    }
                }
            }
            store(info)
        }
        if changed { try? context.save() }
        persist()
    }

    /// Which store folder each file of the notes is in.
    private static func fileKinds(_ notes: [Note]) -> [String: StoredFileKind] {
        var kinds: [String: StoredFileKind] = [:]
        for note in notes {
            for name in [note.audioFileName, note.pendingAudioFileName].compactMap({ $0 }) + note.audioFileNames { kinds[name] = .recording }
            for attachment in note.attachments { kinds[attachment.fileName] = .attachment }
        }
        return kinds
    }

    private func enqueue(_ plan: SharedBowlOutgoing, info: SharedBowlInfo) {
        guard !plan.isEmpty, let engine = engine(for: info.role) else { return }
        let zoneID = SharedBowlRecords.zoneID(info)
        func id(_ kind: SharedBowlNames.RecordKind) -> CKRecord.ID { SharedBowlRecords.recordID(kind, in: zoneID) }
        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        if plan.saveBowl { changes.append(.saveRecord(id(.bowl))) }
        changes += plan.noteSaves.map { .saveRecord(id(.note($0))) }
        changes += plan.fileSaves.map { .saveRecord(id(.file($0))) }
        changes += plan.noteDeletes.map { .deleteRecord(id(.note($0))) }
        changes += plan.fileDeletes.map { .deleteRecord(id(.file($0))) }
        let pending = Set(engine.state.pendingRecordZoneChanges)
        let new = changes.filter { change in
            guard !pending.contains(change) else { return false }
            if case .saveRecord(let id) = change { return inFlight[Self.flightKey(id)] == nil }
            return true
        }
        if !new.isEmpty { engine.state.add(pendingRecordZoneChanges: new) }
    }

    private static func flightKey(_ id: CKRecord.ID) -> String {
        "\(id.zoneID.ownerName)/\(id.zoneID.zoneName)/\(id.recordName)"
    }

    // MARK: - Sending

    /// The record to send for a pending save, made from the store as it is now; nil when there is nothing to send
    /// (the note left the bowl, a file is not readable here), and the pending save is dropped.
    func record(for id: CKRecord.ID) -> CKRecord? {
        guard let record = makeRecord(for: id) else {
            let engines = [privateEngine, sharedEngine].compactMap { $0 }
            Task { @MainActor in engines.forEach { $0.state.remove(pendingRecordZoneChanges: [.saveRecord(id)]) } }
            return nil
        }
        return record
    }

    private func makeRecord(for id: CKRecord.ID) -> CKRecord? {
        guard let context, let bowlID = SharedBowlNames.bowlID(fromZoneName: id.zoneID.zoneName), let info = bowls[bowlID],
              info.endingSince == nil, let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { return nil }
        let key = SharedBowlNames.bowlKey(bowlID)
        let record = SharedBowlRecords.base(kind, id: id, systemFields: info.systemFields[id.recordName])
        switch kind {
        case .bowl:
            guard let folder = (try? context.fetch(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == bowlID })))?.first else { return nil }
            SharedBowlRecords.fillBowl(record, bowlID: bowlID, name: folder.name)
            inFlight[Self.flightKey(id)] = SharedBowlNames.bowlFingerprint(name: folder.name)
        case .note(let noteID):
            let matches = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID }))) ?? []
            guard let note = matches.first(where: { $0.projectIDs.contains(key) }), SharedBowlPlanner.isSendable(note),
                  let written = SharedBowlRecords.fillNote(record, payload: SharedNotePayload(note), temporaryDirectory: temporaryDirectory)
            else { return nil }
            inFlight[Self.flightKey(id)] = written
        case .file(let name):
            let notes = ((try? context.fetch(FetchDescriptor<Note>())) ?? []).filter { $0.projectIDs.contains(key) }
            let kind = Self.fileKinds(notes)[name] ?? .recording
            let url: URL
            switch AudioStore.state(of: name, kind: kind) {
            case .local(let found), .downloaded(let found): url = found
            default: return nil
            }
            SharedBowlRecords.fillFile(record, fileName: name, kind: kind, url: url)
        }
        return record
    }

    // MARK: - Events of the engines

    func handle(_ event: CKSyncEngine.Event, scope: CKDatabase.Scope, from engine: CKSyncEngine) {
        guard isCurrent(engine, scope: scope) else { return }
        switch event {
        case .stateUpdate(let update):
            if scope == .private { engineStates.private = update.stateSerialization } else { engineStates.shared = update.stateSerialization }
            persist()
        case .accountChange(let change):
            accountChanged(change)
        case .fetchedDatabaseChanges(let changes):
            databaseChanged(changes, scope: scope)
        case .fetchedRecordZoneChanges(let changes):
            apply(changes, scope: scope)
        case .sentRecordZoneChanges(let sent):
            handleSent(sent, scope: scope)
        case .didFetchChanges:
            scanSoon()
        default:
            break
        }
    }

    /// Signed out or another account: what this device knew of shares was the other account's. It is forgotten; the
    /// entries stay in the store as they are.
    private func accountChanged(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn:
            break
        case .signOut, .switchAccounts:
            bowls = [:]
            inFlight = [:]
            engineStates = (nil, nil)
            makeEngines()
            persist()
        @unknown default:
            break
        }
    }

    /// The only places a share becomes known here are this one (a zone of mine, or one accepted on another of my
    /// devices) and `accept`.
    private func databaseChanged(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges, scope: CKDatabase.Scope) {
        var learned = false
        for modification in changes.modifications {
            let zoneID = modification.zoneID
            guard let bowlID = SharedBowlNames.bowlID(fromZoneName: zoneID.zoneName), bowls[bowlID] == nil else { continue }
            store(SharedBowlInfo(bowlID: bowlID, role: scope == .private ? .owner : .participant, zoneOwnerName: zoneID.ownerName))
            learned = true
        }
        for deletion in changes.deletions {
            guard let bowlID = SharedBowlNames.bowlID(fromZoneName: deletion.zoneID.zoneName), let info = bowls[bowlID],
                  (scope == .private) == (info.role == .owner) else { continue }
            // Stopped on another of my devices, or the owner stopped sharing, or I left on another device.
            end(info)
        }
        persist()
        if learned { Task { await refreshPeople() } }
    }

    /// The bowl a record of a zone belongs to, if this device follows that share (and it is not ending).
    private func followed(_ zoneID: CKRecordZone.ID) -> SharedBowlInfo? {
        guard let bowlID = SharedBowlNames.bowlID(fromZoneName: zoneID.zoneName), let info = bowls[bowlID],
              info.endingSince == nil, info.zoneOwnerName == zoneID.ownerName else { return nil }
        return info
    }

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, scope: CKDatabase.Scope) {
        guard let context else { return }
        for modification in changes.modifications {
            let record = modification.record
            guard var info = followed(record.recordID.zoneID) else { continue }
            if let share = record as? CKShare {
                info.people = SharedBowlRecords.people(of: share)
                store(info)
                continue
            }
            guard let kind = SharedBowlNames.kind(ofRecordName: record.recordID.recordName) else { continue }
            var taken = true
            switch kind {
            case .bowl: applyBowl(record, info: &info, in: context)
            case .note(let id): taken = applyNote(record, id: id, info: &info, in: context)
            case .file(let name): applyFile(record, name: name, info: &info)
            }
            // A record that could not be read keeps the old system fields: a change sent on top of it would replace
            // what it holds without anyone having seen it.
            if taken { info.systemFields[record.recordID.recordName] = SharedBowlRecords.systemFields(of: record) }
            store(info)
        }
        for deletion in changes.deletions {
            guard var info = followed(deletion.recordID.zoneID) else { continue }
            recordWasDeleted(deletion.recordID, info: &info, in: context)
            store(info)
        }
        try? context.save()
        persist()
    }

    /// A record left the zone (someone deleted it): what this device knew of it goes; a note still in the bowl here
    /// waits to be moved to the inbox (`scan`).
    private func recordWasDeleted(_ id: CKRecord.ID, info: inout SharedBowlInfo, in context: ModelContext) {
        guard let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { return }
        info.systemFields[id.recordName] = nil
        switch kind {
        case .note(let noteID):
            let key = noteID.uuidString
            info.noteHashes[key] = nil
            info.unreadNotes?.remove(key)
            let bowlKey = SharedBowlNames.bowlKey(info.bowlID)
            let local = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID }))) ?? []
            if local.contains(where: { $0.projectIDs.contains(bowlKey) }) { info.pendingRemovals[key] = Date() }
        case .file(let name):
            info.fileNames.remove(name)
            info.fileOwners?[name] = nil
        case .bowl:
            info.bowlHash = nil
        }
    }

    private func applyBowl(_ record: CKRecord, info: inout SharedBowlInfo, in context: ModelContext) {
        let name = SharedBowlRecords.bowlName(of: record)
        let bowlID = info.bowlID
        let folders = (try? context.fetch(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == bowlID }))) ?? []
        let hadHash = info.bowlHash
        info.bowlHash = SharedBowlNames.bowlFingerprint(name: name)
        if !name.isEmpty { info.name = name }
        if folders.isEmpty {
            // The owner's own bowl comes through the private sync, never as a copy.
            guard info.role == .participant else { return }
            let folder = NoteFolder(name: name.isEmpty ? String(localized: "Shared Bowl") : name)
            folder.id = bowlID
            folder.shareCopyToken = UUID().uuidString
            context.insert(folder)
            return
        }
        for folder in folders where !name.isEmpty && folder.name != name {
            // Renamed here and not sent yet: the name here stays (and is sent).
            if let hadHash, SharedBowlNames.bowlFingerprint(name: folder.name) != hadHash { continue }
            folder.name = name
            folder.updatedAt = Date()
        }
    }

    /// Writes a note of the zone into the store. Returns false when its record could not be read (then nothing of
    /// it is known here, and no file leaves the zone until it is).
    @discardableResult
    private func applyNote(_ record: CKRecord, id: UUID, info: inout SharedBowlInfo, in context: ModelContext) -> Bool {
        let key = id.uuidString
        guard let payload = SharedBowlRecords.payload(of: record), payload.id == id else {
            info.unreadNotes = (info.unreadNotes ?? []).union([key])
            return false
        }
        info.unreadNotes?.remove(key)
        if info.unreadNotes?.isEmpty == true { info.unreadNotes = nil }
        let bowlKey = SharedBowlNames.bowlKey(info.bowlID)
        var matches = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id }))) ?? []
        for extra in SharedBowlMerge.duplicatesToDelete(matches, token: \.shareCopyToken) {
            context.delete(extra)
            matches.removeAll { $0 === extra }
        }
        let local = matches.first
        let createdByMe = record.creatorUserRecordID.map { $0.recordName == CKCurrentUserDefaultName } ?? true
        let decision = SharedBowlMerge.decide(
            local: local, isInBowl: local?.projectIDs.contains(bowlKey) ?? false, lastSynced: info.noteHashes[key],
            incoming: payload, mayInsert: SharedBowlMerge.mayInsert(role: info.role, createdByMe: createdByMe)
        )
        switch decision {
        case .insert:
            let note = Note()
            payload.apply(to: note, bowlKey: bowlKey)
            note.shareCopyToken = UUID().uuidString
            context.insert(note)
        case .apply:
            if let local, SharedNotePayload(local).fingerprint != payload.fingerprint || local.projectIDs != [bowlKey] {
                payload.apply(to: local, bowlKey: bowlKey)
            }
        case .keepLocal, .keepOut:
            break
        case .skip:
            // Not here (yet): nothing is known of it here, so nothing is sent or deleted for it.
            return true
        }
        info.noteHashes[key] = payload.fingerprint
        info.pendingRemovals[key] = nil
        if !payload.fileNames.isEmpty {
            var owners = info.fileOwners ?? [:]
            for file in payload.fileNames { owners[file] = key }
            info.fileOwners = owners
        }
        return true
    }

    private func applyFile(_ record: CKRecord, name: String, info: inout SharedBowlInfo) {
        let kind = SharedBowlRecords.fileKind(of: record)
        if !AudioStore.isObtainable(name, kind: kind), let source = SharedBowlRecords.fileURL(of: record) {
            try? FileManager.default.copyItem(at: source, to: AudioStore.localURL(for: name))
        }
        info.fileNames.insert(name)
    }

    private func handleSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, scope: CKDatabase.Scope) {
        guard let context else { return }
        var again: [CKSyncEngine.PendingRecordZoneChange] = []
        for record in sent.savedRecords {
            let id = record.recordID
            let sentPrint = inFlight.removeValue(forKey: Self.flightKey(id))
            guard var info = followed(id.zoneID), let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { continue }
            info.systemFields[id.recordName] = SharedBowlRecords.systemFields(of: record)
            switch kind {
            case .bowl: if let sentPrint { info.bowlHash = sentPrint }
            case .note(let noteID): if let sentPrint { info.noteHashes[noteID.uuidString] = sentPrint }
            case .file(let name): info.fileNames.insert(name)
            }
            store(info)
        }
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            inFlight[Self.flightKey(id)] = nil
            guard var info = followed(id.zoneID), let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else {
                if failure.error.code == .zoneNotFound || failure.error.code == .userDeletedZone,
                   let bowlID = SharedBowlNames.bowlID(fromZoneName: id.zoneID.zoneName), let info = bowls[bowlID], info.endingSince == nil {
                    end(info)
                }
                continue
            }
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone else changed it first: the later change wins (`SharedBowlMerge`).
                guard let server = failure.error.serverRecord else { break }
                switch kind {
                case .bowl:
                    applyBowl(server, info: &info, in: context)
                    info.systemFields[id.recordName] = SharedBowlRecords.systemFields(of: server)
                    let bowlID = info.bowlID
                    let folder = (try? context.fetch(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == bowlID })))?.first
                    if let folder, SharedBowlNames.bowlFingerprint(name: folder.name) != info.bowlHash { again.append(.saveRecord(id)) }
                case .note(let noteID):
                    if applyNote(server, id: noteID, info: &info, in: context) {
                        info.systemFields[id.recordName] = SharedBowlRecords.systemFields(of: server)
                        // The change here was the later one and stayed: it goes on top of the server's version.
                        if localDiffers(noteID, from: info, in: context) { again.append(.saveRecord(id)) }
                    } else {
                        // The server's version is in a file the error did not bring: it is fetched whole first.
                        refetch(id, scope: scope)
                    }
                case .file(let name):
                    info.fileNames.insert(name)
                    info.systemFields[id.recordName] = SharedBowlRecords.systemFields(of: server)
                }
            case .zoneNotFound, .userDeletedZone:
                end(info)
                continue
            case .unknownItem:
                // Deleted on the server meanwhile: that is someone's removal, not something to bring back.
                switch kind {
                case .bowl:
                    info.systemFields[id.recordName] = nil
                    again.append(.saveRecord(id))
                case .note, .file:
                    recordWasDeleted(id, info: &info, in: context)
                }
            default:
                // Passing failures (network, busy server, rate limits) are tried again by the engine itself.
                print("[sharing] could not save \(id.recordName): \(failure.error)")
            }
            store(info)
        }
        let deleted = sent.deletedRecordIDs + sent.failedRecordDeletes.filter { $0.value.code == .unknownItem }.map(\.key)
        for id in deleted {
            guard var info = followed(id.zoneID), let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { continue }
            info.systemFields[id.recordName] = nil
            switch kind {
            case .note(let noteID): info.noteHashes[noteID.uuidString] = nil
            case .file(let name):
                info.fileNames.remove(name)
                info.fileOwners?[name] = nil
            case .bowl: break
            }
            store(info)
        }
        for (id, error) in sent.failedRecordDeletes where [.zoneNotFound, .userDeletedZone].contains(error.code) {
            if let info = followed(id.zoneID) { end(info) }
        }
        if !again.isEmpty { engine(for: scope)?.state.add(pendingRecordZoneChanges: again) }
        try? context.save()
        persist()
        // Changes made while their record was on its way were skipped then: they go now.
        scanSoon()
    }

    private func localDiffers(_ noteID: UUID, from info: SharedBowlInfo, in context: ModelContext) -> Bool {
        let key = SharedBowlNames.bowlKey(info.bowlID)
        let local = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })))?.first { $0.projectIDs.contains(key) }
        guard let local else { return false }
        return SharedNotePayload(local).fingerprint != info.noteHashes[noteID.uuidString]
    }

    /// Fetches a record whole (with its files) to settle a conflict, then merges it like a fetched change.
    private func refetch(_ id: CKRecord.ID, scope: CKDatabase.Scope) {
        let key = Self.flightKey(id)
        guard !refetching.contains(key), let database = engine(for: scope)?.database else { return }
        refetching.insert(key)
        Task {
            defer { refetching.remove(key) }
            guard let record = try? await database.record(for: id), let context,
                  var info = followed(id.zoneID), case .note(let noteID)? = SharedBowlNames.kind(ofRecordName: id.recordName) else { return }
            guard applyNote(record, id: noteID, info: &info, in: context) else { return }
            info.systemFields[id.recordName] = SharedBowlRecords.systemFields(of: record)
            if localDiffers(noteID, from: info, in: context) { engine(for: scope)?.state.add(pendingRecordZoneChanges: [.saveRecord(id)]) }
            store(info)
            try? context.save()
            persist()
        }
    }

    // MARK: - Saving what this device knows

    private func persist() {
        guard let store else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            let saved = SharedBowlStore.Saved(
                bowls: bowls.values.sorted { $0.bowlID.uuidString < $1.bowlID.uuidString },
                privateEngine: engineStates.private, sharedEngine: engineStates.shared
            )
            store.save(saved)
        }
    }
}

/// Hands the events of a sync engine to `BowlSharing`, on the main actor. Events of an engine that was replaced
/// (after an account change) are dropped there.
final class SharingEngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    let scope: CKDatabase.Scope

    init(scope: CKDatabase.Scope) {
        self.scope = scope
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let scope = scope
        await MainActor.run { BowlSharing.shared.handle(event, scope: scope, from: syncEngine) }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = scope
        guard await MainActor.run(body: { BowlSharing.shared.isCurrent(syncEngine, scope: scope) }) else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !pending.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await MainActor.run { BowlSharing.shared.record(for: id) }
        }
    }

    /// The private database holds SwiftData's zone too: its records are never fetched here.
    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        if scope == .private, options.scope == .all {
            options.scope = .allExcluding([CKRecordZone.ID(zoneName: SharedBowlRecords.coreDataZoneName, ownerName: CKCurrentUserDefaultName)])
        }
        return options
    }
}
