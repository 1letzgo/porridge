import CloudKit
import XCTest
@testable import Porridge

/// Shared bowls beyond the sync itself: who may only see a bowl (nothing of it is sent), and who added or changed
/// what (shown until seen). The part that needs no network.
@MainActor
final class BowlSharingExtrasTests: XCTestCase {
    private let bowlID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private var bowlKey: String { SharedBowlNames.bowlKey(bowlID) }

    private func note(_ title: String = "Note") -> Note {
        let note = Note()
        note.title = title
        note.text = "Text of \(title)"
        note.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        note.updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        note.projectIDs = [bowlKey]
        return note
    }

    private func guest(readOnly: Bool?) -> SharedBowlInfo {
        var info = SharedBowlInfo(bowlID: bowlID, role: .participant, zoneOwnerName: "_owner", name: "Garden")
        info.readOnly = readOnly
        info.people = [
            SharedBowlPerson(name: "Anna", isOwner: true, canEdit: true, userRecordName: "_owner"),
            SharedBowlPerson(name: "Me", isCurrentUser: true, canEdit: readOnly.map { !$0 }, userRecordName: "_me"),
            SharedBowlPerson(name: "Ben", canEdit: true, userRecordName: "_ben"),
        ]
        info.watchingSince = Date(timeIntervalSince1970: 1)
        return info
    }

    private func owner() -> SharedBowlInfo {
        var info = SharedBowlInfo(bowlID: bowlID, role: .owner, zoneOwnerName: CKCurrentUserDefaultName, name: "Garden")
        info.watchingSince = Date(timeIntervalSince1970: 1)
        return info
    }

    // MARK: Who may change the bowl

    func testPermissionOfAPerson() {
        XCTAssertEqual(SharedBowlRecords.canEdit(isOwner: true, permission: .readOnly), true, "the owner always may")
        XCTAssertEqual(SharedBowlRecords.canEdit(isOwner: false, permission: .readWrite), true)
        XCTAssertEqual(SharedBowlRecords.canEdit(isOwner: false, permission: .readOnly), false)
        XCTAssertNil(SharedBowlRecords.canEdit(isOwner: false, permission: .unknown))
        XCTAssertNil(SharedBowlRecords.canEdit(isOwner: false, permission: .none))
    }

    func testOnlyAKnownEditorSends() {
        XCTAssertTrue(owner().maySend)
        XCTAssertFalse(owner().isReadOnly)
        XCTAssertTrue(guest(readOnly: false).maySend)
        XCTAssertFalse(guest(readOnly: true).maySend)
        XCTAssertTrue(guest(readOnly: true).isReadOnly)
        // Not known yet (state of an earlier version, or before the share was fetched): held, and still editable here.
        XCTAssertFalse(guest(readOnly: nil).maySend)
        XCTAssertFalse(guest(readOnly: nil).isReadOnly)
    }

    func testAViewOnlyBowlSendsNothing() {
        let new = note("new")
        new.audioFileName = "rec.m4a"
        let gone = UUID()
        for readOnly in [true, nil] as [Bool?] {
            var info = guest(readOnly: readOnly)
            info.noteHashes[gone.uuidString] = "x"
            info.fileNames = ["old.jpg"]
            info.fileOwners = ["old.jpg": new.id.uuidString]
            let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: "Backyard", info: info, notes: [new]) { _ in true }
            XCTAssertTrue(plan.isEmpty, "no save, no delete, no rename while I may only see it (\(String(describing: readOnly)))")
            XCTAssertEqual(plan.filesToDownload, [])
        }
        var editor = guest(readOnly: false)
        editor.noteHashes[gone.uuidString] = "x"
        let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: "Backyard", info: editor, notes: [new]) { _ in true }
        XCTAssertEqual(plan.noteSaves, [new.id])
        XCTAssertEqual(plan.noteDeletes, [gone])
        XCTAssertTrue(plan.saveBowl)
    }

    func testZoneKeysTellOwnersApart() {
        XCTAssertNotEqual(
            SharedBowlNames.zoneKey(zoneName: "Bowl-A", ownerName: "_anna"),
            SharedBowlNames.zoneKey(zoneName: "Bowl-A", ownerName: "_ben")
        )
    }

    func testSummarySaysViewOnly() {
        XCTAssertTrue(guest(readOnly: true).summary.contains("view only"))
        XCTAssertFalse(guest(readOnly: false).summary.contains("view only"))
        var nobody = guest(readOnly: true)
        nobody.people = []
        XCTAssertEqual(nobody.summary, String(localized: "Shared with you, view only"))
    }

    // MARK: Who changed what

    func testTheCurrentUserNameIsCloudKits() {
        XCTAssertEqual(SharedBowlActivity.currentUserName, CKCurrentUserDefaultName)
    }

    func testOnlyChangesOfOthersCount() {
        let info = guest(readOnly: false)
        func change(_ by: String?, last: String? = nil, incoming: String = "new", applied: Bool = true, _ info: SharedBowlInfo) -> SharedNoteActivity.Kind? {
            SharedBowlActivity.change(modifiedBy: by, lastSynced: last, incoming: incoming, applied: applied, info: info)
        }
        XCTAssertEqual(change("_ben", info), .added, "never seen here before")
        XCTAssertEqual(change("_ben", last: "old", info), .changed)
        XCTAssertNil(change("_ben", last: "new", info), "the same version as before")
        XCTAssertNil(change("_ben", applied: false, info), "kept out of the bowl here")
        XCTAssertNil(change(nil, info))
        XCTAssertNil(change(CKCurrentUserDefaultName, info), "mine, from another of my devices")
        XCTAssertNil(change("_me", info), "mine, by my record name")
        var joining = info
        joining.watchingSince = nil
        XCTAssertNil(change("_ben", joining), "what was there when I joined is not new")
        XCTAssertEqual(change("_anna", last: "old", owner()), .changed)
    }

    func testAddedStaysAddedUntilSeen() {
        var info = guest(readOnly: false)
        SharedBowlActivity.note(.added, noteID: "n", by: "_ben", at: Date(timeIntervalSince1970: 10), in: &info)
        SharedBowlActivity.note(.changed, noteID: "n", by: "_owner", at: Date(timeIntervalSince1970: 20), in: &info)
        XCTAssertEqual(info.activity?["n"], SharedNoteActivity(kind: .added, by: "_ben", name: "Ben", at: Date(timeIntervalSince1970: 20)))
        SharedBowlActivity.note(.changed, noteID: "m", by: "_owner", at: Date(timeIntervalSince1970: 30), in: &info)
        XCTAssertEqual(info.activity?["m"]?.kind, .changed)
        SharedBowlActivity.seen("n", in: &info)
        XCTAssertNil(info.activity?["n"])
        SharedBowlActivity.seen("m", in: &info)
        XCTAssertNil(info.activity, "nothing left")
    }

    func testNewSinceLastVisit() {
        var info = guest(readOnly: false)
        XCTAssertFalse(SharedBowlActivity.hasNewSinceLastVisit(info))
        SharedBowlActivity.note(.added, noteID: "n", by: "_ben", at: Date(timeIntervalSince1970: 100), in: &info)
        XCTAssertTrue(SharedBowlActivity.hasNewSinceLastVisit(info), "never visited")
        info.lastVisit = Date(timeIntervalSince1970: 200)
        XCTAssertFalse(SharedBowlActivity.hasNewSinceLastVisit(info), "the entry keeps its mark, the bowl does not")
        SharedBowlActivity.note(.changed, noteID: "m", by: "_ben", at: Date(timeIntervalSince1970: 300), in: &info)
        XCTAssertTrue(SharedBowlActivity.hasNewSinceLastVisit(info))
    }

    func testTheLineNamesThePerson() {
        var info = guest(readOnly: false)
        let byBen = SharedNoteActivity(kind: .added, by: "_ben", name: nil, at: Date())
        XCTAssertEqual(SharedBowlActivity.line(byBen, in: info), String(localized: "New from Ben"))
        let byOwner = SharedNoteActivity(kind: .changed, by: "_owner", name: nil, at: Date())
        XCTAssertEqual(SharedBowlActivity.line(byOwner, in: info), String(localized: "Changed by Anna"))
        // Someone who left: the name noted when it happened.
        let byGone = SharedNoteActivity(kind: .changed, by: "_clara", name: "Clara", at: Date())
        XCTAssertEqual(SharedBowlActivity.line(byGone, in: info), String(localized: "Changed by Clara"))
        let byNobody = SharedNoteActivity(kind: .changed, by: "_x", name: nil, at: Date())
        XCTAssertEqual(SharedBowlActivity.line(byNobody, in: info), String(localized: "Changed by Someone"))
        // The owner's zone name stands for the owner even without a record name among the people.
        info.people[0].userRecordName = nil
        XCTAssertEqual(SharedBowlActivity.line(byOwner, in: info), String(localized: "Changed by Anna"))
        // With only one other person, it can only have been them.
        var mine = owner()
        mine.people = [SharedBowlPerson(name: "Me", isOwner: true, isCurrentUser: true), SharedBowlPerson(name: "Ben")]
        XCTAssertEqual(SharedBowlActivity.line(byNobody, in: mine), String(localized: "Changed by Ben"))
    }

    // MARK: Kept on the device

    func testActivityAndPermissionAreKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var info = guest(readOnly: true)
        SharedBowlActivity.note(.added, noteID: "n", by: "_ben", at: Date(timeIntervalSince1970: 10), in: &info)
        info.lastVisit = Date(timeIntervalSince1970: 5)
        let store = SharedBowlStore(url: url)
        store.save(SharedBowlStore.Saved(bowls: [info]))
        XCTAssertEqual(store.load().bowls, [info])
    }

    func testPeopleOfTheFirstVersionStillRead() throws {
        // What 2e56dbe wrote: people without permission and record name, a bowl without the new fields.
        let json = """
        {"bowls":[{"bowlID":"11111111-2222-3333-4444-555555555555","role":"participant","zoneName":"Bowl-11111111-2222-3333-4444-555555555555",
        "zoneOwnerName":"_owner","name":"Garden","people":[{"name":"Anna","isOwner":true,"isCurrentUser":false,"isPending":false}],
        "noteHashes":{},"fileNames":[],"systemFields":{},"pendingRemovals":{}}]}
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let loaded = try XCTUnwrap(SharedBowlStore(url: url).load().bowls.first)
        XCTAssertEqual(loaded.people.first?.name, "Anna")
        XCTAssertNil(loaded.people.first?.canEdit)
        XCTAssertNil(loaded.readOnly)
        XCTAssertNil(loaded.activity)
        XCTAssertNil(loaded.watchingSince)
        XCTAssertFalse(loaded.maySend, "held until the share says what I may do")
        XCTAssertFalse(loaded.isReadOnly)
    }

    func testNothingIsReadOnlyWithoutShares() {
        XCTAssertFalse(BowlSharing.shared.isReadOnly(note()))
        XCTAssertNil(BowlSharing.shared.activityLine(for: note()))
        XCTAssertFalse(BowlSharing.shared.hasNewSinceLastVisit(bowlID))
    }
}
