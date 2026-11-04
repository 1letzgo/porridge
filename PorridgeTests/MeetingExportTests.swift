import PDFKit
import XCTest
@testable import Porridge

final class MeetingExportTests: XCTestCase {
    private let lines = [
        MeetingExport.Line(time: "0:05", speaker: "Anna", text: "Wir beginnen mit dem Budget."),
        MeetingExport.Line(time: "0:12", speaker: nil, text: "Ohne Sprecher."),
    ]
    private let summary = "## Key Points\n- **Budget** steht\n## Action Items\n- [ ] Angebot schicken\n- [x] Raum buchen\nEin Absatz."

    func testTextHasOnlyWhatWasChosen() {
        let onlySummary = MeetingExport(title: "Weekly", date: "3. Nov", summary: summary, transcript: []).plainText
        XCTAssertTrue(onlySummary.hasPrefix("Weekly\n\n3. Nov\n\nSummary\n\n"))
        XCTAssertTrue(onlySummary.contains("Key Points\n- Budget steht"))
        XCTAssertTrue(onlySummary.contains("- [ ] Angebot schicken"))
        XCTAssertFalse(onlySummary.contains("Transcript"))
        XCTAssertFalse(onlySummary.contains("#"))

        let onlyTranscript = MeetingExport(title: "Weekly", date: "3. Nov", summary: nil, transcript: lines).plainText
        XCTAssertFalse(onlyTranscript.contains("Summary"))
        XCTAssertTrue(onlyTranscript.contains("[0:05] Anna: Wir beginnen mit dem Budget.\n[0:12] Ohne Sprecher."))
    }

    func testPDFHoldsTheContentAndRunsOverPages() throws {
        let long = (0..<400).map { MeetingExport.Line(time: "\($0):00", speaker: "Anna", text: "Satz Nummer \($0) dieses langen Gesprächs, damit es über mehrere Seiten geht.") }
        let export = MeetingExport(title: "Weekly / Budget", date: "3. Nov 2026", summary: summary, transcript: long)
        let url = try export.write(.pdf)
        XCTAssertEqual(url.lastPathComponent, "Weekly   Budget.pdf")
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(document.pageCount, 3)
        let text = try XCTUnwrap(document.string)
        XCTAssertTrue(text.contains("Weekly / Budget"))
        XCTAssertTrue(text.contains("Angebot schicken"))
        XCTAssertTrue(text.contains("Satz Nummer 0 "))
        XCTAssertTrue(text.contains("Satz Nummer 399 "))
        XCTAssertFalse(text.contains("**"))
        try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: "/tmp/porridge-export-test.pdf"))
    }
}
