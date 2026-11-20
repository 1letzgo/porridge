import Foundation
import Observation
import SwiftData

/// How the data gets to the other devices. Chosen in the settings; a change takes effect at the next launch
/// (the SwiftData store is set up with or without CloudKit when the app starts).
enum SyncMode: String, CaseIterable, Identifiable {
    case off
    case iCloud = "icloud"
    case nextcloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .iCloud: "iCloud"
        case .nextcloud: "Nextcloud"
        }
    }

    static let key = "syncMode"

    /// The choice in the settings; iCloud for everyone who had the app before there was a choice.
    static var chosen: SyncMode {
        UserDefaults.standard.string(forKey: key).flatMap(SyncMode.init(rawValue:)) ?? .iCloud
    }

    /// The mode the app was started with; off on test data (`DataLocation.testFolder`).
    static let active = DataLocation.testFolder == nil ? chosen : .off
}

/// Sync through a Nextcloud: one file `Porridge/porridge-sync.json` with all notes, folders and voices,
/// read by the iPhone, the Mac and Android alike, plus the recordings in `Porridge/Recordings/`.
///
/// Every run reads the file, merges it three ways with this device (what changed on one side wins, when both
/// changed the newer edit wins, deletions travel as tombstones), writes the result into the store and puts the
/// file back only if no other device wrote it in between (ETag); otherwise it starts over.
@MainActor
@Observable
final class NextcloudSync {
    static let shared = NextcloudSync()

    private(set) var isSyncing = false
    private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "nextcloudLastSync") as? Date
    private(set) var lastError: String?
    /// The account currently connected (nil = none).
    private(set) var account: NextcloudAccount? = NextcloudAccount.saved

    private var container: ModelContainer?
    private var pending: Task<Void, Never>?
    /// Something asked for a sync while one was running: another one follows it.
    private var syncAgain = false
    private var applying = false
    /// When a run saved the store and its notification has not come yet. Only that one notification is skipped:
    /// an edit saved right after it still asks for a run.
    private var ownSaveAt: Date?
    /// Counts connecting and disconnecting: a run that sees it changed while it waited was for another account and
    /// leaves the state, the keychain and the uploads alone.
    private var generation = 0
    private var observer: NSObjectProtocol?

    private static let fileName = "porridge-sync.json"

    var isActive: Bool { SyncMode.active == .nextcloud && account != nil }

    /// Starts listening for changes; called once at launch.
    func attach(_ container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Not for the save of a run itself (whether its notification comes at once or a moment later).
                if let at = self.ownSaveAt {
                    self.ownSaveAt = nil
                    if Date().timeIntervalSince(at) < 5 { return }
                }
                guard !self.applying else { return }
                self.syncSoon()
            }
        }
        syncSoon(after: .seconds(1))
        // Now and then while the app runs (the Mac stays open for days).
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(300))
                self?.syncSoon(after: .zero)
            }
        }
    }

    func connect(_ account: NextcloudAccount) {
        generation += 1
        account.save()
        self.account = account
        State.reset()
        lastError = nil
        syncSoon(after: .zero)
    }

    func disconnect() {
        generation += 1
        Task { await RecordingUploads.shared.cancelAll() }
        NextcloudAccount.remove()
        account = nil
        State.reset()
        lastSync = nil
        lastError = nil
        UserDefaults.standard.removeObject(forKey: "nextcloudLastSync")
    }

    /// A sync a moment from now; changes in quick succession end up in one run.
    func syncSoon(after delay: Duration = .seconds(4)) {
        guard isActive else { return }
        // A run in progress stays untouched (it may be halfway through a long upload).
        if isSyncing {
            syncAgain = true
            return
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard isActive, !isSyncing, let account, let container else { return }
        isSyncing = true
        let run = generation
        defer {
            isSyncing = false
            if syncAgain {
                syncAgain = false
                syncSoon()
            }
        }
        do {
            var account = account
            if account.userID == nil, let id = await WebDAV(account: account).fetchUserID() {
                try checkAccount(run)
                account.userID = id
                account.save()
                if self.account?.loginName == account.loginName { self.account = account }
            }
            let dav = WebDAV(account: account)
            try await syncFile(dav, context: container.mainContext, generation: run)
            try await syncRecordings(dav, context: container.mainContext, generation: run)
            try checkAccount(run)
            lastSync = Date()
            lastError = nil
            UserDefaults.standard.set(lastSync, forKey: "nextcloudLastSync")
        } catch {
            // Connected or disconnected meanwhile: this run's error is not the new account's.
            if run == generation { lastError = error.localizedDescription }
        }
    }

    /// Stops a run whose account was connected or disconnected while it waited.
    private func checkAccount(_ generation: Int) throws {
        guard generation == self.generation else { throw CancellationError() }
    }

    // MARK: The file

    private struct Collection {
        let key: String
        let local: [String: SyncMerge.Local]
        let frozen: Set<String>
    }

    private func syncFile(_ dav: WebDAV, context: ModelContext, generation: Int) async throws {
        let url = dav.root.appending(path: Self.fileName)
        try checkAccount(generation)
        var state = State.load()
        for attempt in 0..<4 {
            let remote = try await dav.get(url)
            if remote == nil && attempt == 0 { try await dav.makeFolder(dav.root) }
            // The store takes nothing from an account that is no longer the one connected.
            try checkAccount(generation)
            let file = try remote.map { try SyncMerge.parseFile($0.data) } ?? [:]
            let tombstones = file["deleted"] as? [String: [String: NSNumber]] ?? [:]

            var output = file
            output["version"] = 1
            // Tasks of older versions are gone, in the file too.
            output["actionItems"] = nil
            // Starts from the file: the other platform's voices have tombstones of their own.
            var deleted = tombstones.mapValues { $0.mapValues(\.int64Value) }
            deleted["actionItems"] = nil
            var newBase: [String: [String: SyncBase]] = [:]
            var noteRecords: [String: SyncRecord] = [:]
            var frozenNotes: Set<String> = []
            var folderIDs: Set<String>?
            var filesToDelete: [String] = []
            applying = true
            defer { applying = false }
            for collection in try collections(context) {
                let remoteRecords = (file[collection.key] as? [SyncRecord] ?? []).reduce(into: [String: SyncRecord]()) { all, r in
                    if let id = r["id"] as? String { all[id] = r }
                }
                let result = SyncMerge.merge(
                    local: collection.local,
                    remote: remoteRecords,
                    tombstones: (tombstones[collection.key] ?? [:]).mapValues(\.int64Value),
                    base: state.base[collection.key] ?? [:],
                    frozen: collection.frozen,
                    now: SyncRecords.ms(Date())
                )
                filesToDelete += try apply(result, collection: collection.key, context: context)
                output[collection.key] = result.merged.keys.sorted().compactMap { result.merged[$0] }
                deleted[collection.key] = result.tombstones
                newBase[collection.key] = result.merged.reduce(into: [:]) { base, entry in
                    base[entry.key] = Self.base(of: entry.value)
                }
                switch collection.key {
                case "notes":
                    noteRecords = result.merged
                    frozenNotes = collection.frozen
                case "folders":
                    folderIDs = Set(result.merged.keys)
                default:
                    break
                }
            }
            // Only now, with every folder of this run merged, is a bucket that is not there really gone (deleted
            // on another device): notes leave it, here and in the file, instead of dropping out of every list.
            if let folderIDs {
                let notes = try context.fetch(FetchDescriptor<Note>())
                var pruned = false
                for note in Projects.pruneUnknown(notes, known: folderIDs) {
                    let id = note.id.uuidString
                    // A frozen note keeps the file's record; it goes up once it is done.
                    guard !frozenNotes.contains(id), noteRecords[id] != nil else { continue }
                    let record = SyncRecords.record(note)
                    noteRecords[id] = record
                    newBase["notes"]?[id] = Self.base(of: record)
                    pruned = true
                }
                if pruned { output["notes"] = noteRecords.keys.sorted().compactMap { noteRecords[$0] } }
            }
            output["deleted"] = deleted
            let settingsBase = mergeSettings(file, into: &output, base: state.settings ?? [:])
            if context.hasChanges {
                ownSaveAt = Date()
                do {
                    try context.save()
                } catch {
                    ownSaveAt = nil
                    throw error
                }
            }
            // The files of notes deleted elsewhere go only once their deletion is saved.
            filesToDelete.forEach(AudioStore.delete)
            // Taken before the upload: an edit made during it counts as a change in the next run. Saves from
            // here on are the user's and ask for that run.
            applying = false
            for collection in try collections(context) {
                for (id, local) in collection.local where newBase[collection.key]?[id] != nil {
                    newBase[collection.key]?[id]?.local = SyncMerge.hash(local.record)
                }
            }

            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            let before = remote == nil ? nil : try? JSONSerialization.data(withJSONObject: file, options: [.sortedKeys])
            do {
                if data != before { try await dav.put(data, to: url, ifMatch: remote?.etag) }
            } catch NextcloudError.conflict {
                continue
            }
            // Disconnected meanwhile: the state was reset and stays so.
            try checkAccount(generation)
            // Only now, with the file written, does the merged state become the base of the next run.
            state.base = newBase
            state.settings = settingsBase
            let referenced = try referencedRecordings(output["notes"] as? [SyncRecord] ?? [], context: context)
            let released = Set(state.recordings ?? []).subtracting(referenced)
            state.orphans = Set(state.orphans ?? []).union(released).subtracting(referenced).sorted()
            state.recordings = referenced.sorted()
            state.save()
            return
        }
        throw NextcloudError.conflict
    }

    /// The base of a record as it was written to the file.
    private static func base(of record: SyncRecord) -> SyncBase {
        SyncBase(local: "", remote: SyncMerge.hash(record), text: Todos.isTodoRecord(record) ? record["text"] as? String : nil)
    }

    /// This device's records of every collection in the file.
    private func collections(_ context: ModelContext) throws -> [Collection] {
        let notes = try context.fetch(FetchDescriptor<Note>())
        let folders = try context.fetch(FetchDescriptor<NoteFolder>())
        let voices = try context.fetch(FetchDescriptor<VoiceProfile>())
        func locals<T>(_ models: [T], id: (T) -> UUID, record: (T) -> SyncRecord) -> [String: SyncMerge.Local] {
            models.reduce(into: [:]) { all, model in
                let r = record(model)
                all[id(model).uuidString] = SyncMerge.Local(record: r, updatedAt: SyncMerge.int64(r["updatedAt"] ?? r["createdAt"]))
            }
        }
        return [
            Collection(key: "notes", local: locals(notes, id: \.id, record: SyncRecords.record), frozen: Set(notes.filter(SyncRecords.isFrozen).map(\.id.uuidString))),
            Collection(key: "folders", local: locals(folders, id: \.id, record: SyncRecords.record), frozen: []),
            Collection(key: "voiceProfilesApple", local: locals(voices, id: \.id, record: SyncRecords.record), frozen: []),
        ]
    }

    /// - Returns: the files of the notes deleted, to be deleted once the store is saved.
    private func apply(_ result: SyncMerge.Result, collection: String, context: ModelContext) throws -> [String] {
        guard !result.toApply.isEmpty || !result.toDelete.isEmpty else { return [] }
        var files: [String] = []
        switch collection {
        case "notes":
            let all = try context.fetch(FetchDescriptor<Note>())
            let byID = Dictionary(all.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, r) in result.toApply {
                let note = byID[id] ?? {
                    let note = Note()
                    note.id = UUID(uuidString: id) ?? UUID()
                    context.insert(note)
                    return note
                }()
                SyncRecords.apply(r, to: note)
            }
            for id in result.toDelete {
                guard let note = byID[id] else { continue }
                files += note.storedFileNames
                context.delete(note)
            }
        case "folders":
            let byID = Dictionary(try context.fetch(FetchDescriptor<NoteFolder>()).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, r) in result.toApply {
                let folder = byID[id] ?? {
                    let folder = NoteFolder(name: "")
                    folder.id = UUID(uuidString: id) ?? UUID()
                    context.insert(folder)
                    return folder
                }()
                SyncRecords.apply(r, to: folder)
            }
            for id in result.toDelete { byID[id].map(context.delete) }
        case "voiceProfilesApple":
            let byID = Dictionary(try context.fetch(FetchDescriptor<VoiceProfile>()).map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, r) in result.toApply {
                let profile = byID[id] ?? {
                    let profile = VoiceProfile(name: "", voice: [], seconds: 0)
                    profile.id = UUID(uuidString: id) ?? UUID()
                    context.insert(profile)
                    return profile
                }()
                SyncRecords.apply(r, to: profile)
            }
            for id in result.toDelete { byID[id].map(context.delete) }
        default:
            break
        }
        return files
    }

    // MARK: Settings

    /// Settings that follow the user to every device: key in the file → key here. Which voice is theirs holds per
    /// platform only (the voices of iPhone and Mac are other ones than Android's).
    private static let settings = [
        "myName": AppSettings.myNameKey,
        "myVoiceName": AppSettings.myVoiceNameKey,
        "myVoiceApple": AppSettings.myVoiceKey,
    ]

    /// Merges the settings, writes what changed elsewhere into this device and the result into `output`.
    private func mergeSettings(_ file: [String: Any], into output: inout [String: Any], base: [String: String]) -> [String: String] {
        let remote = (file["settings"] as? [String: [String: Any]] ?? [:]).reduce(into: [String: SyncMerge.Setting]()) { all, entry in
            guard let value = entry.value["value"] as? String else { return }
            all[entry.key] = SyncMerge.Setting(value: value, updatedAt: SyncMerge.int64(entry.value["updatedAt"]))
        }
        let defaults = UserDefaults.standard
        let local = Self.settings.mapValues { defaults.string(forKey: $0) ?? "" }
        let result = SyncMerge.mergeSettings(local: local, remote: remote, base: base, now: SyncRecords.ms(Date()))
        for (key, value) in result.toApply {
            guard let name = Self.settings[key] else { continue }
            if value.isEmpty { defaults.removeObject(forKey: name) } else { defaults.set(value, forKey: name) }
        }
        if !result.file.isEmpty || file["settings"] != nil {
            output["settings"] = result.file.mapValues { ["value": $0.value, "updatedAt": NSNumber(value: $0.updatedAt)] as [String: Any] }
        }
        return result.base
    }

    // MARK: Recordings

    /// The recordings of the notes in the file and of the notes here still being processed.
    private func referencedRecordings(_ notes: [SyncRecord], context: ModelContext) throws -> Set<String> {
        let all = try context.fetch(FetchDescriptor<Note>())
        // A part that failed to transcribe stays on this device for "Try Again" (it never goes into the file).
        let local = all.filter(SyncRecords.isFrozen).flatMap(\.storedFileNames) + all.compactMap(\.pendingAudioFileName)
        return Set(notes.flatMap(SyncRecords.audioFiles) + local)
    }

    /// Loads a recording when it is asked for. Any network will do: somebody is waiting for it.
    func fetchRecording(_ name: String) async throws {
        guard let account, AudioStore.isPlainName(name) else { throw NextcloudError.recordingNotThere }
        let dav = WebDAV(account: account)
        try await dav.download(dav.recordings.appending(path: name), to: AudioStore.url(for: name))
    }

    /// A changed setting takes effect on the uploads already waiting.
    func wifiOnlyChanged() {
        Task {
            await RecordingUploads.shared.cancelAll()
            syncSoon(after: .zero)
        }
    }

    func uploadFinished(error: String?) {
        if let error { lastError = error }
    }

    /// Recordings this device has go up. The other way they come only when asked for (`fetchRecording`):
    /// transcript and summary are there anyway, and not every device needs hours of audio.
    private func syncRecordings(_ dav: WebDAV, context: ModelContext, generation: Int) async throws {
        try checkAccount(generation)
        let all = try context.fetch(FetchDescriptor<Note>())
        let notes = all.filter { !SyncRecords.isFrozen($0) }
        let wanted = Set(notes.flatMap { [$0.audioFileName].compactMap { $0 } + $0.audioFileNames + $0.attachments.map(\.fileName) })
        var state = State.load()
        let orphans = state.orphans ?? []
        guard !wanted.isEmpty || !orphans.isEmpty else { return }
        var remote = try await dav.list(dav.recordings)
        // Recordings deleted somewhere: off the server, and off this device when no note here uses them.
        var firstError: Error?
        if !orphans.isEmpty {
            await RecordingUploads.shared.cancel(Set(orphans))
            let inUse = Set(all.flatMap(\.storedFileNames))
            let result = await SyncMerge.eachFile(orphans.filter(AudioStore.isPlainName)) { name in
                try self.checkAccount(generation)
                if remote.contains(name) { try await dav.delete(dav.recordings.appending(path: name)) }
                remote.remove(name)
                if !inUse.contains(name) { AudioStore.delete(name) }
            }
            try checkAccount(generation)
            // What could not be deleted is tried again next time.
            state.orphans = result.failed
            state.save()
            firstError = result.firstError
        }
        if !wanted.isEmpty {
            if remote.isEmpty { try await dav.makeFolder(dav.recordings) }
            let running = await RecordingUploads.shared.running()
            // No uploads with the credentials of an account that is gone.
            try checkAccount(generation)
            for name in wanted.sorted().filter(AudioStore.isPlainName)
            where AudioStore.exists(name) && !remote.contains(name) && !running.contains(name) {
                let request = dav.uploadRequest(to: dav.recordings.appending(path: name), wifiOnly: AppSettings.recordingsWiFiOnly)
                RecordingUploads.shared.start(request, file: AudioStore.url(for: name), name: name)
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: State

    /// What the last run left: the base of the three-way merge, per collection and id.
    private struct State: Codable {
        var base: [String: [String: SyncBase]] = [:]
        /// The settings at the last run (key in the file → value); nil in a state from before settings synced.
        var settings: [String: String]?
        /// The recordings the file pointed to at the last run; nil before the first run that kept them.
        var recordings: [String]?
        /// Recordings nothing points to any more: they go from the server and from this device.
        var orphans: [String]?

        private static var url: URL {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "NextcloudSync", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appending(path: "state.json")
        }

        static func load() -> State {
            (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
        }

        func save() {
            try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
        }

        static func reset() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
