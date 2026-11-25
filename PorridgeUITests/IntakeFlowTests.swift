import XCTest

/// The inbox on screen: a new note waits in it until it is filed into a bowl.
final class IntakeFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testANewNoteStaysInTheInboxUntilItIsInABucket() throws {
        let app = launchApp()
        // A bowl to file it into.
        let bucket = unique("Bowl")
        app.create("Bowl")
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "name field missing")
        name.typeText(bucket)
        app.confirmAlert("Create")
        let back = app.buttons["Back"]
        if back.waitForExistence(timeout: 3) { back.tap() }

        let title = unique("Inbox")
        app.newNote(title: title)
        app.goBack()

        // The Inbox is the second tab; the newest is on top.
        app.openTab("Inbox")
        let row = app.staticTexts[title]
        XCTAssertTrue(app.reveal(row), "new note not in the inbox")

        // There is no way out but a bowl. The long press of the row has the bowls, as in every list.
        XCTAssertFalse(app.buttons["Keep without Bowl"].exists, "the inbox still offers to keep without a bowl")
        XCTAssertFalse(app.buttons["File into Bowl"].exists, "the inbox still shows a bowl pill under the row")
        row.press(forDuration: 1)
        let file = app.buttons["Bowl"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5), "bowl menu missing in the long press")
        file.tap()
        // With many bowls the menu scrolls; the new one may be further down.
        let choice = app.buttons[bucket].firstMatch
        for _ in 0..<12 where !choice.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "bowl missing in the menu")
        choice.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "filed note still in the inbox")
    }

    /// The chat about a bowl opens from the bowl's ⋯ (Ask About This Bowl) in the Chat tab; it is kept and taken up
    /// again.
    func testAChatAboutABucketIsKeptAndTakenUpAgain() throws {
        let app = launchApp()
        let bucket = unique("Chat")
        app.create("Bowl")
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "name field missing")
        name.typeText(bucket)
        app.confirmAlert("Create")

        // The new bowl opens; its ⋯ asks about it. It is empty, so the answer needs no model.
        func askAboutTheBowl() {
            let menu = app.buttons["BowlMenu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), "bowl menu missing")
            menu.tap()
            let ask = app.buttons["Ask About This Bowl"]
            XCTAssertTrue(ask.waitForExistence(timeout: 5), "Ask About This Bowl missing in the bowl menu")
            ask.tap()
        }
        askAboutTheBowl()
        XCTAssertTrue(app.buttons["Chat About"].waitForExistence(timeout: 5), "the chat does not say what it is about")
        let field = app.textFields["ChatField"].exists ? app.textFields["ChatField"] : app.textViews["ChatField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "chat field missing")
        // The page may still be sliding in: typing starts once the field can take it.
        for _ in 0..<12 where !field.isHittable { usleep(250_000) }
        field.tap()
        let question = unique("What is in here")
        field.typeText(question)
        app.buttons["ChatSend"].tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 20), "question missing in the chat")
        // The index is brought up to date first: on the first launch after an update that cuts the entries again
        // (documents lost their payment state), that takes a while on a simulator full of earlier test entries.
        XCTAssertTrue(app.staticTexts["There is nothing in this bowl yet."].waitForExistence(timeout: 90), "answer missing")

        // Asking about a bowl opens the Search tab on its Chat side.
        XCTAssertTrue(app.tab("Search").isSelected, "the chat did not open in the Search tab")
        XCTAssertEqual(app.searchSideShown, "Chat", "the chat did not open on the Chat side")
        // Kept: it is in the list of chats, and asking about the bowl again shows it.
        // The bar: no list pill; New Chat while the conversation is open, the back pill to the chat's start.
        XCTAssertFalse(app.buttons["All Chats"].exists, "the bar still has an All Chats pill")
        XCTAssertTrue(app.buttons["ChatNewChat"].exists, "no New Chat while a conversation is open")
        app.openAllChats()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 5), "chat missing in the list of chats")
        XCTAssertEqual(app.searchSideShown, "Chat", "All Chats left the Chat side")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Ask Your Bowls"].waitForExistence(timeout: 5), "back from All Chats did not go to the chat's start")
        XCTAssertEqual(app.searchSideShown, "Chat", "back from All Chats left the Chat side")
        XCTAssertTrue(app.buttons.matching(identifier: "RecentChat").firstMatch.exists, "a new chat offers no recent chats")
        app.openTab("Bowls")
        askAboutTheBowl()
        XCTAssertTrue(app.staticTexts["There is nothing in this bowl yet."].waitForExistence(timeout: 10), "the chat was not taken up again")
        XCTAssertTrue(app.buttons["ChatNewChat"].exists, "no way to start another chat")
        app.buttons["ChatNewChat"].tap()
        XCTAssertTrue(app.staticTexts["Ask Your Bowls"].waitForExistence(timeout: 5), "New Chat did not start an empty chat")
    }

    // MARK: Inbox work (stage 6)

    /// The Inbox of the mockups on a store in memory (`-seedInbox`).
    private func launchSeededInbox() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO",
                                "-emptyStore", "YES", "-seedInbox", "YES", "-quietNotifications", "YES"]
        app.launch()
        app.openTab("Inbox")
        return app
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A row names its suggested bowl ("✦ Reading"); a swipe to the right files it there (with Undo), a swipe to the
    /// left offers Delete and no Later (owner revision 9).
    func testSwipesFileIntoTheSuggestion() throws {
        let app = launchSeededInbox()
        let link = app.staticTexts["The Case for Slow Software"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "seeded Inbox missing")
        XCTAssertTrue(app.buttons["File into Reading"].firstMatch.exists, "the row does not name its suggested bowl")
        XCTAssertFalse(app.buttons["Drop Suggestion"].exists, "the old suggestion pills are still there")
        screenshot("inbox-suggestion-word", app)

        link.swipeRight()
        let file = app.buttons["File into Reading"].firstMatch
        XCTAssertTrue(app.buttons["Bowl…"].waitForExistence(timeout: 5), "no Bowl… in the swipe")
        screenshot("inbox-swipe-file", app)
        file.tap()
        XCTAssertTrue(link.waitForNonExistence(timeout: 5), "the swipe did not file the entry")
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "filing offers no Undo")
        undo.tap()
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Undo did not bring the entry back")

        let gift = app.staticTexts["Gift ideas for Mum"]
        XCTAssertTrue(app.reveal(gift))
        gift.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].firstMatch.waitForExistence(timeout: 5), "no Delete in the swipe")
        XCTAssertFalse(app.buttons["Later"].exists, "Later is still in the swipe")
        screenshot("inbox-swipe-delete", app)
    }

    /// Triage goes through the Inbox one entry at a time: File into the suggestion, then Skip; the counter follows.
    func testTriageTwoEntries() throws {
        let app = launchSeededInbox()
        let triage = app.buttons["InboxTriage"]
        XCTAssertTrue(triage.waitForExistence(timeout: 10), "no Triage in the Inbox bar")
        triage.tap()
        let counter = app.staticTexts["TriageCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5), "Triage did not open")
        XCTAssertTrue(counter.label.hasPrefix("Entry 1 of 10"), counter.label)
        XCTAssertFalse(app.placeTabBar.exists && app.placeTabBar.isHittable, "the tab bar shows in Triage")
        XCTAssertFalse(app.addButton.exists && app.addButton.isHittable, "+ of the tab bar shows in Triage")
        XCTAssertTrue(app.staticTexts["Suggested bowl: Reading"].exists, "the suggestion is not named")
        screenshot("triage-first", app)
        app.buttons["TriageFile"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Entry 2 of 10'"), evaluatedWith: counter)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5), "filing in Triage offers no Undo")
        app.buttons["TriageSkip"].tap()
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Entry 3 of 10'"), evaluatedWith: counter)
        waitForExpectations(timeout: 5)
        screenshot("triage-third", app)
        app.buttons["TriageEnd"].tap()
        XCTAssertTrue(app.staticTexts["Invoice INV-2026-1142"].waitForExistence(timeout: 5), "the skipped entry is not in the Inbox")
        XCTAssertFalse(app.staticTexts["The Case for Slow Software"].exists, "the filed entry is still in the Inbox")
    }

    /// Choosing three entries: "3 Selected" is the first row, the selection bar takes the tab bar's place, and More
    /// sets the kind of all of them (no paid mark: documents keep no payment status).
    func testSelectThreeAndSetTheirKind() throws {
        let app = launchSeededInbox()
        let select = app.buttons["Select"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        for title in ["Invoice INV-2026-1142", "Invoice INV-2026-1098", "Receipt, hardware store"] {
            let row = app.staticTexts[title]
            XCTAssertTrue(app.reveal(row), "\(title) missing")
            row.tap()
        }
        XCTAssertEqual(app.staticTexts["SelectionCount"].label, "3 Selected")
        XCTAssertTrue(app.buttons["SelectionMove"].exists, "no selection bar")
        XCTAssertFalse(app.placeTabBar.exists && app.placeTabBar.isHittable, "the tab bar still shows while selecting")
        XCTAssertFalse(app.addButton.exists && app.addButton.isHittable, "+ of the tab bar still shows while selecting")
        screenshot("inbox-selection-bar", app)
        app.buttons["SelectionMore"].tap()
        let kind = app.buttons["Document Kind"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5), "no Document Kind in More")
        XCTAssertTrue(app.buttons["Delete 3 Entries"].exists, "no Delete 3 Entries in More")
        XCTAssertFalse(app.buttons["Mark as Paid"].exists, "Mark as Paid is still in More")
        XCTAssertFalse(app.buttons["Mark as Unpaid"].exists, "Mark as Unpaid is still in More")
        screenshot("inbox-selection-more", app)
        kind.tap()
        let receipt = app.buttons["Receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 5), "no kinds in Document Kind")
        receipt.tap()
        XCTAssertTrue(app.staticTexts["Kind set to Receipt"].waitForExistence(timeout: 5), "setting the kind offers no Undo toast")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.placeTabBar.waitForExistence(timeout: 5) && app.placeTabBar.isHittable, "the tab bar did not come back")
        XCTAssertTrue(app.addButton.waitForExistence(timeout: 5) && app.addButton.isHittable, "+ did not come back with the tab bar")
    }
}
