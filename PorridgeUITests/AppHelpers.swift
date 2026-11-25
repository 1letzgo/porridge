import XCTest

extension XCTestCase {
    /// The app without onboarding and without sync, so a run stays on this simulator.
    func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO"]
        app.launch()
        return app
    }

    /// Where the screenshot tests write their pictures: `SHOTS_DIR` (set as `TEST_RUNNER_SHOTS_DIR=<folder>` for
    /// `xcodebuild`), else the stage's default folder. Pictures are written only when the folder exists.
    func shotsFolder(default path: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHOTS_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? path)
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

    /// New (0) or Later (1) of the Inbox: a segmented control, or capsules with the largest text sizes.
    func inboxSegment(_ index: Int) -> XCUIElement {
        let control = segmentedControls["InboxSegment"]
        if control.exists { return control.buttons.element(boundBy: index) }
        return buttons.matching(NSPredicate(format: "label BEGINSWITH %@", index == 0 ? "New " : "Later ")).firstMatch
    }

    /// "+" in the middle of the tab bar (on an iPad the last pill of the bar).
    var addButton: XCUIElement {
        buttons.matching(identifier: "PlaceAdd").allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            ?? buttons.matching(identifier: "PlaceAdd").firstMatch
    }

    /// "+" once it can be pressed (a menu or sheet that is still going away covers it for a moment), pressed; a
    /// press that came too early and opened nothing is repeated once. Returns whether the Add sheet is up.
    @discardableResult
    func tapAddWhenHittable(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !(addButton.exists && addButton.isHittable) { usleep(200_000) }
        XCTAssertTrue(addButton.isHittable, "PlaceAdd is not hittable")
        addButton.tap()
        if navigationBars["Add"].waitForExistence(timeout: 3) { return true }
        if addButton.exists, addButton.isHittable { addButton.tap() }
        return navigationBars["Add"].waitForExistence(timeout: 5)
    }

    /// One of the places' tabs: Today, Inbox, Bowls, Search. "Chat" is the Search tab on its Chat side.
    func openTab(_ name: String) {
        if name == "Chat" {
            openTab("Search")
            searchSide("Chat")
            return
        }
        let button = tab(name)
        XCTAssertTrue(button.waitForExistence(timeout: 30), "tab \(name) missing")
        button.tap()
    }

    /// The app's tab bar (`PlaceTabBar`: drawn by the app since owner revision 6, not a system tab bar).
    var placeTabBar: XCUIElement {
        descendants(matching: .any).matching(identifier: "PlaceTabBar").firstMatch
    }

    /// A tab of the app's tab bar by its name: Today, Inbox, Bowls, Search ("Add" is "+" in its middle).
    func tab(_ name: String) -> XCUIElement {
        name == "Add" ? buttons["PlaceAdd"] : buttons["Tab" + name]
    }

    /// The chat's Send, once the keyboard has come in and the field has risen above it, and pressed again if the press
    /// sent nothing (Send stays enabled while the question is still in the field). With the largest text sizes the
    /// keyboard exists below the screen's edge for a moment while it comes in: a press then lands where Send was
    /// before the bar moved up, and the question is never sent.
    func tapSendWhenAboveTheKeyboard() {
        let send = buttons["ChatSend"]
        let keyboard = keyboards.firstMatch
        let bottom = windows.firstMatch.frame.maxY
        for _ in 0..<3 {
            let deadline = Date().addingTimeInterval(5)
            var last = CGRect.null
            while Date() < deadline, send.exists {
                let frame = send.frame
                let settled = !keyboard.exists || (keyboard.frame.minY < bottom - 1 && frame.maxY <= keyboard.frame.minY + 1)
                if settled, frame == last { break }
                last = frame
                usleep(250_000)
            }
            send.tap()
            // Sent: the field is empty and Send disabled while the answer comes.
            let sent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == false"), object: send)
            if XCTWaiter().wait(for: [sent], timeout: 3) == .completed { return }
        }
    }

    /// All Chats on the Chat side: from an open conversation the bar's back pill goes to the chat's start, whose
    /// Recent Chats card leads to All Chats (owner revision 6: no list pill in the bar any more).
    func openAllChats() {
        let all = buttons["RecentAllChats"]
        for _ in 0..<2 where !all.waitForExistence(timeout: 2) {
            let back = buttons["Back"].firstMatch
            if back.exists { back.tap() }
        }
        XCTAssertTrue(all.waitForExistence(timeout: 5), "All Chats missing in Recent Chats")
        all.tap()
    }

    /// The side of the Bowls tab's switch (Bowls, Archive or Deleted; their labels carry a count): a segmented
    /// control, or capsules with the largest text sizes. Returns the segment.
    @discardableResult
    func bowlsSide(_ name: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", name + " ")
        let control = segmentedControls["BowlsSide"]
        let barTop = placeTabBar.exists ? placeTabBar.frame.minY : .greatestFiniteMagnitude
        let side = control.waitForExistence(timeout: 5) ? control.buttons.matching(predicate).firstMatch
            : buttons.matching(predicate).allElementsBoundByIndex.first { $0.exists && $0.isHittable && $0.frame.maxY < barTop }
                ?? buttons.matching(predicate).firstMatch
        XCTAssertTrue(side.waitForExistence(timeout: 10), "Bowls · Archive · Deleted has no \(name)")
        if !side.isSelected { side.tap() }
        return side
    }

    /// The side of the Search tab's switch (Search or Chat): a segmented control, or capsules with the largest text
    /// sizes.
    func searchSide(_ name: String) {
        let control = segmentedControls["SearchSide"]
        // With the largest text sizes: capsules, above the tab bar (whose "Search" has the same label).
        let barTop = placeTabBar.exists ? placeTabBar.frame.minY : .greatestFiniteMagnitude
        let side = control.waitForExistence(timeout: 5) ? control.buttons[name]
            : buttons.matching(NSPredicate(format: "label == %@", name)).allElementsBoundByIndex
                .first { $0.exists && $0.isHittable && $0.frame.maxY < barTop }
                ?? buttons[name].firstMatch
        XCTAssertTrue(side.waitForExistence(timeout: 10), "Search | Chat has no \(name)")
        if !side.isSelected { side.tap() }
    }

    /// The side of the Search tab that shows.
    var searchSideShown: String? {
        let control = segmentedControls["SearchSide"]
        guard control.exists else { return nil }
        return ["Search", "Chat"].first { control.buttons[$0].isSelected }
    }

    /// One of the choices of the Add sheet ("+" in the bar): Note, To-do, Meeting, Link, Photo or File, New Bowl…
    /// ("Bowl" stands for New Bowl…).
    func create(_ option: String) {
        // An alert that is still going away has a "Create" of its own.
        _ = alerts.firstMatch.waitForNonExistence(timeout: 5)
        // "+" is the middle of the tab bar on every tab (it hides only while choosing several).
        var plus = addButton
        if !(plus.waitForExistence(timeout: 5) && plus.isHittable) {
            openTab("Today")
            plus = addButton
        }
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
        // "+" of the tab bar shows on an entry's page too: the list is back once the entry's title is gone.
        _ = titleField.waitForNonExistence(timeout: 10)
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "list missing after going back")
    }

    /// Earlier runs leave notes behind, so a new row can be below the fold.
    func reveal(_ element: XCUIElement) -> Bool {
        for _ in 0..<25 where !element.exists { swipeUp() }
        guard element.waitForExistence(timeout: 5) else { return false }
        for _ in 0..<4 where !element.isHittable { swipeUp() }
        return true
    }

    /// `reveal`, then a tap once the row stays put: with the largest text sizes a list can still be moving after the
    /// swipes and the row found a moment ago is gone again. Tried three times; returns whether it was tapped.
    @discardableResult
    func revealAndTap(_ element: XCUIElement) -> Bool {
        for _ in 0..<3 {
            guard reveal(element) else { return false }
            usleep(500_000)
            if element.exists, element.isHittable {
                element.tap()
                return true
            }
        }
        return false
    }

    /// Same upwards: for a row that moved to the top of the list.
    func revealAbove(_ element: XCUIElement) -> Bool {
        for _ in 0..<12 where !element.isHittable { swipeDown() }
        return element.isHittable
    }

    func search(for text: String) {
        openTab("Search")
        searchSide("Search")
        let field = textFields["SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search field missing")
        field.tap()
        field.typeText(text)
    }

    /// Replaces the text in the open search.
    func searchAgain(for text: String) {
        let field = textFields["SearchField"]
        // A tap in the results puts the keyboard away (opening one, scrolling): then the field is emptied and takes
        // the keyboard back.
        if !((field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false) {
            let clear = buttons["Clear Text"]
            if clear.exists { clear.tap() }
            field.tap()
            _ = keyboards.firstMatch.waitForExistence(timeout: 5)
            field.typeText(text)
            return
        }
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
