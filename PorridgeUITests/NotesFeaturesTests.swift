import XCTest

final class NotesFeaturesTests: XCTestCase {
    private let shots = "/private/var/folders/bp/wtvd3wcs1qsdhdjq5fpx2kp40000gn/T/opencode"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES"]
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func blockFields(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "NoteBlock")
    }

    /// Values of all lines of the open note, without the invisible start character.
    private func lines(_ app: XCUIApplication) -> [String] {
        let query = blockFields(app)
        return (0..<query.count).map { (query.element(boundBy: $0).value as? String ?? "").replacingOccurrences(of: "\u{200B}", with: "") }
    }

    /// Types like a person: the editor moves the focus when a line breaks.
    private func type(_ app: XCUIApplication, _ text: String) {
        app.typeText(text)
        usleep(350_000)
    }

    /// Earlier runs leave pinned notes on top, so a new note can be below the fold: scroll until it shows.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<12 where !element.exists { app.swipeUp() }
        guard element.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
        return true
    }

    private func newNote(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Create Note"].waitForExistence(timeout: 30))
        app.buttons["Create Note"].tap()
        let first = blockFields(app).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "editor missing")
        first.tap()
    }

    func testListsContinueAndFormatting() throws {
        let app = launch()
        newNote(app)
        type(app, "Plan")
        type(app, "\n")
        type(app, "- ")
        type(app, "one")
        type(app, "\n")
        type(app, "two")
        type(app, "\n")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == '•'")).count, 3, "bullets missing")
        // Return on the empty item ends the list.
        type(app, "\n")
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == '•'")).count, 2)
        type(app, "after")
        XCTAssertEqual(lines(app), ["Plan", "one", "two", "after"])

        app.buttons["Checklist"].tap()
        type(app, "!")
        type(app, "\n")
        type(app, "next")
        XCTAssertEqual(app.buttons.matching(identifier: "Checkbox").count, 2)
        shot(app, "editor")
    }

    func testFolderAndTrash() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Create Note"].waitForExistence(timeout: 30))
        let folder = "Work\(Int(Date().timeIntervalSince1970))"

        // Folders are a drop-down at the top left.
        app.buttons["Folders"].tap()
        let newFolder = app.buttons["New Folder"]
        XCTAssertTrue(newFolder.waitForExistence(timeout: 10), "folder menu missing")
        shot(app, "folder-menu")
        newFolder.tap()
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(folder)
        app.alerts.buttons["Save"].tap()

        app.buttons["Folders"].tap()
        let folderItem = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch
        XCTAssertTrue(folderItem.waitForExistence(timeout: 5), "folder not created")
        folderItem.tap()

        // A note created in the folder lands in it.
        newNote(app)
        app.typeText("Meeting notes")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Meeting notes"].waitForExistence(timeout: 10))
        shot(app, "folder-list")

        // Delete it from the list: it goes to Recently Deleted.
        app.staticTexts["Meeting notes"].press(forDuration: 1.2)
        app.buttons["Delete"].tap()
        XCTAssertFalse(app.staticTexts["Meeting notes"].waitForExistence(timeout: 3))

        app.buttons["Folders"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Recently Deleted")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Meeting notes"].waitForExistence(timeout: 5), "note not in trash")
        shot(app, "trash")

        // Clean up: the folder created above goes again (so runs do not pile folders up in the menu).
        app.buttons["Folders"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", folder)).firstMatch.tap()
        app.buttons["Folders"].tap()
        app.buttons["Delete Folder"].tap()
        let confirm = app.buttons["Delete Folder"]
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }
    }

    func testChecklistBoxToggleAndBackspace() throws {
        let app = launch()
        newNote(app)
        app.buttons["Checklist"].tap()
        type(app, "milk")
        let box = app.buttons["Checkbox"].firstMatch
        XCTAssertEqual(box.label, "Not checked")
        box.tap()
        XCTAssertEqual(app.buttons["Checkbox"].firstMatch.label, "Checked")
        shot(app, "checked")

        // Backspace right at the start of an empty item removes the box first, then the line joins the one above.
        app.buttons["Checkbox"].firstMatch.tap()
        blockFields(app).firstMatch.tap()
        type(app, "\n")
        XCTAssertEqual(app.buttons.matching(identifier: "Checkbox").count, 2)
        type(app, XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(app.buttons.matching(identifier: "Checkbox").count, 1, "box not removed")
        type(app, XCUIKeyboardKey.delete.rawValue)
        XCTAssertEqual(lines(app), ["milk"])
    }

    func testTagFieldAndSearchSuggestions() throws {
        let app = launch()
        let stamp = Int(Date().timeIntervalSince1970)
        let tag = "field\(stamp)"
        let title = "Tagged\(stamp)"

        newNote(app)
        let field = app.textFields["Title"]
        field.tap()
        field.typeText(title)
        XCTAssertTrue(app.buttons["Add Tag"].waitForExistence(timeout: 5))
        app.buttons["Add Tag"].tap()
        let input = app.textFields["Tag"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText(tag)
        app.alerts.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["#\(tag)"].waitForExistence(timeout: 5), "tag chip missing")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // The Search view offers the tags as chips; picking one filters the notes.
        XCTAssertTrue(app.buttons["Search"].waitForExistence(timeout: 10))
        app.buttons["Search"].tap()
        let suggestion = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "#\(tag)")).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "tag not offered")
        shot(app, "tag-suggestions")
        suggestion.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "note missing after filtering by the tag")
    }

    func testSearchPinAndTags() throws {
        let app = launch()
        let stamp = Int(Date().timeIntervalSince1970)
        let alpha = "Alpha\(stamp)", beta = "Beta\(stamp)"

        for (title, text) in [(alpha, "about #tag\(stamp)"), (beta, "other")] {
            newNote(app)
            let field = app.textFields["Title"]
            field.tap()
            field.typeText(title)
            blockFields(app).firstMatch.tap()
            app.typeText(text)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(reveal(app.staticTexts[title], in: app), "\(title) missing in the list")
        }

        // Pin Beta: it moves into the "Pinned" section. The search narrows the list to it first, so it sits at the top.
        app.buttons["Search"].tap()
        let finder = app.textFields["SearchField"]
        XCTAssertTrue(finder.waitForExistence(timeout: 5))
        finder.tap()
        finder.typeText(beta)
        XCTAssertTrue(app.staticTexts[beta].waitForExistence(timeout: 5))
        app.staticTexts[beta].press(forDuration: 1.2)
        app.buttons["Pin"].tap()
        XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 5), "no pinned section")
        shot(app, "pinned")
        app.buttons["Clear text"].tap()

        // Search narrows the list.
        let search = app.textFields["SearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Alpha\(stamp)")
        XCTAssertTrue(app.staticTexts[alpha].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[beta].exists, "search did not filter")
        app.buttons["Timeline"].tap()

        // The tags are in the folder menu too (the list of tags can be long after many runs: only check that it is there).
        app.buttons["Folders"].tap()
        XCTAssertTrue(app.buttons["Tags"].waitForExistence(timeout: 5), "no tags in the folder menu")
        shot(app, "tags")
    }
}
