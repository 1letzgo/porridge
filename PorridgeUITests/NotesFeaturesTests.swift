import XCTest

final class NotesFeaturesTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func typeInBody(_ app: XCUIApplication, _ text: String) {
        app.typeText(text)
        usleep(350_000)
    }

    func testListsContinueInTheEditor() throws {
        let app = launchApp()
        app.newNote()
        let editor = app.bodyEditor
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor missing")
        editor.tap()
        typeInBody(app, "Plan\n")
        typeInBody(app, "- one\n")
        typeInBody(app, "two\n")
        // Return on the empty item ends the list.
        typeInBody(app, "\n")
        typeInBody(app, "after")
        let value = try XCTUnwrap(editor.value as? String)
        for line in ["Plan", "one", "two", "after"] {
            XCTAssertTrue(value.contains(line), "\(line) missing in: \(value)")
        }
        XCTAssertFalse(value.contains("- two"), "the list mark stays out of the text: \(value)")
        XCTAssertTrue(app.buttons["Checklist"].exists, "format bar missing")
    }

    func testHeadScrollsAwayWithTheText() throws {
        let app = launchApp()
        app.newNote()
        let editor = app.bodyEditor
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "editor missing")
        editor.tap()
        typeInBody(app, (1...40).map { "Line \($0)" }.joined(separator: "\n"))
        app.buttons["Done"].firstMatch.tap()

        for _ in 0..<4 { app.swipeDown() }
        let top = app.titleField.frame.minY
        app.swipeUp()
        // Scrolled off the screen, the title reports no position at all.
        let moved = app.titleField.frame.minY
        XCTAssertTrue(moved.isInfinite || moved < top - 100, "the head stays in place: \(top) -> \(moved)")
    }

    func testChecklistTextStaysClearOfTheBoxAndPlaceholder() throws {
        let app = launchApp()
        app.newNote()
        let editor = app.bodyEditor
        editor.tap()
        // The placeholder is the empty editor's value (no element of its own, so VoiceOver never reads it over text).
        let placeholder = "Start typing or dictate…"
        XCTAssertEqual(editor.value as? String, placeholder, "placeholder missing in the empty note")
        app.buttons["Checklist"].tap()
        app.typeText("Buy milk\nCall Maya\n")
        let value = editor.value as? String ?? ""
        XCTAssertTrue(value.contains("Buy milk"), "typed text missing: \(value)")
        XCTAssertFalse(value.contains(placeholder), "placeholder over the typed text: \(value)")
    }

    func testPinAndTrash() throws {
        let app = launchApp()
        let name = unique("Trash")
        app.newNote(title: name)
        app.goBack()
        // A new note waits in the inbox, the newest on top.
        app.openTab("Inbox")
        let row = app.staticTexts[name]
        XCTAssertTrue(app.reveal(row), "new note missing in the inbox")

        row.press(forDuration: 1.2)
        let pin = app.buttons["Pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "row menu missing")
        pin.tap()

        // Its menu now offers to unpin.
        XCTAssertTrue(app.reveal(app.staticTexts[name]), "pinned note missing")
        app.staticTexts[name].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 5), "note was not pinned")

        // Delete it from the list: it goes to Recently Deleted.
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertFalse(app.staticTexts[name].waitForExistence(timeout: 3), "note still in the inbox")

        // Recently Deleted is the Deleted side of the Bowls tab's switch.
        app.openTab("Bowls")
        app.bowlsSide("Deleted")
        XCTAssertTrue(app.reveal(app.staticTexts[name]), "note not in the trash")
        app.bowlsSide("Bowls")
    }

    func testTagIsOfferedInTheSearch() throws {
        let app = launchApp()
        let title = unique("Tagged")
        let tag = "field\(UUID().uuidString.prefix(6).lowercased())"
        app.newNote(title: title)
        app.titleField.typeText("\n")
        // Tags are a row of Details.
        app.openDetails()
        XCTAssertTrue(app.buttons["Add Tag"].waitForExistence(timeout: 5))
        app.buttons["Add Tag"].tap()
        let input = app.textFields["Tag"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText(tag)
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["#\(tag)"].waitForExistence(timeout: 5), "tag missing in Details")
        app.closeDetails()
        app.goBack()

        // The search offers the tags as chips; picking one filters the notes.
        app.openTab("Search")
        app.searchSide("Search")
        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "#\(tag)")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "tag not offered")
        suggestion.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "note missing after filtering by the tag")
    }

    func testSearchNarrowsTheResults() throws {
        let app = launchApp()
        let alpha = unique("Alpha"), beta = unique("Beta")
        for title in [alpha, beta] {
            app.newNote(title: title)
            app.goBack()
        }
        app.search(for: alpha)
        XCTAssertNotNil(app.searchResult(alpha), "search did not find the note")
        XCTAssertNil(app.searchResult(beta, timeout: 2), "search did not filter")

        // The other way round: the card would show the other note if it matched.
        app.searchAgain(for: beta)
        XCTAssertNotNil(app.searchResult(beta), "search did not find the other note")
        XCTAssertNil(app.searchResult(alpha, timeout: 2), "search did not filter")
    }

    func testProjectIsCreatedAndPinned() throws {
        let app = launchApp()
        let name = unique("Project")
        app.create("Bowl")
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "name field missing")
        field.typeText(name)
        app.confirmAlert("Create")
        // A new project opens or shows in the list; go back to the list if it opened.
        if !app.buttons["BowlSort"].waitForExistence(timeout: 3) { app.goBack() }
        let back = app.buttons["Back"]
        if back.waitForExistence(timeout: 2) { back.tap() }
        let row = app.staticTexts[name]
        XCTAssertTrue(app.reveal(row), "new project missing")

        row.press(forDuration: 1.2)
        let pin = app.buttons["Pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "project menu missing")
        pin.tap()

        // A pinned project moves to the top. Its menu now offers to unpin.
        XCTAssertTrue(app.revealAbove(app.staticTexts[name]), "pinned project missing")
        app.staticTexts[name].press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Unpin"].waitForExistence(timeout: 5), "project was not pinned")

        // Clean up, so runs do not pile projects up.
        let delete = app.buttons["Delete Bowl…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Delete Bowl… missing in the bowl's menu")
        delete.tap()
        app.confirmAlert("Delete Bowl")
        XCTAssertTrue(app.staticTexts[name].waitForNonExistence(timeout: 5), "deleted bowl still listed")
    }
}
