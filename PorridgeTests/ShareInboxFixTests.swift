import SwiftData
import XCTest
@testable import Porridge

/// The share sheet changing an entry the app already took in, and text shared along with a link.
@MainActor
final class ShareInboxFixTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ShareInboxFixTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ShareInbox.rootOverride = root
    }

    override func tearDown() async throws {
        ShareInbox.rootOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func processing(_ context: ModelContext) -> ProcessingService { ProcessingService(container: context.container) }

    func testABucketChosenWhileWaitingReplacesTheEntry() throws {
        var entry = ShareInbox.Entry(text: "Remember the milk")
        try ShareInbox.add(entry)
        XCTAssertTrue(ShareInbox.isPending(entry.id))
        entry.projectID = "P1"
        XCTAssertTrue(try ShareInbox.update(entry))
        XCTAssertEqual(ShareInbox.pending().map(\.projectID), ["P1"])
    }

    func testABucketChosenAfterTheAppTookItInWritesNothing() throws {
        var entry = ShareInbox.Entry(text: "Remember the milk")
        try ShareInbox.add(entry)
        let context = try TestStore.context()
        ShareImport.importInbox(context: context, processing: processing(context))
        XCTAssertFalse(ShareInbox.isPending(entry.id))

        entry.projectID = "P1"
        XCTAssertFalse(try ShareInbox.update(entry))
        // No second share: the folder does not come back and nothing is imported again.
        XCTAssertTrue(ShareInbox.pending().isEmpty)
        ShareImport.importInbox(context: context, processing: processing(context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 1)
    }

    func testEveryShareLeavesTheInboxOnceSaved() throws {
        try ShareInbox.add(.init(text: "One"))
        try ShareInbox.add(.init(url: "https://example.com/two"))
        let context = try TestStore.context()
        ShareImport.importInbox(context: context, processing: processing(context))
        XCTAssertTrue(ShareInbox.pending().isEmpty)
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 2)
    }

    func testTextSharedWithALinkStaysOnItAndGivesNoTasks() throws {
        try ShareInbox.add(.init(url: "https://example.com/a", text: "Read the part on pricing", title: "A"))
        try ShareInbox.add(.init(url: "https://example.com/b", text: "B", title: "B"))
        let context = try TestStore.context()
        ShareImport.importInbox(context: context, processing: processing(context))

        let notes = try Dictionary(uniqueKeysWithValues: context.fetch(FetchDescriptor<Note>()).map { ($0.url ?? "", $0) })
        let a = try XCTUnwrap(notes["https://example.com/a"])
        XCTAssertEqual(a.text, "Read the part on pricing")
        XCTAssertEqual(a.source, .link)
        // Only repeating the title: nothing extra.
        XCTAssertEqual(notes["https://example.com/b"]?.text, "")
        // A link never offers to-dos.
        a.summary = "## Action Items\n- [ ] Read the pricing"
        TodoSuggestions.offer(a)
        XCTAssertNil(a.todoSuggestionsRaw)
        XCTAssertTrue(a.pendingTodoSuggestions(made: []).isEmpty)
    }
}
