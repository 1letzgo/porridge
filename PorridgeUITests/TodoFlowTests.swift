import XCTest

/// A to-do on screen: made like a note, subtasks in its text, ticked in its page and in the list.
final class TodoFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The box's middle is the middle of the title's first line (`lineHeight`: the empty, one-line field).
    private func assertBox(_ box: CGRect, centeredOn titleTop: CGFloat, lineHeight: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(box.midY, titleTop + lineHeight / 2, accuracy: 3, "box not on the first line of the title", file: file, line: line)
    }

    func testATodoWithSubtasksIsTickedInItsPageAndInTheList() throws {
        let app = launchApp()
        let title = unique("Pack")
        app.create("To-do")
        XCTAssertTrue(app.waitForTitleField(), "to-do did not open")
        // The box stands on the first line of the title, and the title does not move when typing starts
        // (an empty field once sat a line lower than the box).
        let pageBox = app.switches["To-do"].firstMatch
        XCTAssertTrue(pageBox.waitForExistence(timeout: 5), "box missing on the page")
        let empty = app.titleField.frame
        assertBox(pageBox.frame, centeredOn: empty.minY, lineHeight: empty.height)
        app.titleField.tap()
        app.titleField.typeText(title)
        let typed = app.titleField.frame
        XCTAssertEqual(typed.minY, empty.minY, accuracy: 1, "the title moved when typing started")
        assertBox(pageBox.frame, centeredOn: typed.minY, lineHeight: empty.height)

        // Two subtasks: "Add Subtask" puts the cursor into a new checklist line, Return makes the next one.
        let add = app.buttons["Add Subtask"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "Add Subtask missing")
        add.tap()
        app.bodyEditor.typeText("Passport\nTickets")
        // The first circle, at the start of the first line of the body.
        let editor = app.bodyEditor
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 14)).tap()
        let progress = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1 of 2 done'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "ticking a subtask did not count")
        app.buttons["Done"].firstMatch.tap()
        screenshot("todo-detail", app)

        app.goBack()
        let inbox = app.buttons["InboxCategory"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 15), "Inbox missing on the home list")
        inbox.tap()
        let row = app.staticTexts[title]
        XCTAssertTrue(app.reveal(row), "to-do not in the inbox")
        screenshot("todo-list-open", app)

        // The box of the row ticks the to-do; it stays in the list for today.
        let box = app.switches.matching(NSPredicate(format: "label == 'To-do' AND value == 'Not Done'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5), "box missing in the row")
        box.tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label == 'To-do' AND value == 'Done'")).firstMatch.waitForExistence(timeout: 5),
                      "to-do not done")
        XCTAssertTrue(row.exists, "a to-do done today left the list")
        screenshot("todo-list-done", app)
    }
}
