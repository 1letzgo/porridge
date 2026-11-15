import SwiftData
import XCTest
@testable import Porridge

/// The inbox fields of a note: how they travel through the sync file.
@MainActor
final class IntakeModelTests: XCTestCase {
    func testTheIntakeFieldsOfANoteSurviveTheSyncFile() throws {
        let note = Note()
        note.source = .share
        note.attachments = [Attachment(fileName: "A.png", name: "Screenshot.png", kindRaw: "image", bytes: 12)]
        note.filedAt = Date(timeIntervalSince1970: 1_700_000_000)
        note.suggestedProjectIDs = ["P1"]

        // Through JSON, as the file does.
        let data = try JSONSerialization.data(withJSONObject: SyncRecords.record(note))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? SyncRecord)
        let copy = Note()
        SyncRecords.apply(record, to: copy)

        XCTAssertEqual(copy.source, .share)
        XCTAssertEqual(copy.attachments, note.attachments)
        XCTAssertEqual(copy.filedAt, note.filedAt)
        XCTAssertEqual(copy.suggestedProjectIDs, ["P1"])
        XCTAssertEqual(SyncRecords.audioFiles(record), ["A.png"])
    }

    func testARecordFromAnOlderVersionLeavesTheIntakeFieldsAlone() {
        let note = Note()
        note.source = .share
        note.filedAt = Date(timeIntervalSince1970: 1_700_000_000)
        note.attachments = [Attachment(fileName: "A.pdf", name: "A.pdf", kindRaw: "pdf")]
        var old = SyncRecords.record(note)
        for key in ["sourceRaw", "attachmentsData", "filedAt", "suggestedProjectIDs"] { old[key] = nil }
        old["title"] = "Renamed elsewhere"

        SyncRecords.apply(old, to: note)

        XCTAssertEqual(note.title, "Renamed elsewhere")
        XCTAssertEqual(note.source, .share)
        XCTAssertNotNil(note.filedAt)
        XCTAssertEqual(note.attachments.count, 1)
    }
}
