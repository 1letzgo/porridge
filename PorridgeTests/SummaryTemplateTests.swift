import XCTest
@testable import Porridge

@MainActor
final class SummaryTemplateTests: XCTestCase {
    private let german = SummaryLanguage(code: "de")

    func testGeneralTemplateKeepsTheStandardSections() {
        let prompt = SummaryService.systemPrompt(german, template: .general)
        XCTAssertTrue(prompt.contains("## Wichtige Punkte"))
        XCTAssertTrue(prompt.contains("## Entscheidungen"))
    }

    func testTemplateReplacesTheMiddleSectionsButNotTasksAndTags() throws {
        let template = try XCTUnwrap(SummaryTemplate.builtIn.first { $0.id == "customer" })
        let prompt = SummaryService.systemPrompt(german, template: template)
        XCTAssertTrue(prompt.contains(template.focus))
        XCTAssertTrue(prompt.contains("## <\"Customer Needs\" in German>"))
        XCTAssertFalse(prompt.contains("## Wichtige Punkte"))
        XCTAssertTrue(prompt.contains("## Zusammenfassung"))
        XCTAssertTrue(prompt.contains("## Aufgaben"))
        XCTAssertTrue(prompt.contains("TITLE:"))
        XCTAssertTrue(prompt.contains("TAGS:"))
    }

    func testCustomTemplateKeepsStandardSectionsAndAddsItsFocus() {
        let template = SummaryTemplate(id: "x", name: "Prices", focus: "Note every price.", sections: nil)
        let prompt = SummaryService.systemPrompt(german, template: template)
        XCTAssertTrue(prompt.contains("Note every price."))
        XCTAssertTrue(prompt.contains("## Wichtige Punkte"))
    }

    func testMeetingPromptForbidsInventingAndAsksForOwnerAndDueDate() {
        let prompt = SummaryService.systemPrompt(german, template: .general)
        XCTAssertTrue(prompt.contains("Only use what is in the transcript"))
        XCTAssertTrue(prompt.contains("<owner, if known> – <due date, if named>"))
    }

    func testNewTemplatesKeepClearOfTheTaskHeadings() throws {
        for id in ["team", "interview"] {
            let template = try XCTUnwrap(SummaryTemplate.builtIn.first { $0.id == id })
            for section in template.sections ?? [] {
                XCTAssertTrue(SummaryTasks.parse("## \(section)\n- Ein Punkt").isEmpty, section)
            }
        }
    }

    func testOnlyMeetingNotesMarkTasks() {
        XCTAssertTrue(SummaryService.notesPrompt(german, noun: "meeting").contains("TASK:"))
        XCTAssertFalse(SummaryService.notesPrompt(german, noun: "note").contains("TASK:"))
    }

    func testTaskLinesWithoutAListMarkGetOne() {
        XCTAssertEqual(SummaryService.withListMarks("Text\n[ ] Anna ruft an\n- [ ] Tom schreibt\n[x] Lisa"), "Text\n- [ ] Anna ruft an\n- [ ] Tom schreibt\n- [x] Lisa")
    }

    func testNotesLookAtTheFocusToo() {
        let prompt = SummaryService.notesPrompt(german, noun: "meeting", focus: "Note every price.")
        XCTAssertTrue(prompt.contains("Note every price."))
    }

    func testPartsNameTheHeaderAndRepeatTheEndOfThePreviousPart() {
        let material = (1...40).map { "Line \($0) of the meeting" }.joined(separator: "\n")
        let prompts = SummaryService.partPrompts(of: material, header: "Participants: Anna, Tom", size: 300)
        XCTAssertGreaterThan(prompts.count, 1)
        XCTAssertTrue(prompts.allSatisfy { $0.hasPrefix("Participants: Anna, Tom") })
        XCTAssertFalse(prompts[0].contains("previous part"))
        XCTAssertTrue(prompts[1].contains("previous part"))
        // Every line of the text still comes along.
        for number in 1...40 {
            XCTAssertTrue(prompts.contains { $0.contains("Line \(number) of the meeting") })
        }
    }
}
