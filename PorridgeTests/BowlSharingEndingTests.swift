import CloudKit
import XCTest
@testable import Porridge

/// How a shared bowl ends and what happens to its entries then (`SharedBowlEnding`), the part that needs no network:
/// which copies go, a copy taken out of the bowl becoming my own, which files go, the appointment links, the error
/// codes that end a share, account changes and iCloud sync off.
@MainActor
final class BowlSharingEndingTests: XCTestCase {
    private let bowlID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private var bowlKey: String { SharedBowlNames.bowlKey(bowlID) }
    private let otherBowl = "AAAAAAAA-2222-3333-4444-555555555555"

    private func sharedCopy(_ title: String = "Copy", in bowl: Bool = true) -> Note {
        let note = Note()
        note.title = title
        note.text = "Text of \(title)"
        note.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        note.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        note.shareCopyToken = "token-\(title)"
        if bowl { note.projectIDs = [bowlKey] }
        return note
    }

    private func guest() -> SharedBowlInfo {
        var info = SharedBowlInfo(bowlID: bowlID, role: .participant, zoneOwnerName: "_owner", name: "Garden")
        info.readOnly = false
        return info
    }

    // MARK: Every way a share ends: the same rule for what stays

    /// Leaving myself, the owner stopping sharing, the owner deleting the bowl and being taken out of it all end in
    /// `BowlSharing.end`, which asks `shareEnd` for every entry: only copies go, wherever they are.
    func testEveryEndingDeletesTheCopiesWhereverTheyAre() {
        let inBowl = SharedBowlEnding.shareEnd(role: .participant, isCopy: true, isInBowl: true, isTracked: true)
        let movedOut = SharedBowlEnding.shareEnd(role: .participant, isCopy: true, isInBowl: false, isTracked: true)
        XCTAssertEqual(inBowl, .deleteCopy)
        XCTAssertEqual(movedOut, .deleteCopy, "a copy that fell out of the bowl before goes too")
    }

    func testACopyOfAnotherZoneOrInAnotherSharedBowlStays() {
        XCTAssertEqual(SharedBowlEnding.shareEnd(role: .participant, isCopy: true, isInBowl: false, isTracked: false), .none,
                       "not known to come from this zone: in doubt it stays")
        XCTAssertEqual(SharedBowlEnding.shareEnd(role: .participant, isCopy: true, isInBowl: false, isTracked: true, isInOtherSharedBowl: true), .none)
    }

    func testMyOwnEntryInTheSharedBowlGoesToTheInboxAndIsNeverDeleted() {
        for isTracked in [false, true] {
            XCTAssertEqual(SharedBowlEnding.shareEnd(role: .participant, isCopy: false, isInBowl: true, isTracked: isTracked), .moveToInbox)
            XCTAssertEqual(SharedBowlEnding.shareEnd(role: .participant, isCopy: false, isInBowl: false, isTracked: isTracked), .none)
        }
        XCTAssertEqual(SharedBowlEnding.removal(role: .participant, isCopy: false, isInBowl: true), .moveToInbox)
    }

    func testTheOwnerLosesNothing() {
        for isCopy in [false, true] {
            for isInBowl in [false, true] {
                XCTAssertEqual(SharedBowlEnding.shareEnd(role: .owner, isCopy: isCopy, isInBowl: isInBowl, isTracked: true), .none)
                XCTAssertNotEqual(SharedBowlEnding.removal(role: .owner, isCopy: isCopy, isInBowl: isInBowl), .deleteCopy)
            }
        }
        XCTAssertFalse(SharedBowlEnding.mustFork(role: .owner, isCopy: true, isTracked: true, isInBowl: false, zoneHasIt: true))
    }

    // MARK: Taken out of the bowl by the person it is shared with

    func testACopyMovedOutBecomesMineOnlyWhileTheZoneHasIt() {
        XCTAssertTrue(SharedBowlEnding.mustFork(role: .participant, isCopy: true, isTracked: true, isInBowl: false, zoneHasIt: true))
        XCTAssertFalse(SharedBowlEnding.mustFork(role: .participant, isCopy: true, isTracked: true, isInBowl: true, zoneHasIt: true), "still in the bowl")
        XCTAssertFalse(SharedBowlEnding.mustFork(role: .participant, isCopy: false, isTracked: true, isInBowl: false, zoneHasIt: true), "an original leaves the zone as before")
        XCTAssertFalse(SharedBowlEnding.mustFork(role: .participant, isCopy: true, isTracked: false, isInBowl: false, zoneHasIt: true), "a copy of another zone")
        XCTAssertFalse(SharedBowlEnding.mustFork(role: .participant, isCopy: true, isTracked: true, isInBowl: false, zoneHasIt: false), "the zone dropped it: deleted at the end")
    }

    func testTheEntryMadeFromACopyIsIndependent() throws {
        let shared = sharedCopy("Meeting", in: false)
        shared.projectIDs = [otherBowl]
        shared.audioFileName = "rec.m4a"
        shared.audioFileNames = ["dict.m4a"]
        shared.attachments = [Attachment(fileName: "scan.pdf", name: "Scan.pdf", kindRaw: "pdf")]
        shared.summary = "## Summary"
        shared.isPinned = true
        let id = SharedBowlEnding.forkID(of: shared.id, token: try XCTUnwrap(shared.shareCopyToken))
        let renamed = ["rec.m4a": SharedBowlEnding.forkFileName("rec.m4a", forkID: id)]
        let mine = SharedBowlEnding.fork(of: shared, id: id, renamed: renamed, now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertNotEqual(mine.id, shared.id)
        XCTAssertNil(mine.shareCopyToken, "an entry of my own")
        XCTAssertEqual(mine.projectIDs, [otherBowl], "where I put it")
        XCTAssertEqual(mine.title, "Meeting")
        XCTAssertEqual(mine.summary, "## Summary")
        XCTAssertTrue(mine.isPinned)
        XCTAssertEqual(mine.audioFileName, renamed["rec.m4a"], "a file that could be copied has its own name")
        XCTAssertEqual(mine.audioFileNames, ["dict.m4a"], "one that could not points at the same file")
        XCTAssertEqual(mine.attachments.map(\.fileName), ["scan.pdf"])
        XCTAssertEqual(mine.updatedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testTwoDevicesMakeTheSameEntryFromTheSameMove() {
        let noteID = UUID()
        XCTAssertEqual(SharedBowlEnding.forkID(of: noteID, token: "a"), SharedBowlEnding.forkID(of: noteID, token: "a"))
        XCTAssertNotEqual(SharedBowlEnding.forkID(of: noteID, token: "a"), SharedBowlEnding.forkID(of: noteID, token: "b"),
                          "the copy gets a new token: moved out again, another entry")
        XCTAssertNotEqual(SharedBowlEnding.forkID(of: noteID, token: "a"), noteID)
        let id = SharedBowlEnding.forkID(of: noteID, token: "a")
        XCTAssertEqual(SharedBowlEnding.forkFileName("x.m4a", forkID: id), SharedBowlEnding.forkFileName("x.m4a", forkID: id))
        XCTAssertTrue(SharedBowlEnding.forkFileName("x.m4a", forkID: id).hasSuffix(".m4a"))
        XCTAssertTrue(FileLocations.isPlainName(SharedBowlEnding.forkFileName("x.m4a", forkID: id)))
        XCTAssertNotEqual(SharedBowlEnding.forkFileName("x.m4a", forkID: id), "x.m4a")
    }

    /// The copy goes back into the bowl with the zone's version counting as its own: nothing is deleted in the zone,
    /// nothing is sent, so the owner's entry stays as it was.
    func testMovingACopyOutSendsNothingToTheZone() {
        let shared = sharedCopy()
        var info = guest()
        info.noteHashes[shared.id.uuidString] = SharedNotePayload(shared).fingerprint
        info.copiedNotes = [shared.id.uuidString]
        // Moved out: the plan of earlier versions deleted it in the zone.
        shared.projectIDs = [otherBowl]
        shared.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SharedBowlPlanner.plan(bowlID: bowlID, bowlName: nil, info: info, notes: [shared]) { _ in true }.noteDeletes, [shared.id])
        // What `BowlSharing.forkIfMovedOut` does with the copy.
        shared.projectIDs = [bowlKey]
        shared.shareCopyToken = "new"
        info.noteHashes[shared.id.uuidString] = SharedNotePayload(shared).fingerprint
        let fork = SharedBowlEnding.fork(of: sharedCopy(in: false), id: UUID(), renamed: [:])
        fork.projectIDs = [otherBowl]
        let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: nil, info: info, notes: [shared, fork]) { _ in true }
        XCTAssertEqual(plan.noteDeletes, [])
        XCTAssertEqual(plan.noteSaves, [])
        // The next version from the zone is taken as it is.
        let incoming = SharedNotePayload(sharedCopy("Changed by the owner"))
        XCTAssertEqual(SharedBowlMerge.decide(local: shared, isInBowl: true, lastSynced: info.noteHashes[shared.id.uuidString], incoming: incoming, mayInsert: true), .apply)
    }

    // MARK: Files

    func testFilesGoOnlyWithoutAnEntryLeftPointingAtThem() {
        let gone = sharedCopy("gone")
        gone.audioFileName = "rec.m4a"
        gone.audioFileNames = ["dict.m4a"]
        gone.attachments = [Attachment(fileName: "scan.pdf", name: "Scan.pdf", kindRaw: "pdf")]
        let mine = Note()
        mine.audioFileNames = ["dict.m4a"]
        let trashed = Note()
        trashed.deletedAt = Date()
        trashed.attachments = [Attachment(fileName: "scan.pdf", name: "Scan.pdf", kindRaw: "pdf")]
        XCTAssertEqual(SharedBowlEnding.unreferencedFiles(of: [gone], remaining: [mine, trashed]), ["rec.m4a"])
        XCTAssertEqual(SharedBowlEnding.unreferencedFiles(of: [gone], remaining: [mine, trashed], otherReferences: ["rec.m4a"]), [])
        XCTAssertEqual(SharedBowlEnding.unreferencedFiles(of: [gone], remaining: []), ["dict.m4a", "rec.m4a", "scan.pdf"])
        let odd = sharedCopy("odd")
        odd.audioFileName = "../escape"
        XCTAssertEqual(SharedBowlEnding.unreferencedFiles(of: [odd], remaining: []), [], "never a path")
    }

    // MARK: Appointments

    private func ref(_ series: String) -> AppointmentRef {
        let appointment = CalendarAppointment(
            id: series, title: "Standup", start: Date(timeIntervalSince1970: 1_700_000_000),
            end: Date(timeIntervalSince1970: 1_700_003_600), isAllDay: false, calendarName: "Work", externalID: series
        )
        return AppointmentRef(appointment)
    }

    func testAGoneBowlLetsGoOfItsAppointments() {
        let then = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        var ledger = AppointmentLedger()
        ledger.bowls["s1"] = .init(bowl: bowlKey, changedAt: then)
        ledger.bowls["s2"] = .init(bowl: otherBowl, changedAt: then)
        let forgotten = ledger.forgettingBowl(bowlKey, now: now)
        XCTAssertNil(forgotten.bowls["s1"]?.bowl, "back in the Inbox and Today")
        XCTAssertEqual(forgotten.bowls["s1"]?.changedAt, now, "a tombstone: other devices take it")
        XCTAssertEqual(forgotten.bowls["s2"]?.bowl, otherBowl)
        XCTAssertEqual(ledger.forgettingBowl("nothing", now: now), ledger)
    }

    func testDeletedCopiesLoseTheirLinksAndMyEntryKeepsIt() {
        let then = Date(timeIntervalSince1970: 1_000)
        let now = Date(timeIntervalSince1970: 2_000)
        var ledger = AppointmentLedger()
        ledger.notes["copy"] = .init(ref: ref("s1"), changedAt: then)
        ledger.notes["other"] = .init(ref: ref("s2"), changedAt: then)
        let forked = ledger.copyingLink(from: "copy", to: "mine", now: now)
        XCTAssertEqual(forked.notes["mine"]?.ref, ref("s1"))
        let forgotten = forked.forgettingNotes(["copy"], now: now)
        XCTAssertNil(forgotten.notes["copy"]?.ref)
        XCTAssertEqual(forgotten.notes["mine"]?.ref, ref("s1"))
        XCTAssertEqual(forgotten.notes["other"]?.ref, ref("s2"))
        XCTAssertEqual(ledger.copyingLink(from: "none", to: "mine", now: now), ledger)
    }

    // MARK: Taken out of a bowl shared with me (error codes)

    func testOnlyAGoneZoneEndsMyOwnShare() {
        XCTAssertEqual(SharedBowlEnding.access(role: .owner, shareFetchError: .zoneNotFound), .ended)
        XCTAssertEqual(SharedBowlEnding.access(role: .owner, shareFetchError: .userDeletedZone), .ended)
        XCTAssertEqual(SharedBowlEnding.access(role: .owner, shareFetchError: .unknownItem), .keep, "another device may be making the share")
        XCTAssertEqual(SharedBowlEnding.access(role: .owner, shareFetchError: .permissionFailure), .keep)
        XCTAssertFalse(SharedBowlEnding.zoneCheck(role: .owner, zoneFetchError: .zoneNotFound))
    }

    func testAShareTakenFromMeIsCheckedTwice() {
        XCTAssertEqual(SharedBowlEnding.access(role: .participant, shareFetchError: nil), .keep)
        XCTAssertEqual(SharedBowlEnding.access(role: .participant, shareFetchError: .zoneNotFound), .ended)
        XCTAssertEqual(SharedBowlEnding.access(role: .participant, shareFetchError: .unknownItem), .confirm)
        XCTAssertEqual(SharedBowlEnding.access(role: .participant, shareFetchError: .permissionFailure), .confirm)
        XCTAssertTrue(SharedBowlEnding.zoneCheck(role: .participant, zoneFetchError: .zoneNotFound))
        XCTAssertTrue(SharedBowlEnding.zoneCheck(role: .participant, zoneFetchError: .unknownItem))
        XCTAssertTrue(SharedBowlEnding.zoneCheck(role: .participant, zoneFetchError: .permissionFailure))
        XCTAssertFalse(SharedBowlEnding.zoneCheck(role: .participant, zoneFetchError: nil), "the zone is there: my access stands")
        XCTAssertFalse(SharedBowlEnding.zoneCheck(role: .participant, zoneFetchError: .networkFailure))
    }

    func testPassingFailuresNeverEndAShare() {
        let passing: [CKError.Code] = [
            .networkUnavailable, .networkFailure, .notAuthenticated, .accountTemporarilyUnavailable, .serviceUnavailable,
            .requestRateLimited, .zoneBusy, .quotaExceeded, .internalError, .partialFailure, .managedAccountRestricted,
            .participantMayNeedVerification,
        ]
        for code in passing {
            for role in [SharedBowlRole.owner, .participant] {
                XCTAssertEqual(SharedBowlEnding.access(role: role, shareFetchError: code), .keep, "\(code)")
            }
            XCTAssertFalse(SharedBowlEnding.zoneCheck(role: .participant, zoneFetchError: code), "\(code)")
        }
    }

    // MARK: Account change and iCloud sync off

    /// Signed out or another account: the copies of the bowls shared with the old account go as when the share ends
    /// (`BowlSharing.accountChanged` uses `removeLocalCopy`); my own bowls and every original stay.
    func testAnAccountChangeKeepsMyOwnBowlsAndOriginals() {
        XCTAssertEqual(SharedBowlEnding.shareEnd(role: .owner, isCopy: false, isInBowl: true), .none)
        XCTAssertEqual(SharedBowlEnding.shareEnd(role: .owner, isCopy: true, isInBowl: true), .none, "the others' entries in my bowl stay")
        XCTAssertEqual(SharedBowlEnding.shareEnd(role: .participant, isCopy: true, isInBowl: true), .deleteCopy)
        XCTAssertEqual(SharedBowlEnding.shareEnd(role: .participant, isCopy: false, isInBowl: true), .moveToInbox)
    }

    /// With iCloud sync off the state is still read, so a bowl shared with me stays one; a leave or a deletion made
    /// then is kept (`endingSince`) and done once sync is back on, and so are the copies it knows of.
    func testALeaveWithSyncOffIsKeptUntilSyncIsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var info = guest()
        info.endingSince = Date(timeIntervalSince1970: 7)
        info.copiedNotes = ["a", "b"]
        let store = SharedBowlStore(url: url)
        store.save(SharedBowlStore.Saved(bowls: [info]))
        let loaded = try XCTUnwrap(store.load().bowls.first)
        XCTAssertEqual(loaded, info)
        XCTAssertEqual(loaded.summary, String(localized: "Leaving…"))
        XCTAssertTrue(SharedBowlPlanner.plan(bowlID: bowlID, bowlName: "Garden", info: loaded, notes: [sharedCopy()]) { _ in true }.isEmpty)
    }

    func testStateWithoutTheCopiesStillReads() throws {
        // What 89e481d wrote: no copiedNotes; they are filled from the bowl and the zone (`BowlSharing.track`).
        let json = """
        {"bowls":[{"bowlID":"11111111-2222-3333-4444-555555555555","role":"participant","zoneName":"Bowl-11111111-2222-3333-4444-555555555555",
        "zoneOwnerName":"_owner","name":"Garden","people":[],"noteHashes":{"n":"h"},"fileNames":[],"systemFields":{},"pendingRemovals":{},"readOnly":false}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let loaded = try XCTUnwrap(SharedBowlStore(url: url).load().bowls.first)
        XCTAssertNil(loaded.copiedNotes)
        XCTAssertEqual(loaded.noteHashes, ["n": "h"])
    }
}
