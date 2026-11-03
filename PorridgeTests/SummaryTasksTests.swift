import SwiftData
import XCTest
@testable import Porridge

/// The same cases as Android's `SummaryTasksLogicTest`, on a store in memory.
@MainActor
final class SummaryTasksTests: XCTestCase {
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

    func testFindsTaskLinesInAnyLanguage() {
        let parsed = SummaryTasks.parse(summary)
        XCTAssertEqual(parsed.map(\.text), ["Angebot schicken – Anna", "Raum buchen", "Bericht schreiben", "Checkbox irgendwo"])
        XCTAssertTrue(parsed[1].done && parsed[1].isCheckbox)
    }

    func testTickingACheckboxChangesItsLine() throws {
        let note = note()
        let line = try XCTUnwrap(SummaryTasks.parse(summary).first { $0.text == "Checkbox irgendwo" }).line
        SummaryTasks.toggleLine(line, of: note, in: context)
        XCTAssertTrue(note.summary?.contains("- [x] Checkbox irgendwo") == true)
        SummaryTasks.toggleLine(line, of: note, in: context)
        XCTAssertEqual(note.summary, summary)
    }

    func testTickingAPlainBulletMakesItACheckbox() throws {
        let note = note()
        let line = try XCTUnwrap(SummaryTasks.parse(summary).first { $0.text.hasPrefix("Angebot") }).line
        SummaryTasks.toggleLine(line, of: note, in: context)
        XCTAssertTrue(note.summary?.contains("- [x] Angebot schicken – Anna") == true)
    }

    func testOnlyTheTappedOfTwoEqualLinesIsTicked() {
        let note = note(summary: "- [ ] Anrufen\n- [ ] Anrufen")
        SummaryTasks.toggleLine(1, of: note, in: context)
        XCTAssertEqual(note.summary, "- [ ] Anrufen\n- [x] Anrufen")
    }

    func testTappingABoxInALinksSummaryDoesNothing() throws {
        let page = note(url: "https://example.com")
        let line = try XCTUnwrap(SummaryTasks.parse(summary).first { $0.isCheckbox }).line
        SummaryTasks.toggleLine(line, of: page, in: context)
        XCTAssertEqual(page.summary, summary)
    }
}
