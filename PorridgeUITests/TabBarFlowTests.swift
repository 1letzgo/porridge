import XCTest

/// Owner revision 5: "+" in the middle of the tab bar, Search | Chat in one tab, Open To-dos and the Weekly Review at
/// the end of the Inbox, the gear in Today, the app always starting on Today, and a chat keyboard that goes away.
/// Owner revision 6: "+" raised and bigger, in a middle slot of its own (`PlaceTabBar`).
final class TabBarFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO"] + extra
        app.launch()
        return app
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The big "+" is the middle of the tab bar (Today · Inbox · + · Bowls · Search), taller than the bar and rising
    /// above its top edge (owner revision 6); the tabs beside it end before it.
    func testPlusSitsOnTheMiddleOfTheTabBar() {
        let app = launch()
        let plus = app.addButton
        XCTAssertTrue(plus.waitForExistence(timeout: 30) && plus.isHittable, "+ is not on screen")
        let tabs = ["Today", "Inbox", "Add", "Bowls", "Search"].map { app.tab($0) }
        XCTAssertTrue(tabs.allSatisfy(\.exists), "a tab is missing")
        let order = tabs.map(\.frame.midX)
        XCTAssertEqual(order, order.sorted(), "the tabs are not Today · Inbox · + · Bowls · Search")
        XCTAssertEqual(plus.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2, "+ is not in the middle of the screen")
        let inbox = app.tab("Inbox").frame
        let bowls = app.tab("Bowls").frame
        XCTAssertGreaterThanOrEqual(plus.frame.width, 56, "+ is not clearly the bar's biggest element")
        XCTAssertGreaterThan(plus.frame.height, inbox.height, "+ is not taller than the bar's tabs")
        XCTAssertLessThan(plus.frame.minY, inbox.minY - 6, "+ does not rise above the bar")
        XCTAssertLessThan(plus.frame.maxY, app.windows.firstMatch.frame.maxY - 20, "+ reaches down to the screen's edge")
        // The tabs (each as wide as its selection capsule) end before the circle.
        XCTAssertLessThanOrEqual(inbox.maxX, plus.frame.minX - 4, "the Inbox's slot reaches under +")
        XCTAssertGreaterThanOrEqual(bowls.minX, plus.frame.maxX + 4, "the Bowls slot reaches under +")
        // "+" is no tab: the place in front stays.
        app.openTab("Bowls")
        XCTAssertTrue(app.tapAddWhenHittable(), "+ did not open the Add sheet")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Add"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tab("Bowls").isSelected, "+ changed the tab")
    }

    /// With a badge of three digits on the Inbox (and each tab chosen once, its selection capsule drawn) "+" still
    /// sits clear of them: pictures of the bar to look at (`SHOTS_DIR`).
    func testPlusLeavesRoomForAThreeDigitBadge() {
        let app = launch(["-emptyStore", "YES", "-seedInboxCount", "120"])
        app.openTab("Inbox")
        XCTAssertTrue(app.tab("Inbox").waitForExistence(timeout: 30))
        let badge = app.tab("Inbox").value as? String ?? ""
        XCTAssertTrue(badge.contains("120"), "the Inbox has no three-digit badge: \(badge)")
        XCTAssertTrue(app.addButton.isHittable)
        XCTAssertLessThanOrEqual(app.tab("Inbox").frame.maxX, app.addButton.frame.minX - 4, "the Inbox's capsule reaches under +")
        let folder = shotsFolder(default: "/tmp/porridge-s11-shots")
        let suffix = ProcessInfo.processInfo.environment["SHOTS_SUFFIX"] ?? ""
        for tab in ["Today", "Inbox", "Bowls", "Search"] {
            app.openTab(tab)
            XCTAssertTrue(app.tab(tab).isSelected, "\(tab) is not chosen")
            sleep(1)
            if FileManager.default.fileExists(atPath: folder.path) {
                let width = Int(app.windows.firstMatch.frame.width)
                try? XCUIScreen.main.screenshot().pngRepresentation
                    .write(to: folder.appendingPathComponent("ios-tabbar-120-\(tab.lowercased())-\(width)\(suffix).png"))
            }
        }
    }

    /// The Inbox's entries are right under its switch New · To-dos (owner revision 9: no card), and the last rows of
    /// the list still scroll clear of the raised "+".
    func testTheInboxEntriesAreOnTopAndTheLastRowClearsThePlus() {
        let app = launch(["-emptyStore", "YES", "-seedInboxCount", "30"])
        app.openTab("Inbox")
        app.inboxSegment(0).tap()
        XCTAssertFalse(app.buttons["InboxWeeklyReview"].exists, "the card is still in the Inbox")
        let first = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Inbox note '")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5), "no entries")
        XCTAssertGreaterThan(first.frame.minY, app.inboxSegment(0).frame.maxY, "the entries are not under New · To-dos")
        let last = app.staticTexts["Inbox note 1"]
        for _ in 0..<20 where !(last.exists && last.isHittable && last.frame.maxY <= app.addButton.frame.minY) { app.swipeUp() }
        XCTAssertLessThanOrEqual(last.frame.maxY, app.addButton.frame.minY, "the last entry stays under +")
    }

    /// "+" of the tab bar opens the Add sheet into the Inbox from the Inbox, into the bowl from a bowl.
    func testPlusAddsIntoTheInboxOrTheOpenBowl() {
        let app = launch(["-seedEntryKinds", "YES"])
        app.openTab("Inbox")
        XCTAssertTrue(app.tapAddWhenHittable(), "the Add sheet did not open from the Inbox")
        let into = app.buttons["AddInto"]
        XCTAssertTrue(into.waitForExistence(timeout: 5), "the Add sheet has no Into")
        XCTAssertEqual(into.label, "Into: Inbox", "from the Inbox it does not add into the Inbox")
        screenshot("add-sheet-inbox", app)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.navigationBars["Add"].waitForNonExistence(timeout: 5))

        app.openTab("Bowls")
        let bowl = app.staticTexts["Kitchen Renovation"].firstMatch
        XCTAssertTrue(app.reveal(bowl), "seeded bowl missing")
        bowl.tap()
        XCTAssertTrue(app.buttons["BowlMenu"].waitForExistence(timeout: 10), "the bowl did not open")
        XCTAssertTrue(app.tapAddWhenHittable(), "the Add sheet did not open from the bowl")
        XCTAssertTrue(into.waitForExistence(timeout: 5))
        XCTAssertEqual(into.label, "Into: Kitchen Renovation", "from a bowl it does not add into the bowl")
        screenshot("add-sheet-bowl", app)
        app.buttons["Close"].tap()

        // A long press makes a note at once, in the bowl.
        XCTAssertTrue(app.navigationBars["Add"].waitForNonExistence(timeout: 5))
        app.addButton.press(forDuration: 1.0)
        XCTAssertTrue(app.waitForTitleField(), "a long press on + made no note")
        XCTAssertFalse(app.navigationBars["Add"].exists, "the long press also opened the Add sheet")
    }

    /// Today has the gear: Settings opens on Today's own stack, and back is Today.
    func testTodayHasTheSettingsGear() {
        let app = launch()
        app.openTab("Today")
        let gear = app.buttons["PlaceSettings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 30), "Today has no gear")
        XCTAssertTrue(app.buttons["TodayNextDay"].exists, "the gear pushed the day pager out of the bar")
        gear.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5), "Settings did not open")
        XCTAssertTrue(app.tab("Today").isSelected, "Settings did not open on Today")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["TodayNextDay"].waitForExistence(timeout: 5), "back is not Today")
    }

    /// Every launch starts on Today, whatever tab was used last.
    func testTheAppStartsOnToday() {
        let app = launch()
        app.openTab("Bowls")
        XCTAssertTrue(app.buttons["BowlSort"].waitForExistence(timeout: 10))
        // Out to the home screen and back: the tab stays.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.buttons["BowlSort"].waitForExistence(timeout: 10), "coming back from the background left Bowls")
        XCTAssertTrue(app.tab("Bowls").isSelected)
        // A new launch: Today.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["TodayNextDay"].waitForExistence(timeout: 30), "the app did not start on Today")
        XCTAssertTrue(app.tab("Today").isSelected, "the app did not start on Today")
        // A link still moves on from Today.
        app.open(URL(string: "porridge://bowls")!)
        XCTAssertTrue(app.buttons["BowlSort"].waitForExistence(timeout: 10), "a link did not win over Today")
    }

    /// The Inbox's To-dos side lists the open to-dos (owner revision 9; before, the page Open To-dos), and the Weekly
    /// Review is a button in Today's bar.
    func testInboxToDosSideAndWeeklyReviewInToday() {
        let app = launch(["-seedTodos", unique("Card")])
        app.openTab("Inbox")
        app.inboxSegment(1).tap()
        XCTAssertTrue(app.staticTexts["Overdue"].firstMatch.waitForExistence(timeout: 10), "the To-dos side shows no open to-dos")
        XCTAssertTrue(app.tab("Inbox").isSelected, "the To-dos side left the Inbox tab")
        screenshot("inbox-todos-side", app)
        app.inboxSegment(0).tap()

        app.openTab("Today")
        let review = app.buttons["TodayWeeklyReview"]
        XCTAssertTrue(review.waitForExistence(timeout: 10), "no Weekly Review in Today's bar")
        review.tap()
        XCTAssertTrue(app.staticTexts["This Week"].waitForExistence(timeout: 5), "the Weekly Review did not open")
        app.buttons["Done"].firstMatch.tap()
    }

    /// An empty Inbox says so, under its switch.
    func testEmptyInboxSaysSo() {
        let app = launch(["-emptyStore", "YES"])
        app.openTab("Inbox")
        app.inboxSegment(0).tap()
        XCTAssertTrue(app.staticTexts["Inbox Empty"].waitForExistence(timeout: 10), "the empty Inbox says nothing")
        XCTAssertTrue(app.inboxSegment(0).label.hasPrefix("New"), "no New side")
        XCTAssertFalse(app.inboxSegment(0).label.contains("0"), "a 0 on the switch")
        screenshot("inbox-empty", app)
    }

    /// The chat's keyboard goes away: with a tap in the conversation, with a drag down through it, and after sending.
    func testChatKeyboardCanBeDismissed() {
        let app = launch(["-seedEntryKinds", "YES", "-chatStub", "YES"])
        app.openTab("Chat")
        let field = app.textFields["ChatField"].exists ? app.textFields["ChatField"] : app.textViews["ChatField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no chat field")
        if app.buttons["New Chat"].firstMatch.exists { app.buttons["New Chat"].firstMatch.tap() }
        let keyboard = app.keyboards.firstMatch
        let conversation = app.descendants(matching: .any)["ChatConversation"].firstMatch

        // A tap in the conversation.
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "no keyboard")
        screenshot("chat-keyboard-open", app)
        XCTAssertTrue(conversation.exists, "no conversation area")
        // In the conversation's margin, above the field: nothing there to press.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: field.frame.minY - 30)).tap()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "a tap in the conversation left the keyboard up")
        screenshot("chat-keyboard-dismissed", app)

        // Sending: the answer is not covered by the keyboard.
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let question = "worktop colour \(UUID().uuidString.prefix(4))"
        field.typeText(question)
        app.tapSendWhenAboveTheKeyboard()
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "sending left the keyboard over the answer")
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 10), "the question is not in the chat")
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'From your notes' OR label BEGINSWITH 'I found nothing'")).firstMatch.waitForExistence(timeout: 90)

        // A drag down through the conversation.
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let top = app.staticTexts[question].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 400)))
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "a drag down through the conversation left the keyboard up")

        // The Search side: a tap in the results.
        app.searchSide("Search")
        let search = app.textFields["SearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("kitchen")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let ask = app.buttons["SearchAsk"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10))
        let below = ask.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        below.press(forDuration: 0.05, thenDragTo: below.withOffset(CGVector(dx: 0, dy: 300)))
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "a drag through the search results left the keyboard up")
        app.buttons["Clear Text"].tap()
    }
}
