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
        // The meta line under the title counts them ("To-do · 24 Nov · 1 of 2 subtasks").
        let progress = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '1 of 2 subtasks'")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5), "ticking a subtask did not count")
        app.buttons["Done"].firstMatch.tap()

        // Due today, from the Due row of Details.
        app.openDetails()
        let due = app.buttons["Due Date"].firstMatch
        XCTAssertTrue(due.waitForExistence(timeout: 5), "Due row missing in Details")
        due.tap()
        let today = app.buttons["Today"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 5), "due date menu missing")
        today.tap()
        screenshot("todo-details-due", app)
        app.closeDetails()
        // The head's meta line now names the day.
        let meta = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Today'")).firstMatch
        XCTAssertTrue(meta.waitForExistence(timeout: 5), "due date not set")
        screenshot("todo-detail", app)

        app.goBack()
        app.openTab("Inbox")
        let row = app.staticTexts[title]
        XCTAssertTrue(app.reveal(row), "to-do not in the inbox")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Due Today'")).firstMatch.exists,
                      "due date missing in the row")
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

    /// A summarized meeting offers its tasks as to-dos: the user's and nobody's are picked, Anna's is not; taking
    /// them on makes two to-dos in the meeting's bowl, and the suggestions are gone.
    func testSuggestedTodosFromAMeetingAreTakenOn() throws {
        let title = unique("Launch")
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO",
                                "-myName", "Me", "-seedMeetingWithTasks", title]
        app.launch()

        // The meeting's bowl is in the Bowls place.
        app.openTab("Bowls")
        let bucket = app.staticTexts[title].firstMatch
        XCTAssertTrue(app.reveal(bucket), "bowl of the meeting missing")
        bucket.tap()
        let hint = app.staticTexts["3 suggested to-dos"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 10), "the meeting row does not say that to-dos wait")
        screenshot("meeting-suggested-todos-row", app)
        hint.tap()

        XCTAssertTrue(app.staticTexts["Suggested To-dos"].waitForExistence(timeout: 10), "no suggestions on the meeting's page")
        let add = app.buttons["AddSuggestedTodos"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "Add 2 To-dos", "the user's and nobody's tasks are not the ones picked")
        screenshot("meeting-suggested-todos", app)
        add.tap()

        XCTAssertTrue(app.staticTexts["Suggested To-dos"].waitForNonExistence(timeout: 5), "suggestions stay after taking them on")
        XCTAssertTrue(app.buttons["Send the offer to the customer"].waitForExistence(timeout: 5)
                      || app.staticTexts["Send the offer to the customer"].exists, "made to-do missing on the meeting's page")
        // Each task is on the page once: the made to-dos list them, the summary leaves them out.
        XCTAssertEqual(app.staticTexts.matching(identifier: "Send the offer to the customer").count, 1, "a taken task shows twice")
        XCTAssertEqual(app.staticTexts.matching(identifier: "Update the roadmap").count, 1, "a taken task shows twice")
        screenshot("meeting-suggested-todos-taken", app)

        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["To-dos"].firstMatch.waitForExistence(timeout: 10), "no to-dos in the bowl")
        XCTAssertTrue(app.staticTexts["Send the offer to the customer"].exists, "the user's task is not a to-do")
        XCTAssertTrue(app.staticTexts["Update the roadmap"].exists, "nobody's task is not a to-do")
        XCTAssertFalse(app.staticTexts["Book the venue"].exists, "Anna's task became a to-do without being picked")
        XCTAssertFalse(app.staticTexts["3 suggested to-dos"].exists, "the row still says that to-dos wait")
    }

    /// The to-dos folder under the Inbox: every open to-do by due day, the longest overdue first; ticked there, it
    /// stays for today under "Done Today".
    func testTodosFolderListsOpenTodosByDueDay() throws {
        let prefix = unique("Folder")
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-seedTodos", prefix]
        app.launch()

        // Open To-dos is the Inbox's To-dos side (owner revision 9).
        app.openTab("Inbox")
        let entry = app.inboxSegment(1)
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "no To-dos side in the Inbox")
        screenshot("inbox-todos-folder-home", app)
        entry.tap()

        XCTAssertTrue(app.staticTexts["Overdue"].firstMatch.waitForExistence(timeout: 10), "no Overdue group")
        let first = app.staticTexts["\(prefix) long overdue"]
        XCTAssertTrue(first.waitForExistence(timeout: 5), "the longest overdue to-do is not on top")
        // It names its bowl: the row's label holds the prefix twice, in the title and as the bowl.
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "\(prefix) long overdue, ")).firstMatch
        XCTAssertTrue(row.exists, "row of the overdue to-do missing")
        XCTAssertEqual(row.label.components(separatedBy: prefix).count - 1, 2, "the row does not name its bowl: \(row.label)")
        screenshot("inbox-todos-folder", app)

        // Ticked in the folder, it goes to Done Today.
        let box = app.switches.matching(NSPredicate(format: "label == 'To-do' AND value == 'Not Done'")).firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 5))
        box.tap()
        XCTAssertTrue(app.reveal(app.staticTexts["Done Today"]), "no Done Today group after ticking")

        // Its own plus makes a to-do right here ("+" of the tab bar opens the Add sheet).
        let newTodo = app.buttons["TodosAdd"]
        XCTAssertTrue(app.revealAbove(newTodo), "Open To-dos has no New To-do")
        newTodo.tap()
        XCTAssertTrue(app.waitForTitleField(), "the plus did not make a to-do")
        XCTAssertTrue(app.switches["To-do"].firstMatch.waitForExistence(timeout: 5), "the plus made a note, not a to-do")
    }
}

