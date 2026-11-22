import SwiftData
import XCTest
@testable import Porridge

/// Links between entries: the Markdown format, the editor's round trip (with renamed and missing entries),
/// backlinks and mentions, the export's mapping to files, and the `porridge://` URLs.
@MainActor
final class EntryLinksTests: XCTestCase {
    private let a = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let b = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    override func tearDown() async throws {
        EntryLinks.lookup = { _ in nil }
    }

    private func link(_ id: UUID, _ title: String) -> String { "[\(title)](porridge://entry/\(id.uuidString))" }

    // MARK: Format

    func testParsesLinksAndIgnoresOtherLinksAndImages() {
        let text = "See \(link(a, "Plan")) and [web](https://x.org) and ![pic](porridge://entry/\(b.uuidString)), [low](porridge://entry/\(b.uuidString.lowercased()))"
        let links = EntryLinks.links(in: text)
        XCTAssertEqual(links.map(\.id), [a, b])
        XCTAssertEqual(links.map(\.label), ["Plan", "low"])
        XCTAssertEqual((text as NSString).substring(with: links[0].range), link(a, "Plan"))
        XCTAssertEqual(EntryLinks.linkedIDs(in: text), [a, b])
        XCTAssertTrue(EntryLinks.links(in: "[x](porridge://entry/not-a-uuid)").isEmpty)
    }

    func testLabelsWithBracketsAreEscapedAndReadBack() {
        let markdown = EntryLinks.markdown(id: a, title: "Q[1] \\ notes]")
        XCTAssertEqual(markdown, "[Q\\[1\\] \\\\ notes\\]](porridge://entry/\(a.uuidString))")
        let parsed = EntryLinks.links(in: "x \(markdown) y")
        XCTAssertEqual(parsed.first?.label, "Q[1] \\ notes]")
        XCTAssertEqual(parsed.first?.id, a)
    }

    func testPlainLinesShowTheLabel() {
        XCTAssertEqual(NoteText.plainLines("- [ ] Call about \(link(a, "Offer"))"), ["Call about Offer"])
    }

    // MARK: Editor

    func testEditorShowsCurrentTitleAndWritesItBack() throws {
        EntryLinks.lookup = { [a] id in id == a ? EntryLinks.Target(title: "Renamed Plan", symbol: "text.alignleft") : nil }
        let markdown = "See \(link(a, "Old Plan")) now"
        let attributed = NoteMarkdown.attributed(from: markdown)
        var attachments: [EntryLinkAttachment] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let link = value as? EntryLinkAttachment { attachments.append(link) }
        }
        let chip = try XCTUnwrap(attachments.first)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(chip.title, "Renamed Plan", "the current title, not the stored label")
        XCTAssertFalse(chip.isMissing)
        XCTAssertEqual(attributed.string, "See \u{FFFC} now", "one character for the link")
        XCTAssertEqual(NoteMarkdown.markdown(from: attributed), "See \(link(a, "Renamed Plan")) now")
    }

    func testMissingEntryKeepsItsLabel() throws {
        let markdown = "Gone: \(link(b, "Deleted Thing"))"
        let attributed = NoteMarkdown.attributed(from: markdown)
        let chip = try XCTUnwrap(attributed.attribute(.attachment, at: 6, effectiveRange: nil) as? EntryLinkAttachment)
        XCTAssertTrue(chip.isMissing)
        XCTAssertEqual(chip.title, "Deleted Thing")
        XCTAssertEqual(NoteMarkdown.markdown(from: attributed), markdown, "a missing link is written back unchanged")
        // A size and a picture without a crash.
        XCTAssertGreaterThan(chip.size(font: NoteMarkdown.baseFont(kind: .paragraph), maxWidth: 300).width, 10)
    }

    func testLinksKeepBoldListsAndChecklistsAroundThem() {
        EntryLinks.lookup = { [a, b] id in [a: "Alpha", b: "Beta*"][id].map { EntryLinks.Target(title: $0, symbol: "doc") } }
        for markdown in [
            "**bold \(link(a, "Alpha")) text**",
            "- [ ] Call \(link(a, "Alpha"))",
            "- [x] \(link(b, "Beta\\*")) first",
            "1. \(link(a, "Alpha"))\(link(b, "Beta*"))",
            "> quote \(link(a, "Alpha"))",
            "*one* \(link(b, "Beta*")) *two*",
        ] {
            let expected = markdown.replacingOccurrences(of: "Beta\\*", with: "Beta*")
            XCTAssertEqual(NoteMarkdown.markdown(from: NoteMarkdown.attributed(from: markdown)), expected, markdown)
        }
        // In code a link is text.
        let code = "```\n\(link(a, "Alpha"))\n```"
        let attributed = NoteMarkdown.attributed(from: code)
        XCTAssertFalse(attributed.string.contains("\u{FFFC}"))
        XCTAssertEqual(NoteMarkdown.markdown(from: attributed), code)
    }

    // MARK: Backlinks and mentions

    private func store() throws -> (ModelContext, Note, Note, Note, Note) {
        let context = try TestStore.context()
        let target = Note()
        target.title = "Budget Review"
        let linking = Note()
        linking.title = "Linking"
        linking.text = "See \(link(target.id, "Budget Review"))."
        let mentioning = Note()
        mentioning.title = "Mentioning"
        mentioning.text = "We talked about the budget review today.\n```\nBudget Review in code\n```"
        let trashed = Note()
        trashed.text = link(target.id, "Budget Review")
        trashed.deletedAt = Date()
        for note in [target, linking, mentioning, trashed] { context.insert(note) }
        try context.save()
        return (context, target, linking, mentioning, trashed)
    }

    func testBacklinksAndMentions() throws {
        let (_, target, linking, mentioning, trashed) = try store()
        let all = [target, linking, mentioning, trashed]
        XCTAssertEqual(EntryLinks.backlinks(to: target.id, among: all).map(\.id), [linking.id], "trash left out")
        XCTAssertEqual(EntryLinks.mentions(of: target, among: all).map(\.id), [mentioning.id], "a linking entry is no mention")
        XCTAssertTrue(EntryLinks.backlinks(to: linking.id, among: all).isEmpty)
    }

    func testLinkingAMentionMakesItABacklink() throws {
        let (_, target, linking, mentioning, _) = try store()
        XCTAssertTrue(EntryLinks.linkMention(in: mentioning, to: target))
        XCTAssertEqual(mentioning.text, "We talked about the \(link(target.id, "budget review")) today.\n```\nBudget Review in code\n```",
                       "the first mention outside code, keeping its words")
        XCTAssertEqual(EntryLinks.backlinks(to: target.id, among: [target, linking, mentioning]).count, 2)
        XCTAssertTrue(EntryLinks.mentions(of: target, among: [target, linking, mentioning]).isEmpty)
        UndoToast.shared.undo()
        XCTAssertFalse(mentioning.text.contains("porridge://"), "undo puts the text back")
    }

    func testMentionsNeedWholeWordsAndATellingTitle() {
        XCTAssertNil(EntryLinks.mentionRange(of: "Plan", in: "Planning ahead"))
        XCTAssertNotNil(EntryLinks.mentionRange(of: "Über Plan", in: "das uber plan, ok"), "case and accents do not matter")
        XCTAssertNil(EntryLinks.mentionRange(of: "Budget", in: "[Budget](https://x.org/Budget)"), "not inside other links")
        let short = Note()
        short.title = "Plan"
        XCTAssertNil(EntryLinks.mentionTitle(of: short), "one short word says nothing")
        short.title = "2026"
        XCTAssertNil(EntryLinks.mentionTitle(of: short))
        short.title = "Roadmap"
        XCTAssertEqual(EntryLinks.mentionTitle(of: short), "Roadmap")
    }

    func testCandidatesFuzzyWithoutSelfOrTrash() throws {
        let (_, target, linking, mentioning, trashed) = try store()
        let all = [target, linking, mentioning, trashed]
        XCTAssertEqual(EntryLinks.candidates(for: "bdgt", among: all, excluding: linking.id).map(\.id), [target.id])
        XCTAssertFalse(EntryLinks.candidates(for: "", among: all, excluding: target.id).contains { $0.id == target.id || $0.id == trashed.id })
    }

    // MARK: Export

    func testRelativePaths() {
        XCTAssertEqual(FullExport.relativePath(to: "Inbox/b.md", from: "Inbox/a.md"), "b.md")
        XCTAssertEqual(FullExport.relativePath(to: "Bowls/Work/b.md", from: "Inbox/a.md"), "../Bowls/Work/b.md")
        XCTAssertEqual(FullExport.relativePath(to: "Inbox/b.md", from: "Bowls/Work/a.md"), "../../Inbox/b.md")
    }

    func testExportPointsLinksToMarkdownFiles() throws {
        let context = try TestStore.context()
        let bowl = NoteFolder(name: "Work")
        context.insert(bowl)
        let target = Note()
        target.title = "Target Now"
        target.projectIDs = [bowl.id.uuidString]
        let source = Note()
        source.title = "Source"
        source.text = "See \(link(target.id, "Target Before")) and \(link(b, "Elsewhere"))."
        context.insert(target)
        context.insert(source)
        try context.save()

        let plan = FullExport.plan(.everything, in: context)
        let links = FullExport.linkTargets(of: plan.archive)
        let entry = try XCTUnwrap(plan.archive.entries.first { $0.id == source.id.uuidString })
        let targetPath = try XCTUnwrap(plan.archive.entries.first { $0.id == target.id.uuidString }?.markdown)
        let markdown = FullExport.markdown(for: entry, links: links)
        XCTAssertTrue(markdown.contains("See [Target Now](<\(FullExport.relativePath(to: targetPath, from: entry.markdown))>)"), markdown)
        XCTAssertTrue(targetPath.hasPrefix("Bowls/Work/"))
        XCTAssertTrue(markdown.contains("../Bowls/Work/"))
        XCTAssertTrue(markdown.contains(link(b, "Elsewhere")), "an entry not in the export keeps its app link")
        XCTAssertEqual(entry.text, source.text, "the JSON keeps the text as stored")
    }

    // MARK: URLs

    func testEntryURLs() {
        XCTAssertEqual(PorridgeURL.entry(a).absoluteString, "porridge://entry/\(a.uuidString)")
        XCTAssertEqual(PorridgeURL.entryID(from: PorridgeURL.entry(a)), a)
        XCTAssertEqual(PorridgeURL.entryID(from: URL(string: "PORRIDGE://Entry/\(a.uuidString.lowercased())")!), a)
        XCTAssertNil(PorridgeURL.entryID(from: URL(string: "https://entry/\(a.uuidString)")!))
        XCTAssertNil(PorridgeURL.entryID(from: URL(string: "porridge://note/\(a.uuidString)")!))
        XCTAssertNil(PorridgeURL.entryID(from: URL(string: "porridge://entry/\(a.uuidString)/more")!))
    }

    func testRouterHoldsTheEntryOnce() {
        _ = EntryLinkRouter.take()
        // The test host's list listens too and takes the entry (it opens it when it has it). Whoever reads it
        // first gets it; after that it is gone.
        let posted = expectation(forNotification: .porridgeOpenEntry, object: nil)
        XCTAssertTrue(EntryLinkRouter.handle(PorridgeURL.entry(b)))
        wait(for: [posted], timeout: 1)
        let first = EntryLinkRouter.take()
        XCTAssertTrue(first == b || first == nil)
        XCTAssertNil(EntryLinkRouter.take(), "handed out once")
        EntryLinkRouter.request(a)
        XCTAssertNil(EntryLinkRouter.take().flatMap { $0 == a ? nil : $0 }, "only the entry asked for")
        XCTAssertFalse(EntryLinkRouter.handle(URL(string: "https://example.com")!))
        XCTAssertNil(EntryLinkRouter.take())
    }

    /// One router for every `porridge://` link: the older `note/<id>` opens the entry too, the widgets' other routes
    /// go to `QuickActionCenter` (and never open an entry).
    func testRouterTakesTheOlderNoteFormAndHandsOnTheOtherRoutes() {
        _ = EntryLinkRouter.take()
        let posted = expectation(forNotification: .porridgeOpenEntry, object: nil)
        XCTAssertTrue(EntryLinkRouter.handle(URL(string: "porridge://note/\(a.uuidString)")!))
        wait(for: [posted], timeout: 1)
        XCTAssertNil(EntryLinkRouter.take().flatMap { $0 == a ? nil : $0 })

        let action = expectation(forNotification: .porridgeQuickAction, object: nil)
        XCTAssertTrue(EntryLinkRouter.handle(URL(string: "porridge://search?q=plan")!))
        wait(for: [action], timeout: 1)
        XCTAssertNil(EntryLinkRouter.take())
        XCTAssertNil(QuickActionCenter.take().flatMap { $0 == .search("plan") ? nil : $0 })
        XCTAssertFalse(EntryLinkRouter.handle(URL(string: "porridge://elsewhere")!))
    }
}
