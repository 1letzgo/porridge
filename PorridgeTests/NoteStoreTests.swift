import SwiftData
import XCTest
@testable import Porridge

/// Store rules that lost data once.
@MainActor
final class NoteStoreTests: XCTestCase {
    private var context: ModelContext!
    private var files: [String] = []

    override func setUp() async throws {
        context = try TestStore.context()
    }

    override func tearDown() async throws {
        files.forEach(AudioStore.delete)
    }

    /// A recording that exists in the store.
    private func recording() throws -> String {
        let name = AudioStore.newFileName()
        try Data("x".utf8).write(to: AudioStore.url(for: name))
        files.append(name)
        return name
    }

    private func note() -> Note {
        let note = Note()
        context.insert(note)
        return note
    }

    func testOnlyReallyEmptyNotesAreLeftovers() {
        XCTAssertTrue(note().isEmptyLeftover)
        // A link whose page could not be fetched has no title and no text.
        let link = note()
        link.url = "https://example.com/a.pdf"
        XCTAssertFalse(link.isEmptyLeftover)
        let summarized = note()
        summarized.summary = "Kurz"
        XCTAssertFalse(summarized.isEmptyLeftover)
        let titled = note()
        titled.title = "Titel"
        XCTAssertFalse(titled.isEmptyLeftover)
    }

    func testTrashAndRestoreCountAsEdits() {
        let note = note()
        note.updatedAt = .distantPast
        NoteStore.trash(note, in: context)
        XCTAssertGreaterThan(note.updatedAt, .distantPast)
        note.updatedAt = .distantPast
        NoteStore.restore(note, in: context)
        XCTAssertGreaterThan(note.updatedAt, .distantPast)
    }

    func testDeletingPermanentlyTakesEveryRecordingWithIt() throws {
        let note = note()
        let meeting = try recording(), dictation = try recording()
        note.audioFileName = meeting
        note.audioFileNames = [dictation]
        NoteStore.deletePermanently(note, in: context)
        XCTAssertFalse(AudioStore.exists(meeting))
        XCTAssertFalse(AudioStore.exists(dictation))
    }

    func testMergingWithoutAllRecordingsKeepsThem() async throws {
        let base = note(), other = note()
        let here = try recording()
        let elsewhere = "\(UUID().uuidString).m4a"
        base.audioFileName = here
        other.audioFileName = elsewhere
        other.createdAt = base.createdAt.addingTimeInterval(60)
        try await NoteMerger.merge([other], into: base, context: context)
        XCTAssertNil(base.audioFileName)
        XCTAssertEqual(Set(base.audioFileNames), [here, elsewhere], "nothing pointing at them would delete them on the server too")
        XCTAssertTrue(AudioStore.exists(here))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Note>()), 1)
    }

    func testNamesFromTheSyncFileStayInsideTheStore() throws {
        let outside = AudioStore.directory.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).db")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        for name in ["../\(outside.lastPathComponent)", "..", "sub/a.m4a", ".hidden", ""] {
            XCTAssertFalse(AudioStore.isPlainName(name), name)
            XCTAssertFalse(AudioStore.exists(name), name)
            AudioStore.delete(name)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(AudioStore.isPlainName(AudioStore.newFileName()))
    }
}
