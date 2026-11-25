import XCTest

/// Pictures of owner revision 6 to look at: the tab bar with the raised "+" (a badge "120" on the Inbox, each tab
/// chosen once), the Bowls tab on its three sides, the Search tab's Search and Chat sides (start, an open conversation,
/// All Chats) and the Inbox's card on top (owner revision 7). They go to /tmp/porridge-s11-shots (or `SHOTS_DIR`,
/// `TEST_RUNNER_SHOTS_DIR` for xcodebuild) when that folder exists; dark mode and the text size are switched from
/// outside (`xcrun simctl ui …`) and named by `SHOTS_SUFFIX`.
final class Revision6ShotsTests: XCTestCase {
    private lazy var folder = shotsFolder(default: "/tmp/porridge-s11-shots")
    private let suffix = ProcessInfo.processInfo.environment["SHOTS_SUFFIX"] ?? ""

    override func setUp() {
        continueAfterFailure = true
    }

    private func shoot(_ name: String) {
        sleep(1)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("ios-\(name)\(suffix).png"))
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO",
                                "-chatStub", "YES"] + extra
        app.launch()
        XCTAssertTrue(app.addButton.waitForExistence(timeout: 30))
        return app
    }

    func testTabBarWithABadgeOf120() throws {
        let app = launch(["-emptyStore", "YES", "-seedInboxCount", "120"])
        for tab in ["Today", "Inbox", "Bowls", "Search"] {
            app.openTab(tab)
            shoot("tabbar-120-\(tab.lowercased())")
        }
        app.openTab("Inbox")
        _ = app.buttons["InboxWeeklyReview"].waitForExistence(timeout: 10)
        shoot("inbox-top-card")
    }

    func testRevision6Screens() throws {
        let app = launch(["-seedEntryKinds", "YES", "-seedTodos", "Garden"])

        // Bowls: one bowl archived (made here when the Archive is empty), one entry deleted.
        app.openTab("Bowls")
        app.bowlsSide("Archive")
        if app.staticTexts["Nothing Archived"].waitForExistence(timeout: 2) {
            app.bowlsSide("Bowls")
            let name = unique("Old Trip")
            app.create("Bowl")
            let field = app.alerts.textFields.firstMatch
            if field.waitForExistence(timeout: 5) {
                field.typeText(name)
                app.alerts.buttons["Create"].tap()
                let menu = app.buttons["BowlMenu"]
                if menu.waitForExistence(timeout: 10) {
                    menu.tap()
                    let archive = app.buttons["Archive"]
                    if archive.waitForExistence(timeout: 5) { archive.tap() }
                }
                if app.buttons["Back"].firstMatch.exists { app.buttons["Back"].firstMatch.tap() }
            }
        }
        if app.bowlsSide("Deleted").label == "Deleted 0" {
            let name = unique("Old draft")
            app.newNote(title: name)
            app.goBack()
            app.openTab("Inbox")
            let row = app.staticTexts[name]
            if app.reveal(row) {
                row.press(forDuration: 1.2)
                let delete = app.buttons["Delete"]
                if delete.waitForExistence(timeout: 5) { delete.tap() }
            }
        }
        app.openTab("Bowls")
        app.bowlsSide("Bowls")
        shoot("bowls-bowls")
        app.bowlsSide("Archive")
        shoot("bowls-archive")
        app.bowlsSide("Deleted")
        shoot("bowls-deleted")
        app.bowlsSide("Bowls")

        // Search and Chat.
        app.openTab("Search")
        app.searchSide("Search")
        shoot("search")
        app.searchSide("Chat")
        if app.buttons["ChatNewChat"].exists { app.buttons["ChatNewChat"].tap() }
        shoot("chat-start")
        let field = app.textFields["ChatField"].exists ? app.textFields["ChatField"] : app.textViews["ChatField"]
        field.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        field.typeText("What is open in the kitchen?")
        app.tapSendWhenAboveTheKeyboard()
        _ = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'From your notes' OR label BEGINSWITH 'I found nothing'")).firstMatch.waitForExistence(timeout: 60)
        app.scrollViews.firstMatch.swipeDown(velocity: .slow)
        shoot("chat-conversation")
        app.openAllChats()
        shoot("chat-all-chats")
        app.buttons["Back"].firstMatch.tap()
        shoot("chat-back-to-start")
    }
}
