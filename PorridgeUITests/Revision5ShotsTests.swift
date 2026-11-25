import XCTest

/// Pictures of owner revision 5 to look at: the tab bar with "+" in the middle, Today with its gear (and no Open
/// To-dos rows at its end), the Inbox's end card, Search | Chat on both sides, the chat with the keyboard open and put
/// away, the Add sheet from the Inbox and from a bowl. They go to /tmp/porridge-s10-shots (or `SHOTS_DIR`,
/// `TEST_RUNNER_SHOTS_DIR` for xcodebuild) when that folder exists; dark mode and the text size are switched from
/// outside (`xcrun simctl ui …`) and named by `SHOTS_SUFFIX`.
final class Revision5ShotsTests: XCTestCase {
    private lazy var folder = shotsFolder(default: "/tmp/porridge-s10-shots")
    private let suffix = ProcessInfo.processInfo.environment["SHOTS_SUFFIX"] ?? ""

    override func setUp() {
        continueAfterFailure = true
    }

    private func shoot(_ name: String) {
        sleep(1)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("ios-\(name)\(suffix).png"))
    }

    func testRevision5Screens() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO",
                                "-seedEntryKinds", "YES", "-seedTodos", "Garden", "-chatStub", "YES"]
        app.launch()
        XCTAssertTrue(app.addButton.waitForExistence(timeout: 30))
        app.openTab("Today")
        shoot("today")
        for _ in 0..<6 { app.swipeUp() }
        shoot("today-end")

        app.openTab("Inbox")
        shoot("inbox")
        app.openTodos()
        shoot("bowls-todos")
        app.bowlsSide("Bowls")
        app.openTab("Inbox")
        app.tapAddWhenHittable()
        shoot("add-sheet-inbox")
        app.buttons["Close"].tap()

        app.openTab("Bowls")
        let bowl = app.staticTexts["Kitchen Renovation"].firstMatch
        if app.reveal(bowl) {
            bowl.tap()
            _ = app.buttons["BowlMenu"].waitForExistence(timeout: 10)
            shoot("bowl")
            app.tapAddWhenHittable()
            shoot("add-sheet-bowl")
            app.buttons["Close"].tap()
            app.buttons["Back"].firstMatch.tap()
        }

        app.openTab("Search")
        app.searchSide("Search")
        shoot("search-empty")
        let field = app.textFields["SearchField"]
        field.tap()
        field.typeText("kitchen")
        shoot("search-typed")
        app.buttons["Clear Text"].tap()

        app.searchSide("Chat")
        if app.buttons["New Chat"].firstMatch.exists { app.buttons["New Chat"].firstMatch.tap() }
        shoot("chat")
        let chat = app.textFields["ChatField"].exists ? app.textFields["ChatField"] : app.textViews["ChatField"]
        chat.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        shoot("chat-keyboard-open")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 6, dy: chat.frame.minY - 30)).tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        shoot("chat-keyboard-dismissed")
        app.searchSide("Search")
        app.openTab("Today")
    }
}
