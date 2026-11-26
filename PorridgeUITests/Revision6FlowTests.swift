import XCTest

/// Owner revision 6, as changed by owner revisions 10 and 13: the Bowls tab without a switch (its To-dos side moved
/// to the Inbox tab), the trash pill and the Archive row, and the Search tab's Chat side without a page title of its own or a list pill in the bar.
final class Revision6FlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO",
                                "-chatStub", "YES"] + extra
        app.launch()
        return app
    }

    private var deletedPredicate: NSPredicate {
        NSPredicate(format: "label BEGINSWITH 'Notes are deleted after' OR label == 'Nothing Deleted'")
    }

    /// Owner revision 13: Bowls has no switch (the open to-dos are the Inbox tab's To-dos side); the trash pill in the
    /// bar opens Recently Deleted as a page with Delete All (when something is there); the Archive row at the end
    /// opens the archived bowls as a page; Sort and the trash pill are Bowls', "+ To-do" the To-dos side's.
    func testBowlsWithoutSwitchTrashPillAndArchiveRow() throws {
        let app = launch()
        app.openTab("Bowls")
        XCTAssertTrue(app.buttons["BowlSort"].waitForExistence(timeout: 10), "no Sort in Bowls")
        XCTAssertFalse(app.segmentedControls["BowlsSide"].exists, "Bowls still has a switch")
        XCTAssertFalse(app.segmentedControls["InboxSide"].exists, "the Inbox's switch shows in Bowls")
        XCTAssertFalse(app.buttons["TodosAdd"].exists, "New To-do shows in Bowls")
        XCTAssertTrue(app.buttons["BowlsTrash"].exists, "no trash pill in Bowls")
        XCTAssertTrue(app.reveal(app.buttons["NewSmartFilter"]), "Smart Filters missing in Bowls")
        XCTAssertTrue(app.reveal(app.buttons["BowlsArchive"]), "no Archive row after the smart filters")
        XCTAssertGreaterThan(app.buttons["BowlsArchive"].frame.minY, app.buttons["NewSmartFilter"].frame.maxY, "Archive is not the last section")

        app.openTodos()
        XCTAssertTrue(app.tab("Inbox").isSelected, "the To-dos side left the Inbox tab")
        XCTAssertFalse(app.buttons["BowlSort"].exists, "Sort shows on the To-dos side")
        XCTAssertFalse(app.buttons["BowlsTrash"].exists, "the trash pill shows on the To-dos side")
        XCTAssertTrue(app.buttons["TodosAdd"].exists, "no New To-do on the To-dos side")
        app.inboxSide("Inbox")
        app.openTab("Bowls")

        // The Archive, a page with a back pill.
        app.openArchive()
        XCTAssertFalse(app.buttons["BowlSort"].exists, "Sort shows on the Archive page")
        app.goBack()

        // Something in Recently Deleted: a note made and deleted.
        let name = unique("Gone")
        app.newNote(title: name)
        app.goBack()
        app.openTab("Inbox")
        let row = app.staticTexts[name]
        XCTAssertTrue(app.reveal(row), "the new note is not in the Inbox")
        row.press(forDuration: 1.2)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()

        app.openRecentlyDeleted()
        XCTAssertTrue(app.buttons["Back"].firstMatch.exists, "Recently Deleted has no back pill")
        XCTAssertTrue(app.staticTexts.matching(deletedPredicate).firstMatch.waitForExistence(timeout: 5), "no 30-days hint")
        XCTAssertTrue(app.reveal(app.staticTexts[name]), "the deleted note is not in Recently Deleted")
        XCTAssertTrue(app.buttons["TrashDeleteAll"].exists, "no Delete All in Recently Deleted")
        XCTAssertFalse(app.buttons["BowlSort"].exists, "Sort shows in Recently Deleted")
        app.goBack()
        XCTAssertTrue(app.buttons["BowlSort"].waitForExistence(timeout: 5), "Back did not return to Bowls")

        // The Inbox tab comes back on the side it was left on while the app runs; a cold launch starts on Inbox.
        app.openTodos()
        app.openTab("Today")
        app.openTab("Inbox")
        XCTAssertTrue(app.inboxSide("To-dos").isSelected, "the Inbox tab did not come back on To-dos")
        app.terminate()
        let again = launch()
        again.openTab("Inbox")
        XCTAssertTrue(again.buttons["InboxTriage"].waitForExistence(timeout: 10), "a cold launch did not start on Inbox")
        XCTAssertTrue(again.inboxSide("Inbox").isSelected, "a cold launch did not start on Inbox")
    }

    /// Go To rows of the search open Recently Deleted and the Archive as pages of the Bowls tab, with a back pill.
    func testGoToArchiveAndRecentlyDeletedOpenTheirPages() throws {
        let app = launch()
        app.search(for: "Recently Deleted")
        let goTo = app.buttons.matching(identifier: "GoTo").matching(NSPredicate(format: "label CONTAINS 'Recently Deleted'")).firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: 10), "no Go To row for Recently Deleted")
        goTo.tap()
        XCTAssertTrue(app.tab("Bowls").waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.tab("Bowls"))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.staticTexts.matching(deletedPredicate).firstMatch.waitForExistence(timeout: 5), "Go To Recently Deleted did not open it")
        XCTAssertTrue(app.buttons["Back"].firstMatch.exists, "Recently Deleted was not pushed as a page")
        app.goBack()

        app.openTab("Search")
        app.searchAgain(for: "Archive")
        let archive = app.buttons.matching(identifier: "GoTo").matching(NSPredicate(format: "label BEGINSWITH 'Archive'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "no Go To row for Archive")
        archive.tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.tab("Bowls"))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["Back"].firstMatch.waitForExistence(timeout: 5), "Archive was not pushed as a page")
        XCTAssertFalse(app.segmentedControls["InboxSide"].exists, "Go To Archive shows the Inbox's switch")
    }

    /// The Chat side: no list pill in the bar; a conversation has New Chat and a back pill to the chat's start; All
    /// Chats is in the Recent Chats card, and its back pill returns to the chat's start; a chat picked there goes back
    /// to the list. The tab stays on its Chat side all the way.
    func testChatSideNavigation() throws {
        let app = launch()
        app.openTab("Chat")
        if app.buttons["ChatNewChat"].exists { app.buttons["ChatNewChat"].tap() }
        XCTAssertFalse(app.buttons["All Chats"].exists && app.buttons["All Chats"].identifier != "RecentAllChats",
                       "the bar has a list pill on the Chat side")
        XCTAssertFalse(app.buttons["ChatNewChat"].exists, "New Chat shows at the chat's start")
        XCTAssertFalse(app.buttons["Back"].exists, "a back pill at the chat's start")

        let field = app.textFields["ChatField"].exists ? app.textFields["ChatField"] : app.textViews["ChatField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no chat field")
        let question = unique("Where is the worktop")
        field.tap()
        // The field moves up with the keyboard: typing starts once it has the keyboard.
        if !app.keyboards.firstMatch.waitForExistence(timeout: 5) { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard for the chat field")
        field.typeText(question)
        app.tapSendWhenAboveTheKeyboard()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 90), "question missing")
        XCTAssertTrue(app.buttons["ChatNewChat"].waitForExistence(timeout: 5), "no New Chat while a conversation is open")
        XCTAssertTrue(app.buttons["Back"].exists, "no back pill while a conversation is open")
        XCTAssertEqual(app.searchSideShown, "Chat")
        XCTAssertTrue(app.headTitled("Chat"), "an open conversation's head is not titled Chat")
        XCTAssertEqual(app.tab("Search").label, "Chat", "the last tab does not say Chat in a conversation")

        // Back: the chat's start, with this chat among the recent ones.
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["RecentAllChats"].waitForExistence(timeout: 5), "back did not go to the chat's start")
        XCTAssertEqual(app.searchSideShown, "Chat", "back left the Chat side")
        XCTAssertTrue(app.tab("Search").isSelected)

        // All Chats: a chat picked there goes back to the list, the list back to the start.
        app.buttons["RecentAllChats"].tap()
        let row = app.staticTexts[question].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the chat is not in All Chats")
        XCTAssertTrue(app.buttons["Back"].exists, "All Chats has no back pill")
        XCTAssertTrue(app.headTitled("All Chats"), "All Chats is not titled All Chats")
        row.tap()
        XCTAssertTrue(app.buttons["ChatNewChat"].waitForExistence(timeout: 5), "the chat did not open from All Chats")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "back from a chat picked in All Chats did not return to the list")
        XCTAssertEqual(app.searchSideShown, "Chat")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["RecentAllChats"].waitForExistence(timeout: 5), "back from All Chats did not go to the chat's start")
        XCTAssertEqual(app.searchSideShown, "Chat", "back from All Chats left the Chat side")

        // New Chat from an open conversation: an empty chat.
        app.buttons.matching(identifier: "RecentChat").firstMatch.tap()
        XCTAssertTrue(app.buttons["ChatNewChat"].waitForExistence(timeout: 5))
        app.buttons["ChatNewChat"].tap()
        XCTAssertTrue(app.staticTexts["Ask Your Bowls"].waitForExistence(timeout: 5), "New Chat did not start an empty chat")
    }
}
