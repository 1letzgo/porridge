import XCTest

/// Pictures of Search & Ask and the Chat tab to look at (design stage 5): the empty Chat tab, the empty search with
/// recent searches, a typed query with "Ask Porridge" first, the hand-over with an answer and its sources, a card of
/// changes to confirm, Ask About This Bowl, All Chats. They go to /tmp/porridge-s5-shots when that folder exists
/// (simulator only); `TEST_RUNNER_SHOT_SUFFIX=-dark` names a second run after the simulator was switched to dark.
/// The model is the Debug stand-in (`-chatStub YES`).
final class SearchAskShotsTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/porridge-s5-shots")
    private var suffix: String { ProcessInfo.processInfo.environment["SHOT_SUFFIX"] ?? "" }

    override func setUp() {
        continueAfterFailure = true
    }

    private func shoot(_ name: String) {
        sleep(1)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("ios-\(name)\(suffix).png"))
    }

    func testSearchAndChat() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-seedEntryKinds", "YES", "-chatStub", "YES"]
        app.launch()

        app.openTab("Chat")
        if app.buttons["New Chat"].firstMatch.exists { app.buttons["New Chat"].firstMatch.tap() }
        shoot("chat-empty")

        app.search(for: "invoice")
        shoot("search-typed")
        // Return keeps the search (Recent Searches) and lets the keyboard go.
        app.textFields["SearchField"].typeText("\n")
        app.textFields["SearchField"].tap()
        app.searchAgain(for: "q4")
        shoot("search-goto")
        app.searchAgain(for: "settings")
        shoot("search-goto-settings")
        // The empty field: recent searches and tags.
        app.buttons["Clear Text"].tap()
        shoot("search-empty")

        app.textFields["SearchField"].tap()
        app.searchAgain(for: "worktop colour")
        _ = app.buttons["SearchAsk"].waitForExistence(timeout: 10)
        app.buttons["SearchAsk"].tap()
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'From your notes'")).firstMatch.waitForExistence(timeout: 60)
        shoot("chat-answer")
        let field = app.textFields["ChatField"].exists ? app.textFields["ChatField"] : app.textViews["ChatField"]
        field.tap()
        field.typeText("Mark the worktop to-do as checked")
        app.buttons["ChatSend"].tap()
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Confirm All'")).firstMatch.waitForExistence(timeout: 60)
        // The keyboard goes with a slow drag down over the chat.
        app.scrollViews.firstMatch.swipeDown(velocity: .slow)
        shoot("chat-confirm-card")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Confirm All'")).firstMatch.tap()
        shoot("chat-confirmed-toast")

        app.buttons["All Chats"].firstMatch.tap()
        shoot("chat-all-chats")

        app.openTab("Bowls")
        let bowl = app.staticTexts["Kitchen Renovation"].firstMatch
        if app.reveal(bowl) {
            bowl.tap()
            app.buttons["BowlMenu"].tap()
            app.buttons["Ask About This Bowl"].tap()
            shoot("chat-about-bowl")
        }
        app.terminate()
    }
}
