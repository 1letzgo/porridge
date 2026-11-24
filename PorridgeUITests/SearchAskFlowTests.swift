import XCTest

/// Search & Ask and the Chat tab (stage 5, revision 3): the search offers "Ask Porridge: …" first, then where to go,
/// then the entries; asking hands the question over to the Chat tab; Ask About This Bowl opens the Chat tab about the
/// bowl; a chat's changes are confirmed on one card and undone from the toast; Delete Chat asks and can be undone.
/// The model is the Debug stand-in (`-chatStub YES`): no model and no network.
final class SearchAskFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-seedEntryKinds", "YES", "-chatStub", "YES"] + extra
        app.launch()
        return app
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func chatField(_ app: XCUIApplication) -> XCUIElement {
        app.textFields["ChatField"].exists ? app.textFields["ChatField"] : app.textViews["ChatField"]
    }

    func testTheTabsAreTheFourPlacesAndTheSearch() throws {
        let app = launch()
        let tabs = ["Today", "Inbox", "Bowls", "Chat", "Search"]
        for tab in tabs {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 30), "tab \(tab) missing")
        }
        let order = tabs.map { app.tabBars.buttons[$0].frame.midX }
        XCTAssertEqual(order, order.sorted(), "the tabs are not in the order Today · Inbox · Bowls · Chat · Search")
        app.openTab("Chat")
        XCTAssertTrue(app.buttons["Chat About"].waitForExistence(timeout: 5), "the Chat tab shows no chat")
        XCTAssertTrue(chatField(app).exists, "the Chat tab has no field")
        app.openTab("Search")
        XCTAssertTrue(app.textFields["SearchField"].waitForExistence(timeout: 5), "the search tab has no field")
        XCTAssertFalse(app.buttons["SearchChat"].exists, "the search still has the old Chat row")
    }

    func testSearchOffersAskThenGoToThenEntries() throws {
        let app = launch()
        app.search(for: "kitchen")
        let ask = app.buttons["SearchAsk"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10), "no Ask Porridge row")
        XCTAssertTrue(ask.label.contains("Ask Porridge: “kitchen”"), "the ask row does not say what it asks: \(ask.label)")
        let goTo = app.buttons.matching(identifier: "GoTo").firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: 5), "no Go To row for the bowl")
        XCTAssertTrue(goTo.label.contains("Kitchen Renovation"), "the bowl is not offered: \(goTo.label)")
        XCTAssertLessThan(ask.frame.minY, goTo.frame.minY, "Ask Porridge is not the first row")
        screenshot("search-ask-kitchen", app)

        // Typing never asks by itself: the Chat tab has no chat about "kitchen".
        app.openTab("Chat")
        XCTAssertFalse(app.staticTexts["kitchen"].exists, "typing started a chat")

        // The second door to Settings. The Search tab kept its query, like every tab keeps its place.
        app.openTab("Search")
        let field = app.textFields["SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "kitchen", "the Search tab did not keep its query")
        XCTAssertTrue(app.buttons["SearchAsk"].exists, "the kept query shows no results")
        app.buttons["Clear Text"].tap()
        field.tap()
        field.typeText("settings")
        let settings = app.buttons.matching(NSPredicate(format: "identifier == 'GoTo' AND label BEGINSWITH 'Settings'")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no Settings row")
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5), "Settings did not open")
        XCTAssertTrue(app.tabBars.buttons["Bowls"].isSelected, "Settings did not open in the Bowls tab")

        // What was searched for is kept: the empty field lists it.
        app.openTab("Search")
        app.buttons["Clear Text"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "RecentSearch").firstMatch.waitForExistence(timeout: 5), "no recent searches")
    }

    func testAskHandsTheQuestionToTheChatTabAndChangesAreConfirmedOnOneCard() throws {
        let app = launch()
        let question = "worktop colour"
        app.search(for: question)
        let ask = app.buttons["SearchAsk"]
        XCTAssertTrue(ask.waitForExistence(timeout: 10), "no Ask Porridge row")
        ask.tap()
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Chat"].isSelected, "the question did not go to the Chat tab")
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 10), "the question is not in the chat")
        let answer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'From your notes'")).firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "no answer")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Choose worktop colour'")).firstMatch.exists, "the answer names no source")
        screenshot("chat-answer-sources", app)

        // A change: one card with Confirm All, then the one undo toast.
        let field = chatField(app)
        field.tap()
        field.typeText("Mark the worktop to-do as checked")
        app.buttons["ChatSend"].tap()
        let confirmAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Confirm All'")).firstMatch
        XCTAssertTrue(confirmAll.waitForExistence(timeout: 90), "no card to confirm")
        screenshot("chat-confirm-card", app)
        confirmAll.tap()
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "no undo toast after confirming")
        undo.tap()
    }

    func testAskAboutThisBowlOpensTheChatTab() throws {
        let app = launch()
        app.openTab("Bowls")
        let bowl = app.staticTexts["Kitchen Renovation"].firstMatch
        XCTAssertTrue(app.reveal(bowl), "seeded bowl missing")
        bowl.tap()
        let menu = app.buttons["BowlMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "bowl menu missing")
        menu.tap()
        app.buttons["Ask About This Bowl"].tap()
        XCTAssertTrue(app.tabBars.buttons["Chat"].isSelected, "Ask About This Bowl did not open the Chat tab")
        let about = app.buttons["Chat About"]
        XCTAssertTrue(about.waitForExistence(timeout: 5))
        XCTAssertEqual(about.value as? String, "Kitchen Renovation", "the chat is not about the bowl")
        // The scope stays changeable: the Inbox.
        about.tap()
        let inbox = app.buttons.matching(NSPredicate(format: "label == 'Inbox'")).allElementsBoundByIndex.last { $0.isHittable && $0.frame != app.tabBars.buttons["Inbox"].frame }
        XCTAssertNotNil(inbox, "the scope menu has no Inbox")
        inbox?.tap()
        XCTAssertEqual(about.value as? String, "Inbox", "the scope did not change")
    }

    func testDeleteChatAsksAndCanBeUndone() throws {
        let app = launch()
        app.openTab("Chat")
        let field = chatField(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let question = "Delete me \(UUID().uuidString.prefix(6))"
        field.tap()
        field.typeText(question)
        app.buttons["ChatSend"].tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 10), "question missing")
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'From your notes' OR label BEGINSWITH 'I found nothing'")).firstMatch.waitForExistence(timeout: 90)
        app.buttons["All Chats"].tap()
        let row = app.staticTexts[question].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "chat not in All Chats")
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirm = app.alerts.buttons["Delete Chat"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete Chat does not ask first")
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5), "chat not deleted")
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "no undo after deleting a chat")
        undo.tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 5), "undo did not bring the chat back")
    }

    func testTheChatLinkOpensTheChatTab() throws {
        let app = launch()
        app.openTab("Today")
        app.open(URL(string: "porridge://chat")!)
        XCTAssertTrue(app.tabBars.buttons["Chat"].waitForExistence(timeout: 10))
        let selected = NSPredicate(format: "isSelected == true")
        expectation(for: selected, evaluatedWith: app.tabBars.buttons["Chat"])
        waitForExpectations(timeout: 10)
    }
}
