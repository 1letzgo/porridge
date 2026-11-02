import SwiftData
import XCTest
@testable import Porridge

/// The same cases as Android's `ActionItemsLogicTest`, on a store in memory.
@MainActor
final class ActionItemsTests: XCTestCase {
    private let summary = """
    # Weekly
    ## Zusammenfassung
    - Ein Punkt, keine Aufgabe
    ## Aufgaben
    - Angebot schicken – Anna
    - [x] Raum buchen
    1. Bericht schreiben
    - Keine weiteren Aufgaben.
    ## Entscheidungen
    - Wir nehmen Variante B
    ## Notizen
    - [ ] Checkbox irgendwo
    """

    private var context: ModelContext!

    override func setUp() async throws {
        context = try TestStore.context()
    }

    private func note(summary: String? = nil, url: String? = nil) -> Note {
        let note = Note()
        note.summary = summary ?? self.summary
        note.url = url
        context.insert(note)
        return note
    }

    private func items(_ note: Note) -> [ActionItem] {
        ActionItems.items(of: note.id, in: context)
    }

    func testParsesSectionsInAnyLanguage() {
        let parsed = ActionItems.parse(summary)
        XCTAssertEqual(parsed.map(\.text), ["Angebot schicken", "Raum buchen", "Bericht schreiben", "Wir nehmen Variante B", "Checkbox irgendwo"])
        XCTAssertEqual(parsed[0].owner, "Anna")
        XCTAssertTrue(parsed[1].done && parsed[1].isCheckbox)
        XCTAssertEqual(parsed[3].kind, .decision)
    }

    func testOwnerOnlyForShortTail() {
        XCTAssertEqual(ActionItems.splitOwner("Text").0, "Text")
        XCTAssertNil(ActionItems.splitOwner("Text").1)
        XCTAssertEqual(ActionItems.splitOwner("Plan - fertig – Ben").0, "Plan - fertig")
        XCTAssertEqual(ActionItems.splitOwner("Plan - fertig – Ben").1, "Ben")
        XCTAssertNil(ActionItems.splitOwner("A – das ist ein sehr langer Rest mit vielen Wörtern").1)
    }

    func testSyncCreatesKeepsAndDeletes() {
        let note = note()
        ActionItems.sync(note, in: context)
        XCTAssertEqual(items(note).count, 5)
        ActionItems.sync(note, in: context)
        XCTAssertEqual(items(note).count, 5, "a second run changes nothing")
        note.summary = summary.replacingOccurrences(of: "- Wir nehmen Variante B\n", with: "")
        ActionItems.sync(note, in: context)
        XCTAssertFalse(items(note).contains { $0.text == "Wir nehmen Variante B" })
        XCTAssertEqual(items(note).first { $0.text == "Checkbox irgendwo" }?.order, 3)
    }

    func testTickingRewritesTheSummaryLineAndCountsAsAnEdit() throws {
        let note = note()
        ActionItems.sync(note, in: context)
        let plain = try XCTUnwrap(items(note).first { $0.text == "Angebot schicken" })
        note.updatedAt = .distantPast
        ActionItems.setDone(plain, true, note: note, in: context)
        XCTAssertTrue(note.summary?.contains("- [x] Angebot schicken – Anna") == true)
        XCTAssertGreaterThan(note.updatedAt, .distantPast, "without it the tick loses a conflict in the sync")
        let box = try XCTUnwrap(items(note).first { $0.text == "Raum buchen" })
        ActionItems.setDone(box, false, note: note, in: context)
        XCTAssertTrue(note.summary?.contains("- [ ] Raum buchen") == true)
    }

    func testRenamedTaskStillMatchesItsLine() throws {
        let note = note()
        ActionItems.sync(note, in: context)
        try XCTUnwrap(items(note).first { $0.text == "Bericht schreiben" }).text = "Quartalsbericht"
        ActionItems.sync(note, in: context)
        XCTAssertEqual(items(note).count, 5)
        XCTAssertFalse(items(note).contains { $0.text == "Bericht schreiben" })
    }

    func testTouchedTasksStayWhenTheirLineGoes() throws {
        let note = note()
        ActionItems.sync(note, in: context)
        try XCTUnwrap(items(note).first { $0.text == "Bericht schreiben" }).details = "Zahlen von Q3"
        note.summary = "## Aufgaben\n- Angebot schicken – Anna"
        ActionItems.sync(note, in: context)
        XCTAssertEqual(items(note).first { $0.text == "Bericht schreiben" }?.source, "kept")
        XCTAssertFalse(items(note).contains { $0.text == "Wir nehmen Variante B" })
    }

    func testPagesNeverGiveTasks() {
        let page = note(url: "https://example.com")
        ActionItems.sync(page, in: context)
        XCTAssertTrue(items(page).isEmpty)
        // Items from before the rule go, even ticked ones.
        page.url = nil
        ActionItems.sync(page, in: context)
        items(page).forEach { $0.isDone = true }
        page.url = "https://example.com"
        ActionItems.sync(page, in: context)
        XCTAssertTrue(items(page).isEmpty)
    }

    func testNewTasksWaitForReview() throws {
        let note = note()
        ActionItems.sync(note, in: context)
        XCTAssertTrue(try XCTUnwrap(items(note).first { $0.text == "Angebot schicken" }).needsReview)
        // Already ticked in the summary, and decisions, need no review.
        XCTAssertEqual(items(note).first { $0.text == "Raum buchen" }?.review, .accepted)
        XCTAssertEqual(items(note).first { $0.text == "Wir nehmen Variante B" }?.review, .accepted)
        // Items from before the review count as accepted.
        XCTAssertEqual(ActionItem().review, .accepted)
    }

    func testDismissedTasksAreNotMadeAgain() throws {
        let note = note()
        ActionItems.sync(note, in: context)
        ActionItems.dismiss(try XCTUnwrap(items(note).first { $0.text == "Angebot schicken" }), in: context)
        ActionItems.sync(note, in: context)
        XCTAssertEqual(items(note).filter { $0.text == "Angebot schicken" }.count, 1)
        XCTAssertEqual(items(note).first { $0.text == "Angebot schicken" }?.review, .dismissed)
    }

    // MARK: Ticking a line in the summary

    func testTappingABoxInALinksSummaryDoesNothing() throws {
        // Used to call itself until the stack overflowed: a page's summary never gets items.
        let page = note(url: "https://example.com")
        let line = try XCTUnwrap(ActionItems.parse(summary).first { $0.isCheckbox }).line
        ActionItems.toggleSummaryLine(line, of: page, in: context)
        XCTAssertTrue(items(page).isEmpty)
        XCTAssertEqual(page.summary, summary)
    }

    func testTappingABoxInAnOldSummaryMakesTheItemsFirst() throws {
        let note = note()
        let line = try XCTUnwrap(ActionItems.parse(summary).first { $0.text == "Checkbox irgendwo" }).line
        XCTAssertTrue(items(note).isEmpty)
        ActionItems.toggleSummaryLine(line, of: note, in: context)
        XCTAssertEqual(items(note).first { $0.text == "Checkbox irgendwo" }?.isDone, true)
        XCTAssertTrue(note.summary?.contains("- [x] Checkbox irgendwo") == true)
    }

    func testTheSecondOfTwoEqualLinesTicksTheSecondItem() throws {
        let note = note(summary: "- [ ] Anrufen\n- [ ] Anrufen")
        ActionItems.toggleSummaryLine(1, of: note, in: context)
        XCTAssertEqual(note.summary, "- [ ] Anrufen\n- [x] Anrufen")
    }
}
