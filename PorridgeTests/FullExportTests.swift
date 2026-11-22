import SwiftData
import XCTest
@testable import Porridge

/// Everything (or one bowl) as files: the layout of the folder, the Markdown with its front matter, and the JSON.
@MainActor
final class FullExportTests: XCTestCase {
    private var root: URL!
    private var sources: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("FullExportTests-\(UUID().uuidString)", isDirectory: true)
        sources = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// A store with a bowl, a document in it, a to-do and a meeting in the inbox, and one entry in the trash.
    private func makeStore() throws -> (ModelContext, NoteFolder) {
        let context = try TestStore.context()
        let bowl = NoteFolder(name: "Taxes: 2026")
        bowl.createdAt = date("2026-01-01T10:00:00Z")
        context.insert(bowl)

        let invoice = Note()
        invoice.title = "Invoice Telekom"
        invoice.source = .share
        invoice.text = "Paid by card #finance"
        invoice.createdAt = date("2026-03-02T09:00:00Z")
        invoice.projectIDs = [bowl.id.uuidString]
        invoice.filedAt = date("2026-03-03T09:00:00Z")
        invoice.attachments = [
            Attachment(fileName: "A1.pdf", name: "Rechnung.pdf", kindRaw: "pdf", bytes: 5,
                       document: DocumentInfo(kind: .invoice, day: "2026-03-02", correspondent: "Telekom", amount: "39.95 EUR")),
            Attachment(fileName: "A2.pdf", name: "Rechnung.pdf", kindRaw: "pdf", bytes: 5),
            Attachment(fileName: "GONE.jpg", name: "photo.jpg", kindRaw: "image", bytes: 9),
        ]
        invoice.summary = "An invoice."
        context.insert(invoice)

        let todo = Note()
        todo.title = "Buy: milk/eggs"
        todo.text = "- [x] Milk\n- [ ] Eggs"
        todo.todoState = .open
        todo.todoDueDay = "2026-11-30"
        todo.createdAt = date("2026-11-20T08:00:00Z")
        context.insert(todo)

        let meeting = Note()
        meeting.title = "Weekly"
        meeting.source = .meeting
        meeting.createdAt = date("2026-11-20T08:00:00Z")
        meeting.audioFileName = "R1.m4a"
        meeting.duration = 61
        meeting.speakers = [Speaker(id: "s1", name: "Anna", colorIndex: 0)]
        meeting.segments = [TranscriptSegment(speakerId: "s1", start: 1, end: 4, text: "Hello all.")]
        context.insert(meeting)

        let trashed = Note()
        trashed.title = "Old"
        trashed.deletedAt = Date()
        context.insert(trashed)
        try context.save()

        for name in ["A1.pdf", "A2.pdf", "R1.m4a"] {
            try Data(name.utf8).write(to: sources.appendingPathComponent(name))
        }
        return (context, bowl)
    }

    private var files: FullExport.FileSource {
        let sources = sources!
        return { name, _ in
            let url = sources.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    func testEverythingIsWrittenAsMarkdownFilesWithTheirFilesNextToThemAndOneJSON() async throws {
        let (context, bowl) = try makeStore()
        let plan = FullExport.plan(.everything, in: context, now: date("2026-11-22T13:30:00Z"))
        XCTAssertTrue(plan.folderName.hasPrefix("Porridge Export 2026-11-22"))
        let out = root.appendingPathComponent("out", isDirectory: true)
        let steps = StepLog()
        try await FullExport.write(plan, to: out, files: files) { done in
            await steps.add(done)
        }
        XCTAssertEqual(steps.steps, Array(1...plan.steps))

        let paths = try relativePaths(in: out)
        let dayOfTodo = DocumentInfo.dayKey(date("2026-11-20T08:00:00Z"))
        let dayOfInvoice = DocumentInfo.dayKey(date("2026-03-02T09:00:00Z"))
        XCTAssertEqual(paths, [
            "Bowls/Taxes 2026/\(dayOfInvoice) Invoice Telekom.md",
            "Bowls/Taxes 2026/\(dayOfInvoice) Invoice Telekom/Rechnung 2.pdf",
            "Bowls/Taxes 2026/\(dayOfInvoice) Invoice Telekom/Rechnung.pdf",
            "Inbox/\(dayOfTodo) Buy milk eggs.md",
            "Inbox/\(dayOfTodo) Weekly.md",
            "Inbox/\(dayOfTodo) Weekly/Recording.m4a",
            "porridge.json",
        ].sorted())
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Inbox/\(dayOfTodo) Weekly/Recording.m4a"), encoding: .utf8), "R1.m4a")

        // The Markdown of the document: front matter, text, summary, links to its files.
        let invoice = try String(contentsOf: out.appendingPathComponent("Bowls/Taxes 2026/\(dayOfInvoice) Invoice Telekom.md"), encoding: .utf8)
        XCTAssertTrue(invoice.hasPrefix("---\nid: "))
        for line in [
            "title: \"Invoice Telekom\"", "kind: file", "source: share", "bowl: \"Taxes: 2026\"", "tags: [\"finance\"]",
            "document:\n  kind: invoice\n  date: 2026-03-02\n  sender: \"Telekom\"\n  amount: \"39.95 EUR\"",
            "files:\n  - \"\(dayOfInvoice) Invoice Telekom/Rechnung.pdf\"\n  - \"\(dayOfInvoice) Invoice Telekom/Rechnung 2.pdf\"",
            "# Invoice Telekom\n\nPaid by card #finance\n\n## Summary\n\nAn invoice.",
            "- [Rechnung.pdf](<\(dayOfInvoice) Invoice Telekom/Rechnung.pdf>)",
            "- photo.jpg (not on this device)",
        ] {
            XCTAssertTrue(invoice.contains(line), "missing: \(line)\n\(invoice)")
        }

        let todo = try String(contentsOf: out.appendingPathComponent("Inbox/\(dayOfTodo) Buy milk eggs.md"), encoding: .utf8)
        XCTAssertTrue(todo.contains("kind: todo\n"))
        XCTAssertTrue(todo.contains("bowl: null\n"))
        XCTAssertTrue(todo.contains("todo:\n  state: open\n  due: 2026-11-30"))
        XCTAssertTrue(todo.contains("# Buy: milk/eggs\n\n- [x] Milk\n- [ ] Eggs"))

        let meeting = try String(contentsOf: out.appendingPathComponent("Inbox/\(dayOfTodo) Weekly.md"), encoding: .utf8)
        XCTAssertTrue(meeting.contains("kind: meeting\n"))
        XCTAssertTrue(meeting.contains("speakers: [\"Anna\"]"))
        XCTAssertTrue(meeting.contains("## Transcript\n\n**[0:01] Anna:** Hello all."))
        XCTAssertTrue(meeting.contains("- [Recording.m4a](<\(dayOfTodo) Weekly/Recording.m4a>)"))

        // The JSON: the trash left out, every entry with its paths, read back as it was written.
        let data = try Data(contentsOf: out.appendingPathComponent("porridge.json"))
        let decoded = try FullExport.decoder.decode(FullExport.Archive.self, from: data)
        XCTAssertEqual(decoded.format, "de.letzgo.porridge.export")
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.scope, "everything")
        XCTAssertEqual(decoded.bowls.map(\.name), ["Taxes: 2026"])
        XCTAssertEqual(decoded.bowls.first?.folder, "Bowls/Taxes 2026")
        // Oldest first.
        XCTAssertEqual(decoded.entries.first?.title, "Invoice Telekom")
        XCTAssertEqual(Set(decoded.entries.map(\.title)), ["Invoice Telekom", "Buy: milk/eggs", "Weekly"])
        XCTAssertFalse(decoded.entries.contains { $0.title == "Old" })
        let entry = try XCTUnwrap(decoded.entries.first { $0.title == "Invoice Telekom" })
        XCTAssertEqual(entry.bowlID, bowl.id.uuidString)
        XCTAssertEqual(entry.kind, "file")
        XCTAssertEqual(entry.document, .init(kind: "invoice", date: "2026-03-02", sender: "Telekom", amount: "39.95 EUR", setByHand: false))
        XCTAssertEqual(entry.attachments.map(\.path), [
            "Bowls/Taxes 2026/\(dayOfInvoice) Invoice Telekom/Rechnung.pdf", "Bowls/Taxes 2026/\(dayOfInvoice) Invoice Telekom/Rechnung 2.pdf", nil,
        ])
        let todoEntry = try XCTUnwrap(decoded.entries.first { $0.kind == "todo" })
        XCTAssertEqual(todoEntry.todo?.subtasks, [.init(text: "Milk", done: true, indent: 0), .init(text: "Eggs", done: false, indent: 0)])
        let meetingEntry = try XCTUnwrap(decoded.entries.first { $0.kind == "meeting" })
        XCTAssertEqual(meetingEntry.meeting?.transcript, [.init(start: 1, end: 4, speaker: "Anna", text: "Hello all.")])
        XCTAssertEqual(meetingEntry.recordings.map(\.path), ["Inbox/\(dayOfTodo) Weekly/Recording.m4a"])

        // The same data are the same bytes.
        XCTAssertEqual(try FullExport.encoder.encode(decoded), data)
    }

    func testABowlAloneHasOnlyItsEntries() async throws {
        let (context, bowl) = try makeStore()
        let plan = FullExport.plan(.bowl(bowl.id), in: context, now: date("2026-11-22T13:30:00Z"))
        XCTAssertTrue(plan.folderName.hasPrefix("Porridge Taxes 2026 "))
        XCTAssertEqual(plan.archive.scope, "bowl")
        XCTAssertEqual(plan.archive.entries.map(\.title), ["Invoice Telekom"])
        XCTAssertEqual(plan.archive.bowls.map(\.name), ["Taxes: 2026"])
        let out = root.appendingPathComponent("bowl", isDirectory: true)
        try await FullExport.write(plan, to: out, files: files)
        XCTAssertFalse(try relativePaths(in: out).contains { $0.hasPrefix("Inbox/") })
    }

    func testACancelledExportStops() async throws {
        let (context, _) = try makeStore()
        let plan = FullExport.plan(.everything, in: context)
        let out = root.appendingPathComponent("cancelled", isDirectory: true)
        let task = Task {
            try await FullExport.write(plan, to: out, files: { _, _ in
                try? await Task.sleep(for: .seconds(5))
                return nil
            })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("not cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("porridge.json").path))
    }

    func testNamesAreSafeAndUnique() {
        XCTAssertEqual(FullExport.safeName("  a/b:c?*\n.d. ", fallback: "x"), "a b c .d")
        XCTAssertEqual(FullExport.safeName("...", fallback: "Entry"), "Entry")
        XCTAssertEqual(FullExport.safeName(String(repeating: "x", count: 200), fallback: "").count, 80)
        var used = Set<String>()
        XCTAssertEqual(FullExport.unique("Note.md", in: &used), "Note.md")
        XCTAssertEqual(FullExport.unique("note.md", in: &used), "note 2.md")
        XCTAssertEqual(FullExport.unique("Note.md", in: &used), "Note 3.md")
        XCTAssertEqual(FullExport.fileName("Scan", stored: "X.jpg"), "Scan.jpg")
        XCTAssertEqual(FullExport.fileName("Data", stored: "X.bin"), "Data")
        XCTAssertEqual(FullExport.yaml("say \"hi\"\n\\"), #""say \"hi\"\n\\""#)
    }

    func testTheArchiveIsZipped() async throws {
        let (context, _) = try makeStore()
        let out = root.appendingPathComponent("Export", isDirectory: true)
        try await FullExport.write(FullExport.plan(.everything, in: context), to: out, files: files)
        let zip = try FullExport.zip(out)
        XCTAssertEqual(zip.lastPathComponent, "Export.zip")
        let header = try Data(contentsOf: zip).prefix(2)
        XCTAssertEqual(header, Data("PK".utf8))
    }

    private func relativePaths(in folder: URL) throws -> [String] {
        let base = folder.resolvingSymlinksInPath().path + "/"
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        var result: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            result.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
        }
        return result.sorted()
    }
}

@MainActor
private final class StepLog {
    var steps: [Int] = []
    func add(_ step: Int) { steps.append(step) }
}
