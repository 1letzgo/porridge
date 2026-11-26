import CloudKit
import XCTest
@testable import Porridge

/// Deleting in a shared bowl is for everyone (`SharedBowlEnding.removal`, `trashedVersion`, `staysOutOfTheZone`,
/// `SharedBowlPlanner`), the part that needs no network:
/// 1. Recently Deleted travels both ways: trashed or restored by anyone, for everyone.
/// 2. Deleted for good by a participant: gone for the other participants, in Recently Deleted for the owner, never
///    sent again from there.
/// 3. Deleted for good by the owner: gone for every participant.
/// 4. Taken out of the bowl, or the share ends: no deletion.
/// 5. What a participant made himself, deleted for good by someone else: in his Recently Deleted.
@MainActor
final class BowlSharingDeletionTests: XCTestCase {
    private let bowlID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private var bowlKey: String { SharedBowlNames.bowlKey(bowlID) }
    private let otherBowl = "AAAAAAAA-2222-3333-4444-555555555555"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ title: String = "Entry", copy: Bool = false, in bowl: Bool = true) -> Note {
        let note = Note()
        note.title = title
        note.text = "Text of \(title)"
        note.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        note.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        if copy { note.shareCopyToken = "token-\(title)" }
        if bowl { note.projectIDs = [bowlKey] }
        return note
    }

    private func owner() -> SharedBowlInfo {
        SharedBowlInfo(bowlID: bowlID, role: .owner, zoneOwnerName: CKCurrentUserDefaultName, name: "Garden")
    }

    private func guest() -> SharedBowlInfo {
        var info = SharedBowlInfo(bowlID: bowlID, role: .participant, zoneOwnerName: "_owner", name: "Garden")
        info.readOnly = false
        return info
    }

    private func plan(_ info: SharedBowlInfo, _ notes: [Note]) -> SharedBowlOutgoing {
        SharedBowlPlanner.plan(bowlID: bowlID, bowlName: nil, info: info, notes: notes) { _ in true }
    }

    // MARK: 1. Recently Deleted, both ways

    func testTrashAndRestoreGoToEveryone() {
        // A participant trashes the owner's entry (his copy of it): the trashed version is sent.
        let mine = entry("Plan", copy: true)
        var info = guest()
        info.noteHashes[mine.id.uuidString] = SharedNotePayload(mine).fingerprint
        mine.deletedAt = now
        mine.updatedAt = now
        XCTAssertEqual(plan(info, [mine]).noteSaves, [mine.id], "in Recently Deleted it stays in the bowl and is sent")
        XCTAssertEqual(plan(info, [mine]).noteDeletes, [])
        let trashed = SharedNotePayload(mine)
        XCTAssertNotNil(trashed.deletedAt)

        // The owner (and anyone else) takes it as it is: in Recently Deleted, still in the bowl.
        let theirs = entry("Plan")
        theirs.id = mine.id
        let synced = SharedNotePayload(theirs).fingerprint
        XCTAssertEqual(SharedBowlMerge.decide(local: theirs, isInBowl: true, lastSynced: synced, incoming: trashed, mayInsert: false), .apply)
        trashed.apply(to: theirs, bowlKey: bowlKey)
        XCTAssertEqual(theirs.deletedAt, trashed.deletedAt)
        XCTAssertEqual(theirs.projectIDs, [bowlKey])

        // Restored by the owner: sent, and taken by everyone.
        var ownerInfo = owner()
        ownerInfo.noteHashes[theirs.id.uuidString] = SharedNotePayload(theirs).fingerprint
        theirs.deletedAt = nil
        theirs.updatedAt = now.addingTimeInterval(60)
        XCTAssertEqual(plan(ownerInfo, [theirs]).noteSaves, [theirs.id])
        let restored = SharedNotePayload(theirs)
        info.noteHashes[mine.id.uuidString] = SharedNotePayload(mine).fingerprint
        XCTAssertEqual(SharedBowlMerge.decide(local: mine, isInBowl: true, lastSynced: info.noteHashes[mine.id.uuidString], incoming: restored, mayInsert: true), .apply)
        restored.apply(to: mine, bowlKey: bowlKey)
        XCTAssertNil(mine.deletedAt)
    }

    // MARK: 2. Deleted for good by a participant

    func testDeletedForGoodByAParticipantStaysInTheOwnersRecentlyDeleted() {
        for isCopy in [false, true] {
            XCTAssertEqual(SharedBowlEnding.removal(role: .owner, isCopy: isCopy, isInBowl: true, isTrashed: true), .keepInTrash,
                           "never deleted on the owner's side, never back in the inbox")
        }
        XCTAssertEqual(SharedBowlEnding.removal(role: .participant, isCopy: true, isInBowl: true, isTrashed: true), .deleteCopy,
                       "the other participants lose their copy")
    }

    func testAnEntryDeletedForGoodElsewhereIsNotSentAgain() {
        // On the owner's device: in Recently Deleted and in the bowl, the zone dropped it.
        let kept = entry("Kept")
        kept.deletedAt = now
        kept.audioFileName = "rec.m4a"
        var info = owner()
        info.fileNames = []
        let outgoing = plan(info, [kept])
        XCTAssertEqual(outgoing.noteSaves, [])
        XCTAssertEqual(outgoing.noteDeletes, [])
        XCTAssertEqual(outgoing.fileSaves, [], "its files are not sent either")
        XCTAssertTrue(SharedBowlEnding.staysOutOfTheZone(isTrashed: true, zoneHasIt: false))
        XCTAssertFalse(SharedBowlEnding.staysOutOfTheZone(isTrashed: true, zoneHasIt: true), "trashed in the zone: changes still go")
        XCTAssertFalse(SharedBowlEnding.staysOutOfTheZone(isTrashed: false, zoneHasIt: false), "a new entry goes")

        // Restored: it goes into the zone again, for everyone.
        kept.deletedAt = nil
        XCTAssertEqual(plan(info, [kept]).noteSaves, [kept.id])
    }

    /// The usual way: trashed (and sent) first, emptied later. The record goes at once, and everyone has it in
    /// Recently Deleted already.
    func testATrashedEntryInTheZoneIsDeletedAtOnce() {
        let gone = entry("Gone", copy: true)
        gone.deletedAt = now
        let payload = SharedNotePayload(gone)
        XCTAssertNil(SharedBowlEnding.trashedVersion(of: payload, zonePrint: payload.fingerprint, now: now))
        var info = guest()
        info.noteHashes[gone.id.uuidString] = payload.fingerprint
        XCTAssertEqual(plan(info, []).noteDeletes, [gone.id])
    }

    /// Trashed and emptied before the trash was sent (offline, or within a moment), or deleted at once: the trashed
    /// version goes first, the record only once the zone has it.
    func testADeletionTheZoneDidNotSeeAsTrashedSendsTheTrashedVersionFirst() throws {
        let gone = entry("Gone", copy: true)
        gone.audioFileName = "rec.m4a"
        let zoneVersion = SharedNotePayload(gone).fingerprint
        let trashed = try XCTUnwrap(SharedBowlEnding.trashedVersion(of: SharedNotePayload(gone), zonePrint: zoneVersion, now: now))
        XCTAssertEqual(trashed.deletedAt, now)
        XCTAssertEqual(trashed.updatedAt, now, "the later change: it wins over an older edit")
        XCTAssertEqual(trashed.title, "Gone", "everything else as it was: nobody loses the content")
        XCTAssertEqual(trashed.version, SharedNotePayload.currentVersion, "a version every build reads")

        // Already in Recently Deleted here, the zone still has the version before.
        gone.deletedAt = Date(timeIntervalSince1970: 1_750_000_000)
        XCTAssertEqual(SharedBowlEnding.trashedVersion(of: SharedNotePayload(gone), zonePrint: zoneVersion, now: now)?.deletedAt,
                       gone.deletedAt, "its own date stays: the usual days count from there")
        XCTAssertNil(SharedBowlEnding.trashedVersion(of: SharedNotePayload(gone), zonePrint: nil, now: now), "not in the zone: nothing to tell")

        var info = guest()
        info.noteHashes[gone.id.uuidString] = zoneVersion
        info.fileNames = ["rec.m4a"]
        info.fileOwners = ["rec.m4a": gone.id.uuidString]
        info.deletedNotes = [gone.id.uuidString: trashed]
        let first = plan(info, [])
        XCTAssertEqual(first.noteSaves, [gone.id], "the trashed version first")
        XCTAssertEqual(first.noteDeletes, [])
        XCTAssertEqual(first.fileDeletes, [], "its files stay while the others still see it")

        // The zone has the trashed version: now the record and its files go.
        info.noteHashes[gone.id.uuidString] = trashed.fingerprint
        let then = plan(info, [])
        XCTAssertEqual(then.noteSaves, [])
        XCTAssertEqual(then.noteDeletes, [gone.id])
        XCTAssertEqual(then.fileDeletes, ["rec.m4a"])
    }

    // MARK: 3. Deleted for good by the owner

    func testDeletedForGoodByTheOwnerIsGoneForEveryParticipant() {
        for isTrashed in [false, true] {
            XCTAssertEqual(SharedBowlEnding.removal(role: .participant, isCopy: true, isInBowl: true, isTrashed: isTrashed), .deleteCopy)
        }
        // The owner's own devices: gone through the private sync; the zone's record goes from the device that deleted it.
        let gone = entry("Gone")
        gone.deletedAt = now
        var info = owner()
        info.noteHashes[gone.id.uuidString] = SharedNotePayload(gone).fingerprint
        XCTAssertEqual(plan(info, []).noteDeletes, [gone.id])
    }

    // MARK: 4. Taken out, or the share ends: never a deletion

    func testTakenOutOfTheBowlIsNoDeletion() {
        // A record deleted without the trashed version before it is a move: nothing is put into Recently Deleted.
        XCTAssertEqual(SharedBowlEnding.removal(role: .owner, isCopy: false, isInBowl: true, isTrashed: false), .moveToInbox)
        XCTAssertEqual(SharedBowlEnding.removal(role: .owner, isCopy: true, isInBowl: true, isTrashed: false), .moveToInbox)
        XCTAssertEqual(SharedBowlEnding.removal(role: .participant, isCopy: false, isInBowl: true, isTrashed: false), .moveToInbox)
        XCTAssertEqual(SharedBowlEnding.removal(role: .participant, isCopy: true, isInBowl: true, isTrashed: false), .deleteCopy,
                       "the owner took it out: the copy goes, as before")
        // Out of the bowl here already (moved on one of my devices): not touched, trashed or not.
        XCTAssertEqual(SharedBowlEnding.removal(role: .owner, isCopy: false, isInBowl: false, isTrashed: true), .none)

        // Moved out here: the record goes at once, no trashed version.
        let moved = entry("Moved", in: false)
        moved.projectIDs = [otherBowl]
        var info = owner()
        info.noteHashes[moved.id.uuidString] = SharedNotePayload(moved).fingerprint
        let outgoing = plan(info, [moved])
        XCTAssertEqual(outgoing.noteDeletes, [moved.id])
        XCTAssertEqual(outgoing.noteSaves, [])

        // A participant moving a copy out makes it his own and sends nothing (`mustFork`), trashed or not.
        XCTAssertTrue(SharedBowlEnding.mustFork(role: .participant, isCopy: true, isTracked: true, isInBowl: false, zoneHasIt: true))
    }

    func testTheEndOfAShareDeletesNothingOnTheOwnersSide() {
        for isCopy in [false, true] {
            for isInBowl in [false, true] {
                XCTAssertEqual(SharedBowlEnding.shareEnd(role: .owner, isCopy: isCopy, isInBowl: isInBowl, isTracked: true), .none)
            }
        }
        // What I made myself leaves the bowl, wherever it is (Recently Deleted included), and is not deleted.
        XCTAssertEqual(SharedBowlEnding.shareEnd(role: .participant, isCopy: false, isInBowl: true), .moveToInbox)
    }

    // MARK: 5. What a participant made himself

    func testMyOwnEntryDeletedForGoodBySomeoneElseStaysInMyRecentlyDeleted() {
        XCTAssertEqual(SharedBowlEnding.removal(role: .participant, isCopy: false, isInBowl: true, isTrashed: true), .keepInTrash)
        // It stays there, out of the zone, and goes after the usual days.
        let mine = entry("Mine")
        mine.deletedAt = now
        XCTAssertTrue(plan(guest(), [mine]).isEmpty)
    }

    // MARK: State

    func testStateWithDeletionsIsKeptAndOlderStateStillReads() throws {
        var info = guest()
        let gone = entry("Gone")
        gone.deletedAt = now
        info.deletedNotes = [gone.id.uuidString: SharedNotePayload(gone)]
        let data = try JSONEncoder().encode(info)
        XCTAssertEqual(try JSONDecoder().decode(SharedBowlInfo.self, from: data), info)

        let older = Data("""
        {"bowlID":"\(bowlID.uuidString)","role":"participant","zoneName":"Bowl-\(bowlID.uuidString)","zoneOwnerName":"_owner",
         "name":"Garden","people":[],"noteHashes":{},"fileNames":[],"systemFields":{},"pendingRemovals":{}}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(SharedBowlInfo.self, from: older).deletedNotes)
    }
}
