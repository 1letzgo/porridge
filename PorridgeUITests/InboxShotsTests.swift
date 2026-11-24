import XCTest

/// Pictures of stage 6 to look at: Today with a to-do being ticked and on another day, the Inbox with "✦ Bowl" and
/// the one-line bundle card, both swipes, the Later sheet, Triage (also on a to-do) and the selection bar. They go to
/// /tmp/porridge-s6-shots when that folder exists (simulator only); dark mode is switched from outside
/// (`xcrun simctl ui … appearance dark`) and named by `TEST_RUNNER_SHOTS_SUFFIX=-dark`.
final class InboxShotsTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/porridge-s6-shots")
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
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-emptyStore", "YES", "-quietNotifications", "YES"] + extra
        app.launch()
        return app
    }

    func testToday() throws {
        let app = launch(["-seedTodos", "Garden"])
        app.openTab("Today")
        XCTAssertTrue(app.staticTexts["Garden today"].waitForExistence(timeout: 10))
        shoot("today")
        app.switches.matching(NSPredicate(format: "label == 'To-do' AND value == 'Not Done'")).firstMatch.tap()
        shoot("today-ticked")
        app.buttons["TodayNextDay"].tap()
        shoot("today-next-day")
        app.buttons["TodayPreviousDay"].tap()
        app.buttons["TodayPreviousDay"].tap()
        shoot("today-yesterday")
    }

    func testInbox() throws {
        let app = launch(["-seedInbox", "YES"])
        app.openTab("Inbox")
        let link = app.staticTexts["The Case for Slow Software"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        sleep(2)
        shoot("inbox")
        link.swipeRight()
        shoot("inbox-swipe-file")
        link.swipeLeft()
        let gift = app.staticTexts["Gift ideas for Mum"]
        if app.reveal(gift) {
            gift.swipeLeft()
            shoot("inbox-swipe-later")
            app.buttons["Later"].firstMatch.tap()
            shoot("inbox-later-sheet")
            app.buttons["Cancel"].tap()
        }
        app.swipeDown()
        app.swipeDown()

        app.buttons["InboxTriage"].tap()
        shoot("triage")
        app.buttons["TriageOther"].tap()
        shoot("triage-other")
        app.buttons["Cancel"].tap()
        // On to the to-do (the oldest entry, the last one).
        for _ in 0..<12 where !app.buttons["TriageDone"].exists && app.buttons["TriageSkip"].exists {
            app.buttons["TriageSkip"].tap()
        }
        shoot("triage-todo")
        app.buttons["TriageDone"].tap()
        shoot("triage-finished")
        app.buttons["TriageEnd"].tap()

        app.buttons["Select"].tap()
        for title in ["Invoice INV-2026-1142", "Invoice INV-2026-1098", "Receipt, hardware store"] {
            let row = app.staticTexts[title]
            if app.reveal(row) { row.tap() }
        }
        shoot("selection-bar")
        app.buttons["SelectionMore"].tap()
        shoot("selection-more")
    }
}
