import CryptoKit
import Foundation

// Sharing a bowl with other iCloud users. SwiftData's CloudKit sync has no sharing, so a shared bowl gets a second,
// small layer next to it (`BowlSharing`): its own record zone in the owner's private database ("Bowl-<id>"), shared as
// a whole with a zone-wide `CKShare`. The bowl and its entries are copied into that zone as records of their own
// (`SharedBowl`, `SharedNote`, `SharedFile`) and back out of it into the store of each person. Everything else (the
// other bowls, the inbox, the chats) stays in the private SwiftData sync as before; nothing in it is moved.
//
// This file holds what needs no network: the names of zones and records, a note as the payload of its record,
// what each device knows about a shared bowl, what has to be sent, and how what comes in is merged.

/// Names of the shared zones and of the records in them.
enum SharedBowlNames {
    static let zonePrefix = "Bowl-"
    static let bowlRecordType = "SharedBowl"
    static let noteRecordType = "SharedNote"
    static let fileRecordType = "SharedFile"
    /// The one bowl record of a zone.
    static let bowlRecordName = "bowl"
    static let notePrefix = "note-"
    static let filePrefix = "file-"

    /// The zone of the bowl with this id.
    static func zoneName(for bowlID: UUID) -> String { zonePrefix + bowlID.uuidString }

    /// The bowl whose zone this is; nil for any other zone (the SwiftData zone among them).
    static func bowlID(fromZoneName name: String) -> UUID? {
        guard name.hasPrefix(zonePrefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(zonePrefix.count)))
    }

    static func noteRecordName(_ id: UUID) -> String { notePrefix + id.uuidString }

    /// Files are named by the store (`AudioStore`), a plain name and never a path; the record is named after it.
    static func fileRecordName(_ fileName: String) -> String { filePrefix + fileName }

    enum RecordKind: Equatable {
        case bowl
        case note(UUID)
        case file(String)
    }

    /// What a record of a shared zone is, by its name; nil for a name of no record of ours (the share, for one).
    static func kind(ofRecordName name: String) -> RecordKind? {
        if name == bowlRecordName { return .bowl }
        if name.hasPrefix(notePrefix) {
            return UUID(uuidString: String(name.dropFirst(notePrefix.count))).map(RecordKind.note)
        }
        if name.hasPrefix(filePrefix) {
            let file = String(name.dropFirst(filePrefix.count))
            return FileLocations.isPlainName(file) ? .file(file) : nil
        }
        return nil
    }

    /// The key of the bowl in `Note.projectIDs`: the same on every device and for every person, as the bowl keeps its
    /// id when it is shared.
    static func bowlKey(_ bowlID: UUID) -> String { bowlID.uuidString }
}

/// A note as the payload of its `SharedNote` record: everything the other person needs to see and change it.
/// Not in it: which bowl it is in (the zone says that), the suggested bowls, and whether it is pinned (each person's own).
/// Encoded with sorted keys, so the same note is the same bytes on every device (`fingerprint` compares them).
struct SharedNotePayload: Codable, Equatable {
    /// Raised when the payload changes in a way older versions cannot read.
    static let currentVersion = 1

    var version: Int = SharedNotePayload.currentVersion
    var id: UUID
    var title: String
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var statusRaw: String
    var errorMessage: String?
    var audioFileNames: [String]
    var deletedAt: Date?
    var url: String?
    var pageText: String?
    var labels: [String]
    var summary: String?
    var summaryModel: String?
    var summarizedAt: Date?
    var titleIsCustom: Bool
    var duration: Double
    var inputName: String?
    var channelCount: Int
    var speakerModeRaw: String
    var audioFileName: String?
    var speakersData: Data?
    var segmentsData: Data?
    var sourceRaw: String
    var attachmentsData: Data?
    var filedAt: Date?
    var todoStateRaw: String?
    var todoDoneAt: Date?
    var todoSourceID: String?
    var todoDueDay: String?
    var todoSuggestionsRaw: String?

    init(_ note: Note) {
        id = note.id
        title = note.title
        text = note.text
        createdAt = note.createdAt
        updatedAt = note.updatedAt
        statusRaw = note.statusRaw
        errorMessage = note.errorMessage
        audioFileNames = note.audioFileNames
        deletedAt = note.deletedAt
        url = note.url
        pageText = note.pageText
        labels = note.labels
        summary = note.summary
        summaryModel = note.summaryModel
        summarizedAt = note.summarizedAt
        titleIsCustom = note.titleIsCustom
        duration = note.duration
        inputName = note.inputName
        channelCount = note.channelCount
        speakerModeRaw = note.speakerModeRaw
        audioFileName = note.audioFileName
        speakersData = note.speakersData
        segmentsData = note.segmentsData
        sourceRaw = note.sourceRaw
        attachmentsData = note.attachmentsData
        filedAt = note.filedAt
        todoStateRaw = note.todoStateRaw
        todoDoneAt = note.todoDoneAt
        todoSourceID = note.todoSourceID
        todoDueDay = note.todoDueDay
        todoSuggestionsRaw = note.todoSuggestionsRaw
    }

    /// Writes the payload into `note`, which is then in the bowl with the key `bowlKey` and in that one only (an
    /// entry has one bowl at most). Its pin stays as it is.
    func apply(to note: Note, bowlKey: String) {
        note.id = id
        note.title = title
        note.text = text
        note.createdAt = createdAt
        note.updatedAt = updatedAt
        note.statusRaw = statusRaw
        note.errorMessage = errorMessage
        note.audioFileNames = audioFileNames.filter(FileLocations.isPlainName)
        note.deletedAt = deletedAt
        note.url = url
        note.pageText = pageText
        note.labels = labels
        note.summary = summary
        note.summaryModel = summaryModel
        note.summarizedAt = summarizedAt
        note.titleIsCustom = titleIsCustom
        note.duration = duration
        note.inputName = inputName
        note.channelCount = channelCount
        note.speakerModeRaw = speakerModeRaw
        note.audioFileName = audioFileName.flatMap { FileLocations.isPlainName($0) ? $0 : nil }
        note.speakersData = speakersData
        note.segmentsData = segmentsData
        note.sourceRaw = sourceRaw
        note.attachmentsData = attachmentsData
        note.filedAt = filedAt
        note.todoStateRaw = todoStateRaw
        note.todoDoneAt = todoDoneAt
        note.todoSourceID = todoSourceID
        note.todoDueDay = todoDueDay
        note.todoSuggestionsRaw = todoSuggestionsRaw
        if note.projectIDs != [bowlKey] { note.projectIDs = [bowlKey] }
        if !note.suggestedProjectIDs.isEmpty { note.suggestedProjectIDs = [] }
        note.folderID = nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    func encoded() -> Data {
        (try? Self.encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> SharedNotePayload? {
        guard let payload = try? JSONDecoder().decode(SharedNotePayload.self, from: data) else { return nil }
        return payload
    }

    /// Stands for the content: equal for equal notes, different as soon as anything of it changed.
    var fingerprint: String { SharedBowlNames.fingerprint(encoded()) }

    /// The files of the note in the store: its recordings and attachments.
    var fileNames: [String] {
        let attachments = attachmentsData.flatMap { try? JSONDecoder().decode([Attachment].self, from: $0) } ?? []
        return ([audioFileName].compactMap { $0 } + audioFileNames + attachments.map(\.fileName)).filter(FileLocations.isPlainName)
    }
}

extension SharedBowlNames {
    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The bowl record changes with its name only.
    static func bowlFingerprint(name: String) -> String { fingerprint(Data(("bowl:" + name).utf8)) }
}

/// Whose a shared bowl is, seen from this device.
enum SharedBowlRole: String, Codable {
    /// The bowl is mine and I share it: its zone is in my private database.
    case owner
    /// Someone shared the bowl with me: its zone is in my shared database.
    case participant
}

/// A person of a share, as shown with the bowl.
struct SharedBowlPerson: Codable, Equatable, Hashable {
    var name: String
    var isOwner: Bool = false
    var isCurrentUser: Bool = false
    /// Invited and not (yet) joined.
    var isPending: Bool = false
}

/// What this device knows about one shared bowl. Kept in a file of its own (`SharedBowlStore`), not in SwiftData:
/// each device finds its shared zones itself (the owner's devices in the private database, the other person's in
/// their shared database), so nothing of it has to sync.
struct SharedBowlInfo: Codable, Equatable {
    var bowlID: UUID
    var role: SharedBowlRole
    var zoneName: String
    /// The owner of the zone: `CKCurrentUserDefaultName` for my own bowls, the owner's record name for shared ones.
    var zoneOwnerName: String
    /// The bowl's name as last seen, for when the bowl is not in the store (yet).
    var name: String = ""
    var people: [SharedBowlPerson] = []
    /// The fingerprint of each note (`SharedNotePayload.fingerprint`, by its id) as the zone has it, as far as this
    /// device knows: a note whose own fingerprint differs has changed here and is sent.
    var noteHashes: [String: String] = [:]
    /// The files that are in the zone.
    var fileNames: Set<String> = []
    /// `SharedBowlNames.bowlFingerprint` of the bowl record in the zone.
    var bowlHash: String?
    /// The system fields of each record as the zone last had them (by record name), so a change is sent on top of
    /// the server's version.
    var systemFields: [String: Data] = [:]
    /// Notes the zone dropped while they are still in the bowl here (by id, since when). They are taken out here only
    /// a while later (`SharedBowlMerge.removalDelay`): when one of my own devices took the note out of the bowl, the
    /// private sync brings that move in the meantime, and the note must not be moved a second time.
    var pendingRemovals: [String: Date] = [:]

    init(bowlID: UUID, role: SharedBowlRole, zoneOwnerName: String, name: String = "") {
        self.bowlID = bowlID
        self.role = role
        zoneName = SharedBowlNames.zoneName(for: bowlID)
        self.zoneOwnerName = zoneOwnerName
        self.name = name
    }

    /// The others: everyone but me, those who left excluded (they are not in `people`).
    var others: [SharedBowlPerson] { people.filter { !$0.isCurrentUser } }

    /// "Shared with Anna and Ben", "Shared by Anna", or, before anyone joined, "Shared, waiting for others to join".
    var summary: String {
        switch role {
        case .owner:
            let joined = others.filter { !$0.isPending }.map(\.name)
            if joined.isEmpty {
                return others.isEmpty ? String(localized: "Shared") : String(localized: "Shared, waiting for others to join")
            }
            return String(localized: "Shared with \(ListFormatter.localizedString(byJoining: joined))")
        case .participant:
            guard let owner = people.first(where: \.isOwner) else { return String(localized: "Shared with you") }
            return String(localized: "Shared by \(owner.name)")
        }
    }
}

/// What has to be sent for one shared bowl, worked out from the store and from what the zone has (`SharedBowlInfo`).
struct SharedBowlOutgoing: Equatable {
    var saveBowl = false
    var noteSaves: [UUID] = []
    var noteDeletes: [UUID] = []
    var fileSaves: [String] = []
    var fileDeletes: [String] = []
    /// Files the zone should have that are not readable here yet (in iCloud, not downloaded): fetched first.
    var filesToDownload: [String] = []

    var isEmpty: Bool {
        !saveBowl && noteSaves.isEmpty && noteDeletes.isEmpty && fileSaves.isEmpty && fileDeletes.isEmpty
    }
}

enum SharedBowlPlanner {
    /// Notes in the middle of their work (a recording waiting for its transcript, files being read) are sent once
    /// they are done, as the files of notes move into iCloud only then (`CloudFiles`).
    static func isSendable(_ note: Note) -> Bool {
        (note.status == .ready || note.status == .failed) && note.pendingAudioFileName == nil
    }

    /// `notes`: all notes of the store. `isReadable`: whether a file can be read here right now.
    /// A note leaves the zone when it left the bowl here or is gone from this device altogether.
    static func plan(
        bowlID: UUID, bowlName: String?, info: SharedBowlInfo, notes: [Note], isReadable: (String) -> Bool
    ) -> SharedBowlOutgoing {
        var result = SharedBowlOutgoing()
        let key = SharedBowlNames.bowlKey(bowlID)
        if let bowlName, SharedBowlNames.bowlFingerprint(name: bowlName) != info.bowlHash { result.saveBowl = true }

        let inBowl = notes.filter { $0.projectIDs.contains(key) }
        var present = Set<String>()
        var referenced = Set<String>()
        var wanted = Set<String>()
        var saves: [UUID] = []
        for note in inBowl {
            let id = note.id.uuidString
            present.insert(id)
            let files = ([note.audioFileName, note.pendingAudioFileName].compactMap { $0 } + note.audioFileNames
                + note.attachments.map(\.fileName)).filter(FileLocations.isPlainName)
            referenced.formUnion(files)
            guard isSendable(note), info.pendingRemovals[id] == nil else { continue }
            if SharedNotePayload(note).fingerprint != info.noteHashes[id], !saves.contains(note.id) { saves.append(note.id) }
            wanted.formUnion(files)
        }
        result.noteSaves = saves
        result.noteDeletes = info.noteHashes.keys.filter { !present.contains($0) }.compactMap(UUID.init(uuidString:)).sorted { $0.uuidString < $1.uuidString }
        for name in wanted.subtracting(info.fileNames).sorted() {
            if isReadable(name) { result.fileSaves.append(name) } else { result.filesToDownload.append(name) }
        }
        result.fileDeletes = info.fileNames.subtracting(referenced).sorted()
        return result
    }
}

/// How what comes in from a shared zone meets what is here.
enum SharedBowlMerge {
    enum Decision: Equatable {
        /// The note is not here: it is added.
        case insert
        /// The zone's version replaces the one here.
        case apply
        /// The note changed here after the zone's version and the change was not sent yet: it stays and is sent.
        case keepLocal
    }

    /// `lastSynced`: the fingerprint of the zone's version this device knew before (`SharedBowlInfo.noteHashes`).
    static func decide(local: Note?, lastSynced: String?, incoming: SharedNotePayload) -> Decision {
        guard let local else { return .insert }
        let localPrint = SharedNotePayload(local).fingerprint
        // Nothing changed here since the zone's last version, or both say the same: the zone's version is taken.
        if localPrint == lastSynced || localPrint == incoming.fingerprint { return .apply }
        // Both changed: the later change wins, the zone's on a tie (it was there first).
        return incoming.updatedAt >= local.updatedAt ? .apply : .keepLocal
    }

    /// How long a note the zone dropped stays here before it is taken out of the bowl (`SharedBowlInfo.pendingRemovals`).
    static let removalDelay: TimeInterval = 120

    /// The notes whose wait is over at `now`.
    static func dueRemovals(_ pending: [String: Date], now: Date) -> [String] {
        pending.filter { now.timeIntervalSince($0.value) >= removalDelay }.map(\.key).sorted()
    }

    enum Removal: Equatable {
        case none
        /// The owner keeps the note: it leaves the bowl and is back in the inbox.
        case moveToInbox
        /// The note was the owner's: the copy of the other person goes.
        case delete
    }

    /// A note left the zone (taken out of the bowl, or deleted for good, by someone). Only a note that is still in
    /// the bowl here is touched: one taken out of it here already belongs to this person alone.
    static func removal(role: SharedBowlRole, isInBowl: Bool) -> Removal {
        guard isInBowl else { return .none }
        return role == .owner ? .moveToInbox : .delete
    }

    /// The bowl and its entries end for me (the owner stopped sharing, or I left): my copies of the owner's bowl go.
    /// The owner's own bowl stays as it is.
    static func keepsLocalCopy(role: SharedBowlRole) -> Bool { role == .owner }

    /// The same note or bowl (same id) can end up twice in the store: two devices of one person both took it from
    /// the zone, and the private sync brings each one the other's copy. Every device has to keep the same one, or
    /// each deletes the other's and both are gone: the original (no token) is kept, else the copy with the smallest
    /// token. Returns the ones to delete; nil tokens of two originals are left alone (not a copy of ours).
    static func duplicatesToDelete<Item>(_ items: [Item], token: (Item) -> String?) -> [Item] {
        guard items.count > 1 else { return [] }
        if items.contains(where: { token($0) == nil }) { return items.filter { token($0) != nil } }
        let sorted = items.sorted { (token($0) ?? "") < (token($1) ?? "") }
        return Array(sorted.dropFirst())
    }
}
