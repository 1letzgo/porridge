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

    /// Presses a button of the alert that is up. With the on-screen keyboard the alert is still moving when it is
    /// first pressed, and the press can miss: it is pressed again while the alert stays.
    func confirmAlert(_ button: String) {
        let alert = alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "alert missing")
        for _ in 0..<3 where alert.exists {
            alert.buttons[button].tap()
            if alert.waitForNonExistence(timeout: 3) { return }
        }
        XCTAssertFalse(alert.exists, "alert did not close")
    }

    /// The "+" pill of the place in front (the last pill of its bar).
    var addButton: XCUIElement {
        buttons.matching(identifier: "PlaceAdd").allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            ?? buttons.matching(identifier: "PlaceAdd").firstMatch
    }

    /// One of the places' tabs: Today, Inbox, Bowls, Search.
    func openTab(_ name: String) {
        let tab = tabBars.buttons[name].exists ? tabBars.buttons[name] : buttons[name].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "tab \(name) missing")
        tab.tap()
    }

    /// One of the choices of the Add sheet ("+" in the bar): Note, To-do, Meeting, Link, Photo or File, New Bowl…
    /// ("Bowl" stands for New Bowl…).
    func create(_ option: String) {
        // An alert that is still going away has a "Create" of its own.
        _ = alerts.firstMatch.waitForNonExistence(timeout: 5)
        let plus = addButton
        XCTAssertTrue(plus.waitForExistence(timeout: 30), "plus button missing")
        plus.tap()
        XCTAssertTrue(navigationBars["Add"].waitForExistence(timeout: 10), "the Add sheet did not open")
        let label = option == "Bowl" ? "New Bowl…" : option
        let choice = buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        // The sheet opens at half height: rows further down appear once it is scrolled.
        for _ in 0..<4 where !(choice.waitForExistence(timeout: 2) && choice.isHittable) {
            collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(label) missing in the Add sheet")
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

    /// Details of the open entry: "Details" at the end of the meta line under the title (the sheet opens at its top).
    func openDetails() {
        let details = buttons["Details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10), "Details missing in the head of the entry")
        details.tap()
        XCTAssertTrue(navigationBars["Details"].waitForExistence(timeout: 5), "Details did not open")
    }

    /// Closes the Details sheet.
    func closeDetails() {
        navigationBars["Details"].buttons["Done"].tap()
        XCTAssertTrue(navigationBars["Details"].waitForNonExistence(timeout: 5), "Details did not close")
    }

    func goBack() {
        buttons["Back"].firstMatch.tap()
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "list missing after going back")
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
        openTab("Search")
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

    /// A row of the search page. The list the search was opened from can stay in the hierarchy behind the page, so
    /// the row that can be pressed is the one.
    func searchResult(_ title: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for row in staticTexts.matching(identifier: title).allElementsBoundByIndex where row.exists && row.isHittable {
                return row
            }
            usleep(200_000)
        } while Date() < deadline
        return nil
    }
}
