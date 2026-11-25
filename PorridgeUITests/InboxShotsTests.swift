import XCTest

/// Pictures of stage 6 to look at: Today with a to-do being ticked and on another day, the Inbox with "✦ Bowl" and
/// the one-line bundle card, both swipes, the Later sheet, Triage (also on a to-do) and the selection bar. They go to
/// /tmp/porridge-s6-shots (or `SHOTS_DIR`, `TEST_RUNNER_SHOTS_DIR` for xcodebuild) when that folder exists (simulator only); dark mode is switched from outside
/// (`xcrun simctl ui … appearance dark`) and named by `TEST_RUNNER_SHOTS_SUFFIX=-dark`.
final class InboxShotsTests: XCTestCase {
    private lazy var folder = shotsFolder(default: "/tmp/porridge-s6-shots")
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
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-emptyStore", "YES", "-quietNotifications", "YES"] + extra
        app.launch()
        return app
    }

    func testToday() throws {
        let app = launch(["-seedTodos", "Garden"])
        app.openTab("Today")
        // With the largest text sizes the to-do is further down: the list is scrolled to it.
        let todo = app.staticTexts["Garden today"]
        for _ in 0..<5 where !(todo.waitForExistence(timeout: 3) && todo.isHittable) { app.swipeUp() }
        XCTAssertTrue(todo.exists)
        shoot("today")
        let box = app.switches.matching(NSPredicate(format: "label == 'To-do' AND value == 'Not Done'")).firstMatch
        for _ in 0..<3 where !box.isHittable { app.swipeUp() }
        box.tap()
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
        // With the largest text sizes the list can still be settling after the swipes: only a row that stays is swiped.
        if app.reveal(gift), gift.waitForExistence(timeout: 3), gift.isHittable {
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
        // With the largest text sizes a tall card can push the buttons below the fold: scrolled to first.
        for _ in 0..<16 where !app.buttons["TriageDone"].exists {
            let skip = app.buttons["TriageSkip"]
            if !(skip.exists && skip.isHittable) {
                app.scrollViews.firstMatch.swipeUp()
                continue
            }
            skip.tap()
        }
        if app.buttons["TriageDone"].exists, !app.buttons["TriageDone"].isHittable { app.scrollViews.firstMatch.swipeUp() }
        shoot("triage-todo")
        app.buttons["TriageDone"].tap()
        shoot("triage-finished")
        app.buttons["TriageEnd"].tap()

        app.buttons["Select"].tap()
        for title in ["Invoice INV-2026-1142", "Invoice INV-2026-1098", "Receipt, hardware store"] {
            app.revealAndTap(app.staticTexts[title].firstMatch)
        }
        shoot("selection-bar")
        app.buttons["SelectionMore"].tap()
        shoot("selection-more")
    }
}
