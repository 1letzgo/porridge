import XCTest
@testable import Porridge

/// A failed recording part and buckets deleted on another device: how they travel through the sync file.
@MainActor
final class SyncFixTests: XCTestCase {
    func testAFailedPartNoLongerFreezesItsNote() {
        let note = Note()
        note.text = "Before"
        note.addRecordedPart("Part.m4a", written: [])
        XCTAssertTrue(SyncRecords.isFrozen(note), "a part waiting to be transcribed stays on this device")
        note.status = .transcribing
        XCTAssertTrue(SyncRecords.isFrozen(note))
        note.status = .failed
        XCTAssertFalse(SyncRecords.isFrozen(note), "a failed part must not keep its note out of sync for good")
    }

    func testTheFailedPartStaysOnThisDevice() throws {
        let note = Note()
        note.text = "Before"
        note.addRecordedPart("Part.m4a", written: [])
        note.status = .failed
        note.errorMessage = "No model"

        let record = SyncRecords.record(note)
        XCTAssertNil(record["pendingAudioFileName"], "the part is not uploaded, so the file does not name it")

        // Edited on another device: the text comes, the part and its failure stay as they are here.
        var remote = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: record)) as? SyncRecord)
        remote["text"] = "Edited elsewhere"
        remote["statusRaw"] = ProcessingStatus.ready.rawValue
        remote["errorMessage"] = nil
        SyncRecords.apply(remote, to: note)
        XCTAssertEqual(note.text, "Edited elsewhere")
        XCTAssertEqual(note.pendingAudioFileName, "Part.m4a")
        XCTAssertEqual(note.status, .failed)
        XCTAssertEqual(note.errorMessage, "No model")

        // Another device never takes a part it does not have, even from a record that names one.
        let copy = Note()
        remote["pendingAudioFileName"] = "Elsewhere.m4a"
        remote["statusRaw"] = ProcessingStatus.failed.rawValue
        SyncRecords.apply(remote, to: copy)
        XCTAssertNil(copy.pendingAudioFileName)
        XCTAssertEqual(copy.status, .failed)
    }

    func testNotesLeaveBucketsThatAreGone() {
        let kept = UUID().uuidString, gone = UUID().uuidString
        let filed = Note()
        filed.projectIDs = [kept, gone]
        filed.suggestedProjectIDs = [gone]
        let only = Note()
        only.projectIDs = [gone]
        let untouched = Note()
        untouched.projectIDs = [kept.lowercased()]
        let updated = only.updatedAt

        let changed = Projects.pruneUnknown([filed, only, untouched], known: [kept])

        XCTAssertEqual(Set(changed.map(\.id)), [filed.id, only.id])
        XCTAssertEqual(filed.projectIDs, [kept])
        XCTAssertEqual(filed.suggestedProjectIDs, [])
        XCTAssertEqual(only.projectIDs, [])
        XCTAssertTrue(only.isInInbox, "a note whose last bucket is gone is back in the inbox")
        XCTAssertEqual(only.updatedAt, updated, "leaving a bucket that is gone is no edit")
        XCTAssertEqual(untouched.projectIDs, [kept.lowercased()])
    }
}
