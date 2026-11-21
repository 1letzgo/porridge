import SwiftData
import XCTest
@testable import Porridge

/// What is shared into the app: the inbox the extension writes, and the notes the app makes of it.
@MainActor
final class ShareImportTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ShareInbox.rootOverride = root
    }

    override func tearDown() async throws {
        ShareInbox.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func processing(_ context: ModelContext) -> ProcessingService { ProcessingService(container: context.container) }

    func testAnEntryIsOnlySeenOnceItIsWrittenAndGoesWithUndo() throws {
        var entry = ShareInbox.Entry(text: "Remember the milk")
        _ = try ShareInbox.folder(for: entry.id)
        XCTAssertTrue(ShareInbox.pending().isEmpty)

        try ShareInbox.add(entry)
        XCTAssertEqual(ShareInbox.pending(), [entry])

        // A bowl chosen afterwards replaces the entry, it does not add one.
        entry.projectID = "P1"
        try ShareInbox.add(entry)
        XCTAssertEqual(ShareInbox.pending().map(\.projectID), ["P1"])

        ShareInbox.remove(entry.id)
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    func testLinksOfTheOldInboxStillArrive() throws {
        let old = root.appendingPathComponent("LinkInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let json = #"{"url":"https://example.com/a","title":"A","date":700000000}"#
        try Data(json.utf8).write(to: old.appendingPathComponent("X.json"))

        let context = try TestStore.context()
        ShareImport.importInbox(context: context, processing: processing(context))

        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.map(\.url), ["https://example.com/a"])
        XCTAssertEqual(notes.first?.source, .link)
        XCTAssertTrue(notes.first?.isInInbox ?? false)
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    func testSharedTextBecomesANoteInTheInboxThatGivesNoTasks() throws {
        try ShareInbox.add(.init(text: "A quote worth keeping", title: "From Books"))
        let context = try TestStore.context()
        ShareImport.importInbox(context: context, processing: processing(context))

        let note = try XCTUnwrap(context.fetch(FetchDescriptor<Note>()).first)
        XCTAssertEqual(note.text, "A quote worth keeping")
        XCTAssertEqual(note.title, "From Books")
        XCTAssertEqual(note.source, .share)
        XCTAssertTrue(note.isInInbox)
        XCTAssertTrue(note.isSaved)
        // Whatever a summary of it lists: its lines are not ticked as tasks.
        note.summary = "## Action Items\n- [ ] Buy the book"
        SummaryTasks.toggleLine(1, of: note, in: context)
        XCTAssertEqual(note.summary, "## Action Items\n- [ ] Buy the book")
    }

    func testSharedFilesBecomeAFileEachInTheChosenBucket() throws {
        let context = try TestStore.context()
        let folder = NoteFolder(name: "Trip")
        context.insert(folder)
        var entry = ShareInbox.Entry(projectID: folder.id.uuidString)
        let dir = try ShareInbox.folder(for: entry.id)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("%PDF-".utf8).write(to: dir.appendingPathComponent("b.pdf"))
        entry.files = [.init(stored: "a.txt", name: "Packing list.txt", kind: .file), .init(stored: "b.pdf", name: "Tickets.pdf", kind: .pdf)]
        try ShareInbox.add(entry)

        ShareImport.importInbox(context: context, processing: processing(context))

        let files = try context.fetch(FetchDescriptor<Note>()).sorted { $0.title < $1.title }
        addTeardownBlock { @MainActor in files.forEach { $0.storedFileNames.forEach(AudioStore.delete) } }
        // Each is a file of its own, not a note with attachments.
        XCTAssertEqual(files.map(\.title), ["Packing list", "Tickets"])
        XCTAssertEqual(files.map { $0.attachments.map(\.name) }, [["Packing list.txt"], ["Tickets.pdf"]])
        XCTAssertEqual(files.flatMap { $0.attachments.map(\.kind) }, [.file, .pdf])
        XCTAssertTrue(files.allSatisfy(\.isFile))
        XCTAssertFalse(files.contains(where: \.isImage))
        XCTAssertTrue(files.flatMap(\.attachments).allSatisfy(AttachmentStore.exists))
        for note in files {
            XCTAssertEqual(note.projectIDs, [folder.id.uuidString])
            XCTAssertFalse(note.isInInbox)
            XCTAssertEqual(note.status, .recorded)
        }
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }

    func testABucketDeletedSinceTheShareLeavesTheNoteInTheInbox() throws {
        try ShareInbox.add(.init(text: "Something", projectID: UUID().uuidString))
        let context = try TestStore.context()
        ShareImport.importInbox(context: context, processing: processing(context))
        let note = try XCTUnwrap(context.fetch(FetchDescriptor<Note>()).first)
        XCTAssertTrue(note.projectIDs.isEmpty)
        XCTAssertTrue(note.isInInbox)
    }

    func testTheTextOfAPlainFileAndAPDFWithoutTextIsRead() async throws {
        let text = root.appendingPathComponent("note.txt")
        try Data("First line\nSecond line".utf8).write(to: text)
        let read = await AttachmentText.read([(text, Attachment(fileName: "x.txt", name: "note.txt", kindRaw: "file"))])
        XCTAssertEqual(read, "First line\nSecond line")
        // Not a PDF at all: nothing to read, and no crash.
        let broken = root.appendingPathComponent("broken.pdf")
        try Data("nope".utf8).write(to: broken)
        let none = await AttachmentText.read([(broken, Attachment(fileName: "y.pdf", name: "broken.pdf", kindRaw: "pdf"))])
        XCTAssertEqual(none, "")
    }

    func testPrintedTextInAnImageIsRead() throws {
        // A white picture with two lines of black text, as a screenshot would be.
        let size = CGSize(width: 900, height: 300)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black]
            ("Invoice 4711" as NSString).draw(at: CGPoint(x: 40, y: 50), withAttributes: attributes)
            ("Total 129 Euro" as NSString).draw(at: CGPoint(x: 40, y: 150), withAttributes: attributes)
        }
        let url = root.appendingPathComponent("shot.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        let text = AttachmentText.recognize(imageAt: url)
        XCTAssertTrue(text.contains("4711"), text)
        XCTAssertTrue(text.contains("129"), text)
    }

    func testAFileWithNothingReadSaysSoInsteadOfCallingItAnEmptyNote() async {
        let image = Note()
        image.source = .share
        image.title = "Holiday"
        image.attachments = [Attachment(fileName: "missing.png", name: "Holiday.png", kindRaw: "image")]
        image.pageText = ""
        do {
            try await SummaryService.summarize(image)
            XCTFail("summarized an image nothing was read out of")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No text could be read from this image.")
        }
    }
}
