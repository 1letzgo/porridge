import XCTest

extension XCTestCase {
    /// The app without onboarding and without sync, so a run stays on this simulator.
    func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO"]
        app.launch()
        return app
    }

    /// A title no earlier run left behind.
    func unique(_ prefix: String) -> String {
        "\(prefix) \(UUID().uuidString.prefix(8))"
    }
}

extension XCUIApplication {
    var titleField: XCUIElement { textViews["Title"].exists ? textViews["Title"] : textFields["Title"] }

    /// The body of the open note: one native text view.
    var bodyEditor: XCUIElement { textViews.matching(NSPredicate(format: "label != 'Title'")).firstMatch }

    /// One of the options behind the plus at the bottom right.
    func create(_ option: String) {
        let plus = buttons["Create"]
        XCTAssertTrue(plus.waitForExistence(timeout: 30), "plus button missing")
        plus.tap()
        let choice = buttons.matching(NSPredicate(format: "label ENDSWITH %@", option)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(option) missing behind the plus")
        choice.tap()
    }

    func newNote(title: String? = nil) {
        create("Note")
        XCTAssertTrue(waitForTitleField(), "note did not open")
        if let title {
            titleField.tap()
            titleField.typeText(title)
        }
    }

    func waitForTitleField(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if titleField.exists { return true }
            usleep(200_000)
        }
        return false
    }

    func goBack() {
        navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(buttons["Create"].waitForExistence(timeout: 10), "list missing after going back")
    }

    /// Earlier runs leave notes behind, so a new row can be below the fold.
    func reveal(_ element: XCUIElement) -> Bool {
        for _ in 0..<25 where !element.exists { swipeUp() }
        guard element.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<4 where !element.isHittable { swipeUp() }
        return true
    }

    /// Same upwards: for a row that moved to the top of the list.
    func revealAbove(_ element: XCUIElement) -> Bool {
        for _ in 0..<12 where !element.isHittable { swipeDown() }
        return element.isHittable
    }

    func search(for text: String) {
        buttons["Search"].tap()
        let field = textFields["SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search field missing")
        field.tap()
        field.typeText(text)
    }

    /// Replaces the text in the open search.
    func searchAgain(for text: String) {
        let field = textFields["SearchField"]
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + text)
    }

    /// A row of the search card. The full-width list stays in the hierarchy behind the card and even counts as
    /// hittable there, so the card's list is told apart by its inset.
    func searchResult(_ title: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for list in collectionViews.allElementsBoundByIndex where list.frame.minX > 0 {
                let row = list.staticTexts[title]
                if row.exists { return row }
            }
            usleep(200_000)
        } while Date() < deadline
        return nil
    }
}
