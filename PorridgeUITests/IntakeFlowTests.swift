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

    /// The chat about a bowl opens from the bowl's ⋯ (Ask About This Bowl); it is kept and taken up again.
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
        // (documents got their payment state), that takes a while on a simulator full of earlier test entries.
        XCTAssertTrue(app.staticTexts["There is nothing in this bowl yet."].waitForExistence(timeout: 90), "answer missing")

        // Kept: it is in the list of chats, and asking about the bowl again shows it.
        app.buttons["All Chats"].tap()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 5), "chat missing in the list of chats")
        app.buttons["Back"].firstMatch.tap()
        app.openTab("Bowls")
        askAboutTheBowl()
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 10), "the chat was not taken up again")
        XCTAssertTrue(app.buttons["New Chat"].exists, "no way to start another chat")
    }
}
