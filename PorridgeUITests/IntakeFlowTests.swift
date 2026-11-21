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

        // The inbox is the first category on the home list; opened, the newest is on top.
        let inbox = app.buttons["InboxCategory"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 15), "Inbox missing on the home list")
        inbox.tap()
        let row = app.staticTexts[title]
        XCTAssertTrue(app.reveal(row), "new note not in the inbox")

        // There is no way out but a bowl. The long press of the row has the bowls, as in every list.
        XCTAssertFalse(app.buttons["Keep without Bowl"].exists, "the inbox still offers to keep without a bowl")
        XCTAssertFalse(app.buttons["File into Bowl"].exists, "the inbox still shows a bowl pill under the row")
        row.press(forDuration: 1)
        let file = app.buttons["Bowls"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 5), "bowls missing in the long press")
        file.tap()
        // With many bowls the menu scrolls; the new one may be further down.
        let choice = app.buttons[bucket].firstMatch
        for _ in 0..<12 where !choice.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "bowl missing in the menu")
        choice.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "filed note still in the inbox")
    }

    /// The chat is a page of its own, opened from its button bottom left; a chat about a bowl is kept and taken up again.
    func testAChatAboutABucketIsKeptAndTakenUpAgain() throws {
        let app = launchApp()
        let bucket = unique("Chat")
        app.create("Bowl")
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "name field missing")
        name.typeText(bucket)
        app.confirmAlert("Create")

        // In the new bowl the chat is about it. It is empty, so the answer needs no model.
        let chat = app.buttons["Chat"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "chat button missing")
        chat.tap()
        XCTAssertTrue(app.buttons["Chat About"].waitForExistence(timeout: 5), "the chat does not say what it is about")
        let field = app.textFields["ChatField"].exists ? app.textFields["ChatField"] : app.textViews["ChatField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "chat field missing")
        field.tap()
        let question = unique("What is in here")
        field.typeText(question)
        app.buttons["ChatSend"].tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 10), "question missing in the chat")
        XCTAssertTrue(app.staticTexts["There is nothing in this bowl yet."].waitForExistence(timeout: 20), "answer missing")

        // Kept: it is in the list of chats, and opening the chat again shows it.
        app.buttons["All Chats"].tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 5), "chat missing in the list of chats")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
        chat.tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 10), "the chat was not taken up again")
        XCTAssertTrue(app.buttons["New Chat"].exists, "no way to start another chat")
    }
}
