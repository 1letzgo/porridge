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

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Sharing needs iCloud Sync. Turn it on in Settings › General.")
        case .notShared: String(localized: "This bowl is not shared any more.")
        }
    }
}

/// Shares bowls with other iCloud users (see `SharedBowlModel.swift` for the design).
///
/// Two `CKSyncEngine`s: one on the private database for the bowls I share (their zones are mine), one on the shared
/// database for the bowls shared with me. Changes in the store are looked for after each save (`scan`): what differs
/// from what the zone has is sent; what the zones bring is written into the store. Only with iCloud sync on.
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
        for name in [ModelContext.didSave, Notification.Name.NSPersistentStoreRemoteChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { BowlSharing.shared.scanSoon() }
            })
        }
        let waiting = waitingShares
        waitingShares = []
        for metadata in waiting { Task { await accept(metadata) } }
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

    private var context: ModelContext? { modelContainer?.mainContext }

    // MARK: - Sharing, stopping, leaving

    /// The share of the bowl, made now if it is not shared yet: the bowl gets its own zone, its entries are copied
    /// into it, and the zone is shared as a whole. Hand the share to the system's sharing sheet.
    func share(_ bowl: NoteFolder) async throws -> CKShare {
        guard let cloud, privateEngine != nil else { throw BowlSharingError.unavailable }
        let bowlID = bowl.id
        if let info = bowls[bowlID] { return try await fetchShare(info) }
        preparing.insert(bowlID)
        defer { preparing.remove(bowlID) }
        let info = SharedBowlInfo(bowlID: bowlID, role: .owner, zoneOwnerName: CKCurrentUserDefaultName, name: bowl.name)
        let zoneID = SharedBowlRecords.zoneID(info)
        let database = cloud.privateCloudDatabase
        let zones = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        if case .failure(let error)? = zones.saveResults[zoneID] { throw error }
        do {
            let share = CKShare(recordZoneID: zoneID)
            share[CKShare.SystemFieldKey.title] = bowl.name
            share.publicPermission = .none
            let saved = try await database.modifyRecords(saving: [share], deleting: [])
            guard let result = saved.saveResults[share.recordID] else { throw BowlSharingError.notShared }
            let savedShare = (try result.get() as? CKShare) ?? share
            var shared = info
            shared.people = SharedBowlRecords.people(of: savedShare)
            bowls[bowlID] = shared
            persist()
            // The bowl and its entries go into the zone right away, before anyone joins.
            scan()
            Task { try? await privateEngine?.sendChanges() }
            return savedShare
        } catch {
            _ = try? await database.deleteRecordZone(withID: zoneID)
            throw error
        }
    }

    /// The share of a shared bowl as the server has it now; also brings the people of it up to date.
    func fetchShare(_ info: SharedBowlInfo) async throws -> CKShare {
        guard let cloud else { throw BowlSharingError.unavailable }
        let database = info.role == .owner ? cloud.privateCloudDatabase : cloud.sharedCloudDatabase
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: SharedBowlRecords.zoneID(info))
        guard let share = try await database.record(for: id) as? CKShare else { throw BowlSharingError.notShared }
        updatePeople(info.bowlID, SharedBowlRecords.people(of: share))
        return share
    }

    /// The people of every shared bowl, from the server (who joined, who left).
    func refreshPeople() async {
        for info in bowls.values {
            do {
                _ = try await fetchShare(info)
            } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {
                end(info)
            } catch let error as CKError where error.code == .unknownItem && info.role == .owner {
                // The share was stopped (from the system's sheet on another device): the zone goes too.
                try? await stopSharing(info.bowlID)
            } catch {
                // Offline or another passing failure: the next time.
            }
        }
    }

    private func updatePeople(_ bowlID: UUID, _ people: [SharedBowlPerson]) {
        guard var info = bowls[bowlID], info.people != people else { return }
        info.people = people
        bowls[bowlID] = info
        persist()
    }

    /// Mine: nobody else sees the bowl any more. Its entries stay here as they are.
    func stopSharing(_ bowlID: UUID) async throws {
        guard let info = bowls[bowlID], info.role == .owner else { return }
        end(info)
        guard let cloud else { return }
        do {
            _ = try await cloud.privateCloudDatabase.deleteRecordZone(withID: SharedBowlRecords.zoneID(info))
        } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {}
    }

    /// Shared with me: I leave it, and its entries are removed from my devices. The owner keeps them.
    func leave(_ bowlID: UUID) async throws {
        guard let info = bowls[bowlID], info.role == .participant else { return }
        if let cloud {
            do {
                _ = try await cloud.sharedCloudDatabase.deleteRecordZone(withID: SharedBowlRecords.zoneID(info))
            } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {}
        }
        end(info)
    }

    /// The bowl is being deleted here: mine stops being shared first, so its entries do not leave the zone one by one.
    func bowlWillBeDeleted(_ bowlID: UUID) {
        guard let info = bowls[bowlID] else { return }
        end(info, removingCopy: false)
        guard let cloud else { return }
        let database = info.role == .owner ? cloud.privateCloudDatabase : cloud.sharedCloudDatabase
        Task { _ = try? await database.deleteRecordZone(withID: SharedBowlRecords.zoneID(info)) }
    }

    /// The share ended (stopped, left, or gone on the server): it is forgotten here, nothing more is sent for it, and
    /// my copy of someone else's bowl goes.
    private func end(_ info: SharedBowlInfo, removingCopy: Bool = true) {
        bowls[info.bowlID] = nil
        if let engine = engine(for: info.role) {
            let zoneID = SharedBowlRecords.zoneID(info)
            let pending = engine.state.pendingRecordZoneChanges.filter { change in
                switch change {
                case .saveRecord(let id), .deleteRecord(let id): id.zoneID == zoneID
                @unknown default: false
                }
            }
            if !pending.isEmpty { engine.state.remove(pendingRecordZoneChanges: pending) }
        }
        if removingCopy, !SharedBowlMerge.keepsLocalCopy(role: info.role) { removeLocalCopy(info) }
        persist()
    }

    private func removeLocalCopy(_ info: SharedBowlInfo) {
        guard let context else { return }
        let key = SharedBowlNames.bowlKey(info.bowlID)
        for note in (try? context.fetch(FetchDescriptor<Note>())) ?? [] where note.projectIDs.contains(key) {
            note.storedFileNames.forEach(AudioStore.delete)
            context.delete(note)
        }
        let bowlID = info.bowlID
        for folder in (try? context.fetch(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == bowlID }))) ?? [] {
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
                bowls[bowlID] = info
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
    /// what the zone dropped a while ago; and keeps one of every entry that is in the store twice.
    private func scan() {
        guard let context, !bowls.isEmpty else { return }
        var notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let folders = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        var changed = false
        var removed = Set<ObjectIdentifier>()
        let now = Date()
        for (bowlID, original) in bowls {
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
            for id in SharedBowlMerge.dueRemovals(info.pendingRemovals, now: now) {
                info.pendingRemovals[id] = nil
                guard info.noteHashes[id] == nil else { continue }
                for note in inBowl where note.id.uuidString == id && !removed.contains(ObjectIdentifier(note)) {
                    switch SharedBowlMerge.removal(role: info.role, isInBowl: true) {
                    case .none: break
                    case .moveToInbox:
                        note.projectIDs = []
                        note.updatedAt = Date()
                    case .delete:
                        note.storedFileNames.forEach(AudioStore.delete)
                        context.delete(note)
                        removed.insert(ObjectIdentifier(note))
                    }
                    changed = true
                }
            }
            notes.removeAll { removed.contains(ObjectIdentifier($0)) }
            let folder = bowlFolders.first { !removed.contains(ObjectIdentifier($0)) }
            if let folder, info.name != folder.name { info.name = folder.name }
            bowls[bowlID] = info
            // The bowl is not in the store (yet, on a device the private sync has not reached): nothing is sent.
            guard let folder else { continue }
            let kinds = Self.fileKinds(notes.filter { $0.projectIDs.contains(key) })
            let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: folder.name, info: info, notes: notes) { name in
                AudioStore.exists(name, kind: kinds[name] ?? .recording)
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
              let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { return nil }
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

    func handle(_ event: CKSyncEngine.Event, scope: CKDatabase.Scope) {
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

    private func databaseChanged(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges, scope: CKDatabase.Scope) {
        var learned = false
        for modification in changes.modifications {
            let zoneID = modification.zoneID
            guard let bowlID = SharedBowlNames.bowlID(fromZoneName: zoneID.zoneName), bowls[bowlID] == nil else { continue }
            // Mine, shared from another of my devices; or someone else's, accepted on another of my devices.
            bowls[bowlID] = SharedBowlInfo(bowlID: bowlID, role: scope == .private ? .owner : .participant, zoneOwnerName: zoneID.ownerName)
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

    private func apply(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, scope: CKDatabase.Scope) {
        guard let context else { return }
        for modification in changes.modifications {
            let record = modification.record
            let zoneID = record.recordID.zoneID
            guard let bowlID = SharedBowlNames.bowlID(fromZoneName: zoneID.zoneName) else { continue }
            let role: SharedBowlRole = scope == .private ? .owner : .participant
            var info = bowls[bowlID] ?? SharedBowlInfo(bowlID: bowlID, role: role, zoneOwnerName: zoneID.ownerName)
            if let share = record as? CKShare {
                info.people = SharedBowlRecords.people(of: share)
                bowls[bowlID] = info
                continue
            }
            guard let kind = SharedBowlNames.kind(ofRecordName: record.recordID.recordName) else { continue }
            switch kind {
            case .bowl: applyBowl(record, info: &info, in: context)
            case .note(let id): applyNote(record, id: id, info: &info, in: context)
            case .file(let name): applyFile(record, name: name, info: &info)
            }
            info.systemFields[record.recordID.recordName] = SharedBowlRecords.systemFields(of: record)
            bowls[bowlID] = info
        }
        for deletion in changes.deletions {
            let id = deletion.recordID
            guard let bowlID = SharedBowlNames.bowlID(fromZoneName: id.zoneID.zoneName), var info = bowls[bowlID],
                  let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { continue }
            info.systemFields[id.recordName] = nil
            switch kind {
            case .note(let noteID):
                let key = noteID.uuidString
                info.noteHashes[key] = nil
                let bowlKey = SharedBowlNames.bowlKey(bowlID)
                let local = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID }))) ?? []
                if local.contains(where: { $0.projectIDs.contains(bowlKey) }) { info.pendingRemovals[key] = Date() }
            case .file(let name):
                info.fileNames.remove(name)
            case .bowl:
                break
            }
            bowls[bowlID] = info
        }
        try? context.save()
        persist()
    }

    private func applyBowl(_ record: CKRecord, info: inout SharedBowlInfo, in context: ModelContext) {
        let name = SharedBowlRecords.bowlName(of: record)
        let bowlID = info.bowlID
        let folders = (try? context.fetch(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == bowlID }))) ?? []
        let hadHash = info.bowlHash
        info.bowlHash = SharedBowlNames.bowlFingerprint(name: name)
        if !name.isEmpty { info.name = name }
        if folders.isEmpty {
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

    private func applyNote(_ record: CKRecord, id: UUID, info: inout SharedBowlInfo, in context: ModelContext) {
        guard let payload = SharedBowlRecords.payload(of: record), payload.id == id else { return }
        let key = SharedBowlNames.bowlKey(info.bowlID)
        var matches = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id }))) ?? []
        for extra in SharedBowlMerge.duplicatesToDelete(matches, token: \.shareCopyToken) {
            context.delete(extra)
            matches.removeAll { $0 === extra }
        }
        let local = matches.first
        switch SharedBowlMerge.decide(local: local, lastSynced: info.noteHashes[id.uuidString], incoming: payload) {
        case .insert:
            let note = Note()
            payload.apply(to: note, bowlKey: key)
            note.shareCopyToken = UUID().uuidString
            context.insert(note)
        case .apply:
            if let local, SharedNotePayload(local) != payload || local.projectIDs != [key] {
                payload.apply(to: local, bowlKey: key)
            }
        case .keepLocal:
            break
        }
        info.noteHashes[id.uuidString] = payload.fingerprint
        info.pendingRemovals[id.uuidString] = nil
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
            guard let bowlID = SharedBowlNames.bowlID(fromZoneName: id.zoneID.zoneName), var info = bowls[bowlID],
                  let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { continue }
            info.systemFields[id.recordName] = SharedBowlRecords.systemFields(of: record)
            switch kind {
            case .bowl: if let sentPrint { info.bowlHash = sentPrint }
            case .note(let noteID): if let sentPrint { info.noteHashes[noteID.uuidString] = sentPrint }
            case .file(let name): info.fileNames.insert(name)
            }
            bowls[bowlID] = info
        }
        for failure in sent.failedRecordSaves {
            let id = failure.record.recordID
            inFlight[Self.flightKey(id)] = nil
            guard let bowlID = SharedBowlNames.bowlID(fromZoneName: id.zoneID.zoneName), var info = bowls[bowlID],
                  let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                // Someone else changed it first: the later change wins (`SharedBowlMerge`).
                guard let server = failure.error.serverRecord else { break }
                switch kind {
                case .bowl:
                    applyBowl(server, info: &info, in: context)
                    let folder = (try? context.fetch(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == bowlID })))?.first
                    if let folder, SharedBowlNames.bowlFingerprint(name: folder.name) != info.bowlHash { again.append(.saveRecord(id)) }
                case .note(let noteID):
                    applyNote(server, id: noteID, info: &info, in: context)
                    // The change here was the later one and stayed: it goes on top of the server's version.
                    let local = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == noteID })))?.first
                    if let local, SharedNotePayload(local).fingerprint != info.noteHashes[noteID.uuidString] {
                        again.append(.saveRecord(id))
                    }
                case .file(let name):
                    info.fileNames.insert(name)
                }
                info.systemFields[id.recordName] = SharedBowlRecords.systemFields(of: server)
            case .zoneNotFound, .userDeletedZone:
                end(info)
                continue
            case .unknownItem:
                // Deleted on the server meanwhile: sent again as a new record.
                info.systemFields[id.recordName] = nil
                again.append(.saveRecord(id))
            default:
                // Passing failures (network, busy server, rate limits) are tried again by the engine itself.
                print("[sharing] could not save \(id.recordName): \(failure.error)")
            }
            bowls[bowlID] = info
        }
        let deleted = sent.deletedRecordIDs + sent.failedRecordDeletes.filter { $0.value.code == .unknownItem }.map(\.key)
        for id in deleted {
            guard let bowlID = SharedBowlNames.bowlID(fromZoneName: id.zoneID.zoneName), var info = bowls[bowlID],
                  let kind = SharedBowlNames.kind(ofRecordName: id.recordName) else { continue }
            info.systemFields[id.recordName] = nil
            switch kind {
            case .note(let noteID): info.noteHashes[noteID.uuidString] = nil
            case .file(let name): info.fileNames.remove(name)
            case .bowl: break
            }
            bowls[bowlID] = info
        }
        for (id, error) in sent.failedRecordDeletes where [.zoneNotFound, .userDeletedZone].contains(error.code) {
            if let bowlID = SharedBowlNames.bowlID(fromZoneName: id.zoneID.zoneName), let info = bowls[bowlID] { end(info) }
        }
        if !again.isEmpty { engine(for: scope)?.state.add(pendingRecordZoneChanges: again) }
        try? context.save()
        persist()
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

/// Hands the events of a sync engine to `BowlSharing`, on the main actor.
final class SharingEngineDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    let scope: CKDatabase.Scope

    init(scope: CKDatabase.Scope) {
        self.scope = scope
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        let scope = scope
        await MainActor.run { BowlSharing.shared.handle(event, scope: scope) }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
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
