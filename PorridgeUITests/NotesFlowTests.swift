import XCTest

final class NotesFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// "Create Note" must open the new note and keep it open.
    func testCreateNoteStaysOpen() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES"]
        app.launch()

        let create = app.buttons["Create Note"]
        XCTAssertTrue(create.waitForExistence(timeout: 30), "Create Note button missing")
        create.tap()

        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "note did not open")
        sleep(3)
        XCTAssertTrue(title.exists, "note closed again by itself")
        XCTAssertFalse(app.buttons["Create Note"].exists, "list is showing again")
    }
}

extension NotesFlowTests {
    /// Create a note, leave it empty, go back, create another one: it must open and stay open.
    func testCreateNoteTwiceAfterLeavingEmpty() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES"]
        app.launch()

        for attempt in 1...3 {
            let create = app.buttons["Create Note"]
            XCTAssertTrue(create.waitForExistence(timeout: 30), "Create Note missing (attempt \(attempt))")
            create.tap()

            let title = app.textFields["Title"]
            if !title.waitForExistence(timeout: 10) {
                print("SCREEN after attempt \(attempt):\n\(app.debugDescription)")
            }
            XCTAssertTrue(title.exists, "note did not open (attempt \(attempt))")
            sleep(2)
            XCTAssertTrue(title.exists, "note closed by itself (attempt \(attempt))")

            // Back to the list without typing anything, and give the animation time to finish.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["Create Note"].waitForExistence(timeout: 10), "list missing after going back (attempt \(attempt))")
            sleep(2)
        }
    }
}

extension NotesFlowTests {
    /// A note with content is kept and can be opened again from the list.
    func testNoteWithContentIsKeptAndReopens() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES"]
        app.launch()

        let name = "Kept \(Int(Date().timeIntervalSince1970))"
        XCTAssertTrue(app.buttons["Create Note"].waitForExistence(timeout: 30))
        app.buttons["Create Note"].tap()
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.tap()
        title.typeText(name)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        sleep(2)

        // The note is in the list (earlier runs leave pinned notes on top, so search for it); tapping it opens it again.
        app.buttons["Search"].tap()
        let search = app.textFields["SearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(name)
        let row = app.staticTexts[name]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "note with a title was not kept")
        row.tap()
        // The title field now shows the note's title instead of its placeholder.
        let reopened = app.textFields.matching(NSPredicate(format: "value == %@", name)).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10), "note did not open from the list")
    }
}
