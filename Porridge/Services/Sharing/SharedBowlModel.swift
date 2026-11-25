import CryptoKit
import Foundation

// Sharing a bowl with other iCloud users. SwiftData's CloudKit sync has no sharing, so a shared bowl gets a second,
// small layer next to it (`BowlSharing`): its own record zone in the owner's private database ("Bowl-<id>"), shared as
// a whole with a zone-wide `CKShare`. The bowl and its entries are copied into that zone as records of their own
// (`SharedBowl`, `SharedNote`, `SharedFile`) and back out of it into the store of each person. Everything else (the
// other bowls, the inbox, the chats) stays in the private SwiftData sync as before; nothing in it is moved.
//
// This file holds what needs no network: the names of zones and records, a note as the payload of its record,
// what each device knows about a shared bowl, what has to be sent, and how what comes in is merged. How a share
// ends and what happens to the copies then is in `SharedBowlEnding.swift`.

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

    /// A zone told apart from every other: its owner and its name.
    static func zoneKey(zoneName: String, ownerName: String) -> String { ownerName + "/" + zoneName }
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
        speakersData = Self.sharedSpeakers(note.speakersData)
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

    /// Dates as whole milliseconds: CloudKit keeps dates to the millisecond, so a note that reached another device of
    /// the same person through the private sync has its dates cut there. Written finer, the same note would have
    /// another fingerprint on each device and be sent back and forth for ever.
    static func milliseconds(_ date: Date) -> Int64 {
        // The small addition keeps a date that already is whole milliseconds on its millisecond (k / 1000 * 1000 can
        // come out a hair below k).
        Int64((date.timeIntervalSince1970 * 1000 + 0.001).rounded(.down))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(milliseconds(date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(Int64.self)
            return Date(timeIntervalSince1970: Double(value) / 1000)
        }
        return decoder
    }()

    func encoded() -> Data {
        (try? Self.encoder.encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> SharedNotePayload? {
        guard var payload = try? decoder.decode(SharedNotePayload.self, from: data) else { return nil }
        // Written by a version that still sent the links to voices.
        payload.speakersData = sharedSpeakers(payload.speakersData)
        return payload
    }

    /// The speakers of a meeting as they are shared: names, colors and voice prints, without the link to a person
    /// (`Speaker.profileID`). The people someone taught live in that person's own iCloud, so a link means nothing
    /// to the others; each device links the speakers to its own people (`VoiceProfiles.link`). Left in, every
    /// device would write its own links and the meeting would go back and forth.
    static func sharedSpeakers(_ data: Data?) -> Data? {
        guard let data, var speakers = try? JSONDecoder().decode([Speaker].self, from: data) else { return data }
        for index in speakers.indices { speakers[index].profileID = nil }
        return (try? speakerEncoder.encode(speakers)) ?? data
    }

    private static let speakerEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

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
    /// May change the bowl ("Can edit") or only see it ("Can view"); nil when not known (state of an earlier version).
    var canEdit: Bool?
    /// The person's user record name (`CKShare.Participant.userIdentity.userRecordID`), to tell who changed an entry
    /// (`CKRecord.lastModifiedUserRecordID`). Nil for someone invited who has not joined yet.
    var userRecordName: String?
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
    /// Notes the zone dropped while they are still in the bowl here (by id, since when). They are taken out of the
    /// bowl only after the private sync brought something newer (`SharedBowlMerge.dueRemovals`): when one of my own
    /// devices took the note out of the bowl (into another one), that move arrives first and is not undone.
    var pendingRemovals: [String: Date] = [:]
    /// Set while the zone is being deleted (sharing stopped, or the bowl deleted) and the server has not confirmed it
    /// yet: nothing is sent or taken for the bowl, and the deletion is tried again until it went through.
    var endingSince: Date?
    /// Notes whose record could not be read (a newer version wrote it, or its file did not come): their files are
    /// unknown, so no file leaves the zone while there are such notes.
    var unreadNotes: Set<String>?
    /// Which note (id) each file of the zone belongs to, as far as this device saw it. A file leaves the zone only
    /// when the note it belongs to is here and no longer has it, or when that note leaves the zone.
    var fileOwners: [String: String]?
    /// A bowl shared with me: whether I may only see it ("Can view"), as the share last said; nil while not known.
    /// Nothing is sent for the bowl unless it is known that I may edit it (`maySend`).
    var readOnly: Bool?
    /// What others added or changed in the bowl and this device has not shown yet, by note id (`SharedBowlActivity`).
    var activity: [String: SharedNoteActivity]?
    /// Since when changes of others are noted (`activity`): set once the bowl's first fetch is done, so the entries
    /// that were there when the bowl was joined do not all count as new.
    var watchingSince: Date?
    /// When the bowl's page was last open on this device ("New since your last visit").
    var lastVisit: Date?
    /// A bowl shared with me: the ids of the entries ever copied from its zone into this store (and not deleted
    /// since). When the share ends they go wherever they are then (`SharedBowlEnding.shareEnd`); a copy taken out
    /// of the bowl here becomes an entry of my own (`SharedBowlEnding.mustFork`). Nil in the state of earlier
    /// versions: filled from the copies in the bowl and the zone's notes (`BowlSharing.scan`).
    var copiedNotes: Set<String>?

    init(bowlID: UUID, role: SharedBowlRole, zoneOwnerName: String, name: String = "") {
        self.bowlID = bowlID
        self.role = role
        zoneName = SharedBowlNames.zoneName(for: bowlID)
        self.zoneOwnerName = zoneOwnerName
        self.name = name
    }

    /// The others: everyone but me, those who left excluded (they are not in `people`).
    var others: [SharedBowlPerson] { people.filter { !$0.isCurrentUser } }

    /// The bowl is shared with me to see only: its entries cannot be changed here.
    var isReadOnly: Bool { role == .participant && readOnly == true }

    /// Changes made here may go to the zone: always for my own bowl; for someone else's only once the share said
    /// that I may edit it. A bowl I may only see never sends anything.
    var maySend: Bool { role == .owner || readOnly == false }

    /// "Shared with Anna and Ben", "Shared by Anna", or, before anyone joined, "Shared, waiting for others to join".
    var summary: String {
        if endingSince != nil {
            return role == .owner ? String(localized: "Stopping sharing…") : String(localized: "Leaving…")
        }
        switch role {
        case .owner:
            let joined = others.filter { !$0.isPending }.map(\.name)
            if joined.isEmpty {
                return others.isEmpty ? String(localized: "Shared") : String(localized: "Shared, waiting for others to join")
            }
            return String(localized: "Shared with \(ListFormatter.localizedString(byJoining: joined))")
        case .participant:
            guard let owner = people.first(where: \.isOwner) else {
                return isReadOnly ? String(localized: "Shared with you, view only") : String(localized: "Shared with you")
            }
            return isReadOnly ? String(localized: "Shared by \(owner.name), view only") : String(localized: "Shared by \(owner.name)")
        }
    }
}

/// Something someone else did to an entry of a shared bowl that this device has not shown yet.
struct SharedNoteActivity: Codable, Equatable {
    enum Kind: String, Codable {
        case added
        case changed
    }

    var kind: Kind
    /// Who did it: their user record name (`CKRecord.lastModifiedUserRecordID`).
    var by: String?
    /// Their name when it happened, for when they are no longer among the people of the share.
    var name: String?
    var at: Date
}

/// Who changed what in a shared bowl, and what of it is new to me. No network: `BowlSharing` hands in what the
/// records say and keeps the result in `SharedBowlInfo.activity`.
enum SharedBowlActivity {
    /// Whether an entry that came from the zone counts as added or changed by someone else, and by whom.
    /// `modifiedBy`: the record's `lastModifiedUserRecordID`. `lastSynced`: the fingerprint this device knew of the
    /// zone's version before (nil: it never saw the entry). `applied`: the entry is in the bowl here after the merge
    /// (not skipped or kept out). Nothing counts before the bowl's first fetch (`watchingSince`), or when it was me.
    static func change(
        modifiedBy: String?, lastSynced: String?, incoming: String, applied: Bool, info: SharedBowlInfo
    ) -> SharedNoteActivity.Kind? {
        guard applied, info.watchingSince != nil, let modifiedBy, !isMe(modifiedBy, in: info) else { return nil }
        guard let lastSynced else { return .added }
        return lastSynced == incoming ? nil : .changed
    }

    /// `CKCurrentUserDefaultName` ("__defaultOwner__") stands for me in what CloudKit says about records.
    static let currentUserName = "__defaultOwner__"

    static func isMe(_ userRecordName: String, in info: SharedBowlInfo) -> Bool {
        if userRecordName == currentUserName { return true }
        return info.people.contains { $0.isCurrentUser && $0.userRecordName == userRecordName }
    }

    /// Notes what someone did to the entry; something added and then changed before I saw it stays "added".
    static func note(_ kind: SharedNoteActivity.Kind, noteID: String, by: String, at: Date, in info: inout SharedBowlInfo) {
        var all = info.activity ?? [:]
        let name = person(by, in: info)?.name
        if let earlier = all[noteID], earlier.kind == .added {
            all[noteID] = SharedNoteActivity(kind: .added, by: earlier.by, name: earlier.name ?? name, at: at)
        } else {
            all[noteID] = SharedNoteActivity(kind: kind, by: by, name: name, at: at)
        }
        info.activity = all
    }

    /// The entry was opened here (or left the zone): it is no longer new.
    static func seen(_ noteID: String, in info: inout SharedBowlInfo) {
        guard info.activity?[noteID] != nil else { return }
        info.activity?[noteID] = nil
        if info.activity?.isEmpty == true { info.activity = nil }
    }

    /// Something was added or changed by someone else since the bowl's page was last open here.
    static func hasNewSinceLastVisit(_ info: SharedBowlInfo) -> Bool {
        guard let activity = info.activity, !activity.isEmpty else { return false }
        guard let lastVisit = info.lastVisit else { return true }
        return activity.values.contains { $0.at > lastVisit }
    }

    /// The person behind a user record name: among the people of the share; else the owner, when it is the zone's
    /// owner; else the only other person there is.
    static func person(_ userRecordName: String?, in info: SharedBowlInfo) -> SharedBowlPerson? {
        if let userRecordName {
            if let found = info.people.first(where: { $0.userRecordName == userRecordName }) { return found }
            if userRecordName == info.zoneOwnerName, let owner = info.people.first(where: \.isOwner) { return owner }
        }
        let others = info.others.filter { !$0.isPending }
        return others.count == 1 ? others.first : nil
    }

    /// "New from Anna", "Changed by Ben".
    static func line(_ activity: SharedNoteActivity, in info: SharedBowlInfo) -> String {
        let name = person(activity.by, in: info)?.name ?? activity.name ?? String(localized: "Someone")
        switch activity.kind {
        case .added: return String(localized: "New from \(name)")
        case .changed: return String(localized: "Changed by \(name)")
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
    /// The note each file of the notes here belongs to (kept in `SharedBowlInfo.fileOwners`).
    var fileOwners: [String: String] = [:]

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
    /// Nothing at all while the share ends, or for a bowl I may only see (or do not know yet that I may edit).
    static func plan(
        bowlID: UUID, bowlName: String?, info: SharedBowlInfo, notes: [Note], isReadable: (String) -> Bool
    ) -> SharedBowlOutgoing {
        var result = SharedBowlOutgoing()
        guard info.endingSince == nil, info.maySend else { return result }
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
            for file in files { result.fileOwners[file] = id }
            guard isSendable(note), info.pendingRemovals[id] == nil else { continue }
            if SharedNotePayload(note).fingerprint != info.noteHashes[id], !saves.contains(note.id) { saves.append(note.id) }
            wanted.formUnion(files)
        }
        result.noteSaves = saves
        result.noteDeletes = info.noteHashes.keys.filter { !present.contains($0) }.compactMap(UUID.init(uuidString:)).sorted { $0.uuidString < $1.uuidString }
        for name in wanted.subtracting(info.fileNames).sorted() {
            if isReadable(name) { result.fileSaves.append(name) } else { result.filesToDownload.append(name) }
        }
        // A file leaves the zone only when it is known whose it is and that note let go of it: it is here and no
        // longer has it, or it leaves the zone now. Never while a note of the zone could not be read.
        let leaving = Set(result.noteDeletes.map(\.uuidString))
        if (info.unreadNotes ?? []).isEmpty {
            let owners = info.fileOwners ?? [:]
            result.fileDeletes = info.fileNames.subtracting(referenced).filter { file in
                guard let owner = owners[file] else { return false }
                return present.contains(owner) || leaving.contains(owner)
            }.sorted()
        }
        return result
    }
}

/// How what comes in from a shared zone meets what is here.
enum SharedBowlMerge {
    enum Decision: Equatable {
        /// The note is not here: it is added.
        case insert
        /// The note is not here and is not added: the owner's own notes come through the private sync, never as a
        /// copy (a copy could bring back a note deleted on another device).
        case skip
        /// The note was taken out of the bowl here and that is not sent yet: it stays out.
        case keepOut
        /// The zone's version replaces the one here.
        case apply
        /// The note changed here after the zone's version and the change was not sent yet: it stays and is sent.
        case keepLocal
    }

    /// `lastSynced`: the fingerprint of the zone's version this device knew before (`SharedBowlInfo.noteHashes`).
    /// `isInBowl`: the note here is in the shared bowl. `mayInsert`: see `mayInsert(role:createdByMe:)`.
    static func decide(local: Note?, isInBowl: Bool, lastSynced: String?, incoming: SharedNotePayload, mayInsert: Bool) -> Decision {
        guard let local else { return mayInsert ? .insert : .skip }
        if !isInBowl, lastSynced != nil { return .keepOut }
        let localPrint = SharedNotePayload(local).fingerprint
        // Nothing changed here since the zone's last version, or both say the same: the zone's version is taken.
        if localPrint == lastSynced || localPrint == incoming.fingerprint { return .apply }
        // Both changed: the later change wins, the zone's on a tie (it was there first).
        return incoming.updatedAt >= local.updatedAt ? .apply : .keepLocal
    }

    /// Whether a note of the zone that is not here is added. The other person's notes always are. On the owner's
    /// devices only notes someone else made: the owner's own come through the private sync (and one deleted there
    /// must not come back as a copy).
    static func mayInsert(role: SharedBowlRole, createdByMe: Bool) -> Bool {
        role == .participant || !createdByMe
    }

    /// The removals that may be done now: those the private sync brought something newer since (`lastImport`). A
    /// removal is never done on time alone, nor at launch before the private sync spoke.
    static func dueRemovals(_ pending: [String: Date], lastImport: Date?) -> [String] {
        guard let lastImport else { return [] }
        return pending.filter { lastImport > $0.value }.map(\.key).sorted()
    }

    enum Removal: Equatable {
        case none
        /// The note leaves the bowl and is back in the inbox; nothing of it is deleted.
        case moveToInbox
        /// A copy taken from the zone goes, with its files where no other entry points at them.
        case deleteCopy
    }

    // What happens to the entries when the zone drops one or the share ends, and to a copy taken out of the bowl
    // here: `SharedBowlEnding`.

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
