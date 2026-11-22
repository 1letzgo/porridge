import CloudKit
import SwiftData
import XCTest
@testable import Porridge

/// Sharing bowls, the part that needs no network: names, a note as a record and back, what is sent, how what comes
/// in is merged, which copy of a duplicate stays, and what is shown about a share.
@MainActor
final class BowlSharingTests: XCTestCase {
    private let bowlID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private var bowlKey: String { SharedBowlNames.bowlKey(bowlID) }

    private func note(_ title: String = "Note", in bowl: Bool = true, minutesAgo: Double = 0) -> Note {
        let note = Note()
        note.title = title
        note.text = "Text of \(title) #tag"
        note.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        note.updatedAt = Date(timeIntervalSince1970: 1_700_000_000 - minutesAgo * 60)
        if bowl { note.projectIDs = [bowlKey] }
        return note
    }

    private func info() -> SharedBowlInfo {
        SharedBowlInfo(bowlID: bowlID, role: .owner, zoneOwnerName: CKCurrentUserDefaultName, name: "Garden")
    }

    // MARK: Names

    func testZoneAndRecordNames() {
        let zone = SharedBowlNames.zoneName(for: bowlID)
        XCTAssertEqual(zone, "Bowl-11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(SharedBowlNames.bowlID(fromZoneName: zone), bowlID)
        XCTAssertNil(SharedBowlNames.bowlID(fromZoneName: "com.apple.coredata.cloudkit.zone"))
        XCTAssertNil(SharedBowlNames.bowlID(fromZoneName: "Bowl-not-a-uuid"))

        let id = UUID()
        XCTAssertEqual(SharedBowlNames.kind(ofRecordName: "bowl"), .bowl)
        XCTAssertEqual(SharedBowlNames.kind(ofRecordName: SharedBowlNames.noteRecordName(id)), .note(id))
        XCTAssertEqual(SharedBowlNames.kind(ofRecordName: SharedBowlNames.fileRecordName("A.m4a")), .file("A.m4a"))
        // Never a path, and never the share's record.
        XCTAssertNil(SharedBowlNames.kind(ofRecordName: "file-../secret"))
        XCTAssertNil(SharedBowlNames.kind(ofRecordName: CKRecordNameZoneWideShare))
    }

    // MARK: Payload

    func testPayloadRoundTripKeepsEverythingAndPutsTheNoteIntoTheBowl() {
        let original = note("Meeting")
        original.summary = "## Summary"
        original.audioFileName = "rec.m4a"
        original.audioFileNames = ["dict.m4a"]
        original.segmentsData = Data("[]".utf8)
        original.url = "https://example.com"
        original.labels = ["work"]
        original.todoStateRaw = "open"
        original.todoDueDay = "2026-12-01"
        original.attachments = [Attachment(fileName: "scan.pdf", name: "Scan.pdf", kindRaw: "pdf")]
        original.deletedAt = Date(timeIntervalSince1970: 1_700_000_500)
        let payload = SharedNotePayload(original)

        let copy = Note()
        copy.isPinned = true
        copy.projectIDs = ["OTHER"]
        copy.suggestedProjectIDs = ["X"]
        payload.apply(to: copy, bowlKey: bowlKey)

        XCTAssertEqual(SharedNotePayload(copy), payload)
        XCTAssertEqual(SharedNotePayload(copy).fingerprint, payload.fingerprint)
        XCTAssertEqual(copy.id, original.id)
        XCTAssertEqual(copy.projectIDs, [bowlKey], "an entry is in one bowl at most")
        XCTAssertEqual(copy.suggestedProjectIDs, [])
        XCTAssertTrue(copy.isPinned, "the pin is each person's own")
        XCTAssertEqual(Set(payload.fileNames), ["rec.m4a", "dict.m4a", "scan.pdf"])
    }

    func testPayloadSurvivesJSON() {
        let payload = SharedNotePayload(note())
        XCTAssertEqual(SharedNotePayload.decode(payload.encoded()), payload)
        XCTAssertNil(SharedNotePayload.decode(Data("nonsense".utf8)))
    }

    func testFingerprintFollowsContent() {
        let one = note()
        let before = SharedNotePayload(one).fingerprint
        XCTAssertEqual(SharedNotePayload(one).fingerprint, before, "the same note, the same bytes")
        one.isPinned = true
        one.projectIDs = [bowlKey, "x"]
        XCTAssertEqual(SharedNotePayload(one).fingerprint, before, "pin and bowls are not part of it")
        one.text += " more"
        XCTAssertNotEqual(SharedNotePayload(one).fingerprint, before)
    }

    func testPayloadNeverTakesPathsAsFileNames() {
        var payload = SharedNotePayload(note())
        payload.audioFileName = "../../evil"
        payload.audioFileNames = ["ok.m4a", "a/b.m4a"]
        let copy = Note()
        payload.apply(to: copy, bowlKey: bowlKey)
        XCTAssertNil(copy.audioFileName)
        XCTAssertEqual(copy.audioFileNames, ["ok.m4a"])
    }

    // MARK: Records

    func testNoteRecordRoundTripInline() throws {
        let payload = SharedNotePayload(note())
        let zone = CKRecordZone.ID(zoneName: SharedBowlNames.zoneName(for: bowlID), ownerName: CKCurrentUserDefaultName)
        let id = SharedBowlRecords.recordID(.note(payload.id), in: zone)
        let record = SharedBowlRecords.base(.note(payload.id), id: id, systemFields: nil)
        XCTAssertEqual(record.recordType, "SharedNote")
        let print = SharedBowlRecords.fillNote(record, payload: payload, temporaryDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(print, payload.fingerprint)
        XCTAssertNotNil(record[SharedBowlRecords.Field.payload])
        XCTAssertNil(record[SharedBowlRecords.Field.payloadAsset])
        XCTAssertEqual(SharedBowlRecords.payload(of: record), payload)
    }

    func testBigNoteGoesAsFile() throws {
        let big = note()
        big.pageText = String(repeating: "word ", count: 200_000)
        let payload = SharedNotePayload(big)
        let zone = CKRecordZone.ID(zoneName: SharedBowlNames.zoneName(for: bowlID), ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: "SharedNote", recordID: SharedBowlRecords.recordID(.note(payload.id), in: zone))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(SharedBowlRecords.fillNote(record, payload: payload, temporaryDirectory: folder), payload.fingerprint)
        XCTAssertNil(record[SharedBowlRecords.Field.payload])
        XCTAssertNotNil(record[SharedBowlRecords.Field.payloadAsset])
        XCTAssertEqual(SharedBowlRecords.payload(of: record), payload)
    }

    func testSystemFieldsRoundTripAndBase() {
        let zone = CKRecordZone.ID(zoneName: SharedBowlNames.zoneName(for: bowlID), ownerName: CKCurrentUserDefaultName)
        let id = SharedBowlRecords.recordID(.bowl, in: zone)
        let record = CKRecord(recordType: "SharedBowl", recordID: id)
        SharedBowlRecords.fillBowl(record, bowlID: bowlID, name: "Garden")
        XCTAssertEqual(SharedBowlRecords.bowlName(of: record), "Garden")
        let fields = SharedBowlRecords.systemFields(of: record)
        let restored = SharedBowlRecords.base(.bowl, id: id, systemFields: fields)
        XCTAssertEqual(restored.recordID, id)
        XCTAssertEqual(restored.recordType, "SharedBowl")
        XCTAssertNil(restored["name"], "only the server's part is kept")
        // Fields of another record are not taken.
        let other = SharedBowlRecords.base(.note(UUID()), id: SharedBowlRecords.recordID(.note(UUID()), in: zone), systemFields: fields)
        XCTAssertEqual(other.recordType, "SharedNote")
    }

    // MARK: What is sent

    func testPlanSendsNewAndChangedNotesOnly() {
        let new = note("new")
        let same = note("same")
        let changed = note("changed")
        let elsewhere = note("elsewhere", in: false)
        var info = info()
        info.bowlHash = SharedBowlNames.bowlFingerprint(name: "Garden")
        info.noteHashes[same.id.uuidString] = SharedNotePayload(same).fingerprint
        info.noteHashes[changed.id.uuidString] = "old"
        let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: "Garden", info: info, notes: [new, same, changed, elsewhere]) { _ in true }
        XCTAssertEqual(Set(plan.noteSaves), [new.id, changed.id])
        XCTAssertEqual(plan.noteDeletes, [])
        XCTAssertFalse(plan.saveBowl)
    }

    func testPlanDeletesNotesThatLeftTheBowlOrAreGone() {
        let left = note("left", in: false)
        let gone = UUID()
        var info = info()
        info.noteHashes[left.id.uuidString] = SharedNotePayload(left).fingerprint
        info.noteHashes[gone.uuidString] = "x"
        let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: nil, info: info, notes: [left]) { _ in true }
        XCTAssertEqual(Set(plan.noteDeletes), [left.id, gone])
        XCTAssertEqual(plan.noteSaves, [])
    }

    func testPlanWaitsForNotesInTheirWorkButDoesNotDropThem() {
        let working = note("working")
        working.status = .transcribing
        working.audioFileName = "rec.m4a"
        var info = info()
        info.noteHashes[working.id.uuidString] = "old"
        info.fileNames = ["rec.m4a"]
        let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: nil, info: info, notes: [working]) { _ in true }
        XCTAssertEqual(plan.noteSaves, [])
        XCTAssertEqual(plan.noteDeletes, [])
        XCTAssertEqual(plan.fileDeletes, [], "a file of a note in its work stays in the zone")
    }

    func testPlanSendsReadableFilesAndFetchesTheOthersFirst() {
        let meeting = note("meeting")
        meeting.audioFileName = "here.m4a"
        meeting.attachments = [Attachment(fileName: "cloud.pdf", name: "Cloud.pdf", kindRaw: "pdf")]
        var info = info()
        info.fileNames = ["old.jpg"]
        let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: nil, info: info, notes: [meeting]) { $0 == "here.m4a" }
        XCTAssertEqual(plan.fileSaves, ["here.m4a"])
        XCTAssertEqual(plan.filesToDownload, ["cloud.pdf"])
        XCTAssertEqual(plan.fileDeletes, ["old.jpg"])
    }

    func testPlanSendsTheBowlWhenItsNameChanged() {
        var info = info()
        info.bowlHash = SharedBowlNames.bowlFingerprint(name: "Garden")
        XCTAssertFalse(SharedBowlPlanner.plan(bowlID: bowlID, bowlName: "Garden", info: info, notes: []) { _ in true }.saveBowl)
        XCTAssertTrue(SharedBowlPlanner.plan(bowlID: bowlID, bowlName: "Backyard", info: info, notes: []) { _ in true }.saveBowl)
        XCTAssertTrue(SharedBowlPlanner.plan(bowlID: bowlID, bowlName: "Garden", info: self.info(), notes: []) { _ in true }.saveBowl, "never sent yet")
    }

    func testPlanDoesNotSendANoteTheZoneDroppedWhileItWaits() {
        let waiting = note("waiting")
        var info = info()
        info.pendingRemovals[waiting.id.uuidString] = Date()
        let plan = SharedBowlPlanner.plan(bowlID: bowlID, bowlName: nil, info: info, notes: [waiting]) { _ in true }
        XCTAssertEqual(plan.noteSaves, [])
    }

    // MARK: What comes in

    func testDecideInsertsApplyOrKeepsTheLaterChange() {
        let incomingNote = note("incoming", minutesAgo: 5)
        let incoming = SharedNotePayload(incomingNote)
        XCTAssertEqual(SharedBowlMerge.decide(local: nil, lastSynced: nil, incoming: incoming), .insert)

        // Nothing changed here since the last version from the zone: taken.
        let local = note("local", minutesAgo: 0)
        local.id = incomingNote.id
        let synced = SharedNotePayload(local).fingerprint
        XCTAssertEqual(SharedBowlMerge.decide(local: local, lastSynced: synced, incoming: incoming), .apply)

        // Changed here later than the zone's version, not sent yet: stays.
        XCTAssertEqual(SharedBowlMerge.decide(local: local, lastSynced: "older", incoming: incoming), .keepLocal)

        // Changed here, but the zone's version is later: the zone wins.
        local.updatedAt = Date(timeIntervalSince1970: 1_600_000_000)
        XCTAssertEqual(SharedBowlMerge.decide(local: local, lastSynced: "older", incoming: incoming), .apply)
    }

    func testRemovalMovesTheOwnersNoteToTheInboxAndDropsTheCopy() {
        XCTAssertEqual(SharedBowlMerge.removal(role: .owner, isInBowl: true), .moveToInbox)
        XCTAssertEqual(SharedBowlMerge.removal(role: .participant, isInBowl: true), .delete)
        XCTAssertEqual(SharedBowlMerge.removal(role: .participant, isInBowl: false), .none, "taken out here already: it is mine")
        XCTAssertTrue(SharedBowlMerge.keepsLocalCopy(role: .owner))
        XCTAssertFalse(SharedBowlMerge.keepsLocalCopy(role: .participant))
    }

    func testRemovalsWaitBeforeTheyAreDone() {
        let now = Date()
        let pending = ["a": now.addingTimeInterval(-SharedBowlMerge.removalDelay - 1), "b": now.addingTimeInterval(-10)]
        XCTAssertEqual(SharedBowlMerge.dueRemovals(pending, now: now), ["a"])
    }

    // MARK: Duplicates

    func testEveryDeviceKeepsTheSameCopy() {
        struct Item: Equatable { let name: String; let token: String? }
        let original = Item(name: "original", token: nil)
        let a = Item(name: "a", token: "B-token")
        let b = Item(name: "b", token: "A-token")
        XCTAssertEqual(SharedBowlMerge.duplicatesToDelete([a, original, b], token: \.token), [a, b])
        // Without the original, the smallest token stays, whatever order a device sees them in.
        XCTAssertEqual(SharedBowlMerge.duplicatesToDelete([a, b], token: \.token), [a])
        XCTAssertEqual(SharedBowlMerge.duplicatesToDelete([b, a], token: \.token), [a])
        XCTAssertEqual(SharedBowlMerge.duplicatesToDelete([a], token: \.token), [])
    }

    func testRemoveDuplicatesKeepsTheOriginalOverASharedCopy() throws {
        let context = try TestStore.context()
        let original = note("original", minutesAgo: 10)
        let copy = note("copy", minutesAgo: 0)
        copy.id = original.id
        copy.shareCopyToken = "token"
        context.insert(original)
        context.insert(copy)
        try context.save()
        LegacyMigration.removeDuplicates(in: context)
        let left = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(left.map(\.title), ["original"], "even though the copy changed later")
    }

    // MARK: What is shown

    func testSummaryNamesThePeople() {
        var owner = info()
        XCTAssertEqual(owner.summary, String(localized: "Shared"))
        owner.people = [
            SharedBowlPerson(name: "Me", isOwner: true, isCurrentUser: true),
            SharedBowlPerson(name: "Anna", isPending: true),
        ]
        XCTAssertEqual(owner.summary, String(localized: "Shared, waiting for others to join"))
        owner.people.append(SharedBowlPerson(name: "Ben"))
        XCTAssertTrue(owner.summary.contains("Ben"))
        XCTAssertFalse(owner.summary.contains("Anna"), "only those who joined")
        XCTAssertFalse(owner.summary.contains("Me"))

        var guest = SharedBowlInfo(bowlID: bowlID, role: .participant, zoneOwnerName: "_owner")
        XCTAssertEqual(guest.summary, String(localized: "Shared with you"))
        guest.people = [SharedBowlPerson(name: "Clara", isOwner: true), SharedBowlPerson(name: "Me", isCurrentUser: true)]
        XCTAssertTrue(guest.summary.contains("Clara"))
    }

    func testStateIsKeptInItsFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SharedBowlStore(url: url)
        XCTAssertTrue(store.load().bowls.isEmpty)
        var info = info()
        info.noteHashes["n"] = "h"
        info.fileNames = ["f.m4a"]
        info.pendingRemovals["p"] = Date(timeIntervalSince1970: 5)
        store.save(SharedBowlStore.Saved(bowls: [info]))
        XCTAssertEqual(store.load().bowls, [info])
    }

    func testSharingIsOffWithoutICloudSync() {
        // The tests run on test data or without sync: nothing is offered and nothing starts.
        if SyncMode.active != .iCloud { XCTAssertFalse(BowlSharing.isAvailable) }
        XCTAssertTrue(BowlSharing.shared.bowls.isEmpty)
    }
}
