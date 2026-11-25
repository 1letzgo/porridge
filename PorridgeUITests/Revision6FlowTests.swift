import XCTest

/// Owner revision 6: the Bowls tab's switch Bowls · Archive · Deleted (in place of the two rows at the end of the
/// list), and the Search tab's Chat side without a page title of its own or a list pill in the bar.
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

    /// The switch has three sides with counts; Sort shows only on Bowls, Delete All only on Deleted (when something is
    /// there); "+" on Archive and Deleted adds to the Inbox; a cold launch starts on Bowls again.
    func testBowlsSwitchesToArchiveAndDeleted() throws {
        let app = launch()
        app.openTab("Bowls")
        let bowls = app.bowlsSide("Bowls")
        XCTAssertTrue(bowls.isSelected, "Bowls does not start on its Bowls side")
        XCTAssertTrue(app.buttons["BowlSort"].exists, "no Sort on the Bowls side")
        XCTAssertTrue(app.reveal(app.buttons["NewSmartFilter"]), "Smart Filters missing on the Bowls side")
        XCTAssertFalse(app.buttons["BowlsArchive"].exists, "the Archive row is still there")
        XCTAssertFalse(app.buttons["BowlsRecentlyDeleted"].exists, "the Recently Deleted row is still there")

        let archive = app.bowlsSide("Archive")
        XCTAssertTrue(archive.isSelected, "Archive did not open")
        XCTAssertFalse(app.buttons["BowlSort"].exists, "Sort shows on the Archive side")
        XCTAssertTrue(app.buttons["PlaceSettings"].exists, "the gear left the bar")
        XCTAssertTrue(app.tapAddWhenHittable(), "+ did not open the Add sheet on the Archive side")
        let into = app.buttons["AddInto"]
        XCTAssertTrue(into.waitForExistence(timeout: 5), "the Add sheet has no Into")
        XCTAssertEqual(into.label, "Into: Inbox", "+ on the Archive side does not add to the Inbox")
        app.buttons["Close"].tap()

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

        app.openTab("Bowls")
        let deleted = app.bowlsSide("Deleted")
        XCTAssertTrue(deleted.isSelected, "Deleted did not open")
        XCTAssertFalse(deleted.label == "Deleted 0", "the Deleted side does not count its entries: \(deleted.label)")
        XCTAssertTrue(app.staticTexts.matching(deletedPredicate).firstMatch.waitForExistence(timeout: 5), "no 30-days hint")
        XCTAssertTrue(app.reveal(app.staticTexts[name]), "the deleted note is not on the Deleted side")
        XCTAssertTrue(app.buttons["TrashDeleteAll"].exists, "no Delete All on the Deleted side")
        XCTAssertFalse(app.buttons["BowlSort"].exists, "Sort shows on the Deleted side")

        // Another tab and back keeps the side; a cold launch starts on Bowls.
        app.openTab("Today")
        app.openTab("Bowls")
        XCTAssertTrue(app.bowlsSide("Deleted").isSelected, "the side was not kept while the app ran")
        app.terminate()
        let again = launch()
        again.openTab("Bowls")
        XCTAssertTrue(again.buttons["BowlSort"].waitForExistence(timeout: 10), "a cold launch did not start on Bowls")
        XCTAssertTrue(again.bowlsSide("Bowls").isSelected, "a cold launch did not start on Bowls")
    }

    /// Go To rows of the search land on the Bowls tab on the right side.
    func testGoToArchiveAndRecentlyDeletedSelectTheirSide() throws {
        let app = launch()
        app.search(for: "Recently Deleted")
        let goTo = app.buttons.matching(identifier: "GoTo").matching(NSPredicate(format: "label CONTAINS 'Recently Deleted'")).firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: 10), "no Go To row for Recently Deleted")
        goTo.tap()
        XCTAssertTrue(app.tab("Bowls").waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.tab("Bowls"))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.bowlsSide("Deleted").isSelected, "Go To Recently Deleted did not select the Deleted side")

        app.openTab("Search")
        app.searchAgain(for: "Archive")
        let archive = app.buttons.matching(identifier: "GoTo").matching(NSPredicate(format: "label BEGINSWITH 'Archive'")).firstMatch
        XCTAssertTrue(archive.waitForExistence(timeout: 10), "no Go To row for Archive")
        archive.tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.tab("Bowls"))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.bowlsSide("Archive").isSelected, "Go To Archive did not select the Archive side")
        XCTAssertFalse(app.buttons["Back"].exists, "Archive was pushed as a page of its own")
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
