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
}
