import XCTest

final class NotesFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Creating a note must open it and keep it open.
    func testCreateNoteStaysOpen() throws {
        let app = launchApp()
        app.newNote()
        sleep(3)
        XCTAssertTrue(app.titleField.exists, "note closed again by itself")
        XCTAssertFalse(app.buttons["Create"].isHittable, "list is showing again")
    }

    /// Create a note, leave it empty, go back, create another one: it must open and stay open.
    func testCreateNoteTwiceAfterLeavingEmpty() throws {
        let app = launchApp()
        for attempt in 1...3 {
            app.newNote()
            sleep(2)
            XCTAssertTrue(app.titleField.exists, "note closed by itself (attempt \(attempt))")
            // Back to the list without typing anything, and give the animation time to finish.
            app.goBack()
            sleep(2)
        }
    }

    /// Settings and its subpages open in place; afterwards the list still answers as before.
    func testRecordNewNotesSwitchInSettings() throws {
        let app = launchApp()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "settings button missing")
        settings.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10), "settings did not open")
        XCTAssertTrue(app.reveal(app.switches["Record New Notes Automatically"].firstMatch), "switch missing")
    }

    func testSettingsSubpageAndBack() throws {
        let app = launchApp()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "settings button missing")
        settings.tap()
        let row = app.buttons["Acknowledgements"].firstMatch
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10), "settings did not open")
        XCTAssertTrue(app.reveal(row), "acknowledgements row missing")
        row.tap()
        XCTAssertTrue(app.staticTexts["Libraries"].waitForExistence(timeout: 10), "acknowledgements did not open")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "settings missing after going back")
        app.goBack()
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), "plus did not open its menu")
    }

    /// A note with content is kept and can be opened again from the search.
    func testNoteWithContentIsKeptAndReopens() throws {
        let app = launchApp()
        let name = unique("Kept")
        app.newNote(title: name)
        app.goBack()
        sleep(2)

        app.search(for: name)
        let row = try XCTUnwrap(app.searchResult(name), "note with a title was not kept")
        row.tap()
        // A filled title field is known by its value: the placeholder "Title" is gone.
        let reopened = app.textFields.matching(NSPredicate(format: "value == %@", name)).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10), "note did not open from the search")
    }

    /// The filter is the system menu now; its button says what is chosen.
    func testFilterMenuNarrowsTheList() throws {
        let app = launchApp()
        let filter = app.buttons["HomeFilterButton"]
        XCTAssertTrue(filter.waitForExistence(timeout: 30))
        filter.tap()
        let notes = app.buttons["Notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5), "filter menu did not open")
        notes.tap()
        XCTAssertTrue(app.buttons["Filter: Notes"].waitForExistence(timeout: 5))
    }

    /// VoiceOver sees what this test sees: a row of the list has to be something to press.
    func testNoteRowIsAButtonForAssistiveTechnologies() throws {
        let app = launchApp()
        let title = unique("Row")
        app.create("Note")
        let field = app.titleField
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title)
        app.buttons["Back"].firstMatch.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "row is not a button:\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", title)).firstMatch.waitForExistence(timeout: 10), "row did not open the note")
    }

    /// The largest text size: a picture of the list to look at, and the buttons still there.
    func testLargestTextKeepsTheBottomButtons() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["HomeFilterButton"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Create"].isHittable)
        app.buttons["Create"].tap()
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "largest-text-plus-menu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
