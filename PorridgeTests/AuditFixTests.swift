import SwiftData
import XCTest
@testable import Porridge

/// Rules from the code audit of November 2026: each of these lost or damaged something before.
@MainActor
final class AuditFixTests: XCTestCase {
    func testMergingKeepsTheRecordingsTheOtherNoteCarries() async throws {
        let context = try TestStore.context()
        let kept = AudioStore.newFileName()
        try Data("x".utf8).write(to: AudioStore.url(for: kept))
        defer { AudioStore.delete(kept) }

        let base = Note()
        let other = Note()
        other.createdAt = base.createdAt.addingTimeInterval(60)
        other.audioFileNames = [kept]
        context.insert(base)
        context.insert(other)
        try context.save()

        try await NoteMerger.merge([other], into: base, context: context)
        XCTAssertEqual(base.audioFileNames, [kept])
        XCTAssertTrue(AudioStore.exists(kept), "deleting the merged note must not delete what moved to the base")
    }

    func testNumberedItemsCountOnAndStartOverAfterText() {
        let blocks = NoteBlock.parse("1. a\n1. b\n  1. x\n  1. y\n1. c\ntext\n1. d")
        XCTAssertEqual(NoteBlock.numbers(for: blocks), [1, 2, 1, 2, 3, 0, 1])
    }

    func testItalicInsideBoldKeepsTheBoldOpen() {
        let markdown = "**a *b* c** und ***d***"
        XCTAssertEqual(NoteMarkdown.markdown(from: NoteMarkdown.attributed(from: markdown)), markdown)
    }

    func testTheCursorInsideBoldIsNotCountedPastTheClosingMarks() {
        let text = NoteMarkdown.attributed(from: "**fett**")
        let before = text.attributedSubstring(from: NSRange(location: 0, length: 2))
        XCTAssertEqual(NoteMarkdown.markdown(from: before, openEnded: true), "**fe")
        XCTAssertEqual(NoteMarkdown.markdown(from: before), "**fe**")
    }

    func testAListLineWithoutMarkerKeepsItsText() {
        let text = NSMutableAttributedString(attributedString: NoteMarkdown.attributed(from: "- eins"))
        // Pasted into the item: the line has the list's attributes, but no marker of its own.
        text.append(NSAttributedString(string: "\nlinks\trechts", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
        XCTAssertEqual(NoteMarkdown.markdown(from: text), "- eins\n- links\trechts")
    }

    func testAnEnhancedNoteThatLostHalfIsRefused() {
        let note = String(repeating: "Ein Satz mit Inhalt. ", count: 40)
        XCTAssertTrue(SummaryService.isCutShort(String(note.prefix(200)), original: note))
        XCTAssertFalse(SummaryService.isCutShort(String(note.prefix(700)), original: note))
        XCTAssertFalse(SummaryService.isCutShort("ok", original: "kurze notiz"))
        XCTAssertTrue(CloudLLM.isTruncation("length"))
        XCTAssertTrue(CloudLLM.isTruncation("max_tokens"))
        XCTAssertTrue(CloudLLM.isTruncation("MAX_TOKENS"))
        XCTAssertFalse(CloudLLM.isTruncation("stop"))
        XCTAssertFalse(CloudLLM.isTruncation(nil))
    }

    func testThePlaudTokenOnlyGoesToPlaud() {
        XCTAssertTrue(PlaudAPI.isPlaudHost("https://api-euc1.plaud.ai"))
        XCTAssertFalse(PlaudAPI.isPlaudHost("http://api.plaud.ai"))
        XCTAssertFalse(PlaudAPI.isPlaudHost("https://plaud.ai.example.com"))
    }
}
