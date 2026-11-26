import CloudKit
import CryptoKit
import Foundation

/// How a share of a bowl ends and what happens to the entries then, without network or store: `BowlSharing` hands
/// in what it sees and does what these say. Every deletion here is of a copy (`Note.shareCopyToken` set) of a bowl
/// shared with me, never of an original and never on the owner's side.
///
/// - A copy of a bowl shared with me is deleted when the owner takes the entry out of the bowl, when anyone deletes
///   it for good, and when the share ends (left, stopped, deleted, removed), wherever the copy is then. What I made
///   myself goes to my inbox (taken out, share ended) or stays in Recently Deleted (deleted for good by someone).
///   On the owner's devices nothing is deleted: what leaves the zone goes to the inbox, or stays in Recently Deleted
///   when it was deleted for good, and goes from there after the usual days.
/// - Recently Deleted travels with the entry (`deletedAt` in its record), both ways: trashed or restored by anyone,
///   it is so for everyone. A deletion for good reaches the zone as the trashed entry first, then as the deletion of
///   its record (`trashedVersion`, `removal`).
/// - A copy I take out of a bowl shared with me (into another bowl or the inbox) becomes an entry of my own (a new
///   id, no token, its files copied); the shared entry stays in the shared bowl, and nothing is deleted in the zone.
/// - A file of a deleted copy goes only when no entry left here points at it.
enum SharedBowlEnding {
    // MARK: Which copies go

    /// What happens to an entry when the zone dropped it (someone took it out of the bowl or deleted it for good),
    /// once the private sync spoke (`SharedBowlMerge.dueRemovals`). Only an entry still in the bowl here is touched.
    /// Of a bowl shared with me a copy goes either way. Everything else (what I made myself, and anything on the
    /// owner's devices) is never deleted here: deleted for good, it stays in Recently Deleted; taken out of the bowl,
    /// it goes to the inbox.
    ///
    /// Deleted for good or taken out: a deletion for everyone always reaches the zone as the entry in Recently Deleted
    /// first and only then as the record's deletion (`trashedVersion`), so `isTrashed` (the entry here is in Recently
    /// Deleted, as the zone last said) tells them apart. A record deleted without that (a move out of the bowl, an
    /// older version, a device that missed the trashed version) never counts as a deletion: nothing is lost then.
    /// The end of a share deletes the zone, not its records, and never comes here (`shareEnd`).
    static func removal(role: SharedBowlRole, isCopy: Bool, isInBowl: Bool, isTrashed: Bool = false) -> SharedBowlMerge.Removal {
        guard isInBowl else { return .none }
        if role == .participant && isCopy { return .deleteCopy }
        return isTrashed ? .keepInTrash : .moveToInbox
    }

    // MARK: Deleted for good, for everyone

    /// An entry of a shared bowl in Recently Deleted that the zone does not have (someone deleted it for good, or it
    /// was deleted before the bowl was shared) is not sent: it stays out of the zone until it is restored.
    static func staysOutOfTheZone(isTrashed: Bool, zoneHasIt: Bool) -> Bool {
        isTrashed && !zoneHasIt
    }

    /// An entry of a shared bowl is deleted for good here. `zonePrint`: the fingerprint of the zone's version as far
    /// as this device knows (`SharedBowlInfo.noteHashes`), nil when the zone does not have it. Returns the version to
    /// send before its record is deleted: the entry in Recently Deleted (since `now` if it was not there), when the
    /// zone does not have exactly that yet (trashed and emptied before the trash was sent, or deleted at once). Nil
    /// when the record may go right away: the zone has it in Recently Deleted already, or does not have it at all.
    static func trashedVersion(of payload: SharedNotePayload, zonePrint: String?, now: Date = Date()) -> SharedNotePayload? {
        guard let zonePrint else { return nil }
        if payload.deletedAt != nil, payload.fingerprint == zonePrint { return nil }
        var trashed = payload
        if trashed.deletedAt == nil {
            trashed.deletedAt = now
            trashed.updatedAt = now
        }
        return trashed
    }

    /// The share ended for me (I left, the owner stopped sharing or deleted the bowl, or I was taken out of it).
    /// The owner's side keeps everything. Of a bowl shared with me every copy of its zone goes, also one that is no
    /// longer in the bowl (`isTracked`: taken from this zone, `SharedBowlInfo.copiedNotes`), unless it is in another
    /// shared bowl now (kept: in doubt nothing goes). What I made myself and put into the bowl goes to my inbox.
    static func shareEnd(
        role: SharedBowlRole, isCopy: Bool, isInBowl: Bool, isTracked: Bool = false, isInOtherSharedBowl: Bool = false
    ) -> SharedBowlMerge.Removal {
        guard role == .participant else { return .none }
        if isCopy {
            if isInBowl { return .deleteCopy }
            return isTracked && !isInOtherSharedBowl ? .deleteCopy : .none
        }
        return isInBowl ? .moveToInbox : .none
    }

    // MARK: A copy taken out of the bowl here

    /// A copy of a bowl shared with me that is no longer in the bowl here, while the zone still has it (or only just
    /// dropped it): I moved it (here or on another of my devices). It becomes an entry of my own and the shared one
    /// goes back into the shared bowl. Never on the owner's side, never for an original, never for a copy of
    /// another zone (`isTracked`).
    static func mustFork(role: SharedBowlRole, isCopy: Bool, isTracked: Bool, isInBowl: Bool, zoneHasIt: Bool) -> Bool {
        role == .participant && isCopy && isTracked && !isInBowl && zoneHasIt
    }

    /// The id of the entry of my own made from a copy: the same on each of my devices for the same move (from the
    /// copy's id and token), so two devices that both see the move make one entry, not two.
    static func forkID(of noteID: UUID, token: String) -> UUID {
        uuid(from: "fork|\(noteID.uuidString)|\(token)")
    }

    /// The name of a file of that entry: as with the id, the same on each device.
    static func forkFileName(_ fileName: String, forkID: UUID) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = uuid(from: "file|\(forkID.uuidString)|\(fileName)").uuidString
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    private static func uuid(from text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The entry of my own made from `copy`: everything of it, with a new id, no token, in the bowl (or inbox) the
    /// copy was moved to; its files under the names of `renamed` (the old name where a file could not be copied).
    static func fork(of copy: Note, id: UUID, renamed: [String: String], now: Date = Date()) -> Note {
        func name(_ old: String) -> String { renamed[old] ?? old }
        let note = Note()
        note.id = id
        note.title = copy.title
        note.text = copy.text
        note.createdAt = copy.createdAt
        note.updatedAt = now
        note.statusRaw = copy.statusRaw
        note.errorMessage = copy.errorMessage
        note.pendingAudioFileName = copy.pendingAudioFileName.map(name)
        note.audioFileNames = copy.audioFileNames.map(name)
        note.folderID = nil
        note.projectIDs = copy.projectIDs
        note.isPinned = copy.isPinned
        note.deletedAt = copy.deletedAt
        note.url = copy.url
        note.pageText = copy.pageText
        note.labels = copy.labels
        note.summary = copy.summary
        note.summaryModel = copy.summaryModel
        note.summarizedAt = copy.summarizedAt
        note.titleIsCustom = copy.titleIsCustom
        note.duration = copy.duration
        note.inputName = copy.inputName
        note.channelCount = copy.channelCount
        note.speakerModeRaw = copy.speakerModeRaw
        note.audioFileName = copy.audioFileName.map(name)
        note.speakersData = copy.speakersData
        note.segmentsData = copy.segmentsData
        note.sourceRaw = copy.sourceRaw
        if copy.attachmentsData != nil {
            note.attachments = copy.attachments.map { attachment in
                var renamedAttachment = attachment
                renamedAttachment.fileName = name(attachment.fileName)
                return renamedAttachment
            }
        }
        note.filedAt = copy.filedAt ?? (copy.projectIDs.isEmpty ? nil : now)
        note.suggestedProjectIDs = copy.suggestedProjectIDs
        note.todoStateRaw = copy.todoStateRaw
        note.todoDoneAt = copy.todoDoneAt
        note.todoSourceID = copy.todoSourceID
        note.todoDueDay = copy.todoDueDay
        note.todoSuggestionsRaw = copy.todoSuggestionsRaw
        note.shareCopyToken = nil
        return note
    }

    // MARK: Files

    /// The files of the deleted copies that no entry left here points at (the trash included): only those go.
    /// `otherReferences`: file names something else of the store points at (the meetings kept from before).
    static func unreferencedFiles(of deleted: [Note], remaining: [Note], otherReferences: Set<String> = []) -> [String] {
        let referenced = Set(remaining.flatMap(\.storedFileNames)).union(otherReferences)
        let candidates = Set(deleted.flatMap(\.storedFileNames)).filter(FileLocations.isPlainName)
        return candidates.subtracting(referenced).sorted()
    }

    // MARK: Taken out of a bowl shared with me

    /// What asking the server for the share of a bowl says about it.
    enum Access: Equatable {
        /// Nothing says the share ended (it is there, or a passing failure: offline, account, busy server).
        case keep
        /// The share ended: the zone is gone.
        case ended
        /// Looks like my access was taken away: asked once more, for the zone itself (`zoneCheck`), before it counts.
        case confirm
    }

    /// The answer to fetching the share record. For the owner only a zone the server says is gone ends a share (a
    /// missing share alone never does: another of my devices may be making it right now).
    ///
    /// For a bowl shared with me Apple documents no error for "you were removed from the share". What it plausibly
    /// gives then, by the documented meaning of the codes: `unknownItem` ("the specified record doesn't exist": the
    /// share record is gone for me) or `permissionFailure` ("the user doesn't have permission to save or fetch
    /// data"). Neither is taken alone: the zone is asked for as well (`zoneCheck`). Network, account, quota, rate
    /// and busy errors (`networkUnavailable`, `networkFailure`, `notAuthenticated`, `accountTemporarilyUnavailable`,
    /// `serviceUnavailable`, `requestRateLimited`, `zoneBusy`, ...) never end a share.
    static func access(role: SharedBowlRole, shareFetchError code: CKError.Code?) -> Access {
        guard let code else { return .keep }
        if code == .zoneNotFound || code == .userDeletedZone { return .ended }
        guard role == .participant else { return .keep }
        return code == .unknownItem || code == .permissionFailure ? .confirm : .keep
    }

    /// The answer to fetching the zone itself after `access` said `.confirm`: ended only when the zone cannot be
    /// had either (not there, or no permission to it). It is there (nil): my access stands, nothing ends. Any other
    /// failure: asked again another time.
    static func zoneCheck(role: SharedBowlRole, zoneFetchError code: CKError.Code?) -> Bool {
        guard role == .participant, let code else { return false }
        return [.zoneNotFound, .userDeletedZone, .unknownItem, .permissionFailure].contains(code)
    }
}
