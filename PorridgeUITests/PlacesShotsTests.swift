import XCTest

/// Pictures of the three places to look at (design stage 4): filled and empty, a bowl's ⋯, the Add sheet, Settings
/// from the gear, Today on another day (dark mode is switched from outside: `xcrun simctl ui … appearance dark`, the
/// device's appearance from the test does not reach the app on this simulator). They go to /tmp/porridge-s4-shots (or `SHOTS_DIR`, `TEST_RUNNER_SHOTS_DIR` for xcodebuild) when that folder exists
/// (simulator only); without it the test only walks the screens.
final class PlacesShotsTests: XCTestCase {
    private lazy var folder = shotsFolder(default: "/tmp/porridge-s4-shots")

    override func setUp() {
        continueAfterFailure = true
    }

    private func shoot(_ name: String) {
        sleep(1)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("ios-\(name).png"))
    }

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-syncMode", "off", "-recordsNewNotes", "NO"] + extra
        app.launch()
        return app
    }

    func testFilledPlaces() throws {
        for dark in [false] {
            let suffix = dark ? "-dark" : ""
            let app = launch(["-seedEntryKinds", "YES", "-seedTodos", "Garden"])
            app.openTab("Today")
            shoot("today\(suffix)")
            app.swipeUp()
            shoot("today-end\(suffix)")
            app.openTab("Inbox")
            shoot("inbox\(suffix)")
            app.inboxSegment(1).tap()
            shoot("inbox-todos\(suffix)")
            app.inboxSegment(0).tap()
            app.openTab("Bowls")
            shoot("bowls\(suffix)")
            app.swipeUp()
            shoot("bowls-end\(suffix)")
            if dark { app.terminate(); continue }
            app.swipeDown()
            app.buttons["BowlSort"].tap()
            shoot("bowls-sort-menu")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.6)).tap()
            let bowl = app.staticTexts["Kitchen Renovation"].firstMatch
            if app.reveal(bowl) {
                bowl.tap()
                shoot("bowl")
                app.buttons["BowlMenu"].tap()
                shoot("bowl-menu")
                // Closed by a tap below it: with the largest text sizes the menu covers the left edge at 60 % too,
                // and a tap there chose one of its rows (Select Entries), which hides "+".
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8)).tap()
                _ = app.buttons["Select Entries"].waitForNonExistence(timeout: 3)
                sleep(1)
                XCTAssertTrue(app.addButton.waitForExistence(timeout: 5), "PlaceAdd missing after the bowl menu")
                app.tapAddWhenHittable()
                shoot("add-sheet-bowl")
                app.buttons["Close"].tap()
                app.buttons["Back"].firstMatch.tap()
            }
            app.buttons["Settings"].tap()
            shoot("settings")
            app.buttons["Back"].firstMatch.tap()
            app.openTab("Search")
            app.searchSide("Search")
            shoot("search")
            app.openTab("Today")
            app.addButton.tap()
            shoot("add-sheet")
            app.buttons["Close"].tap()
            // Another day with the longest short title of the week ahead.
            for step in 1...9 {
                app.buttons["TodayNextDay"].tap()
                if step == 2 || step == 8 { shoot("today-day-\(step)") }
            }
            app.terminate()
        }
    }

    func testEmptyPlaces() throws {
        do {
            let suffix = ""
            let app = launch(["-emptyStore", "YES"])
            app.openTab("Today")
            shoot("empty-today\(suffix)")
            app.openTab("Inbox")
            shoot("empty-inbox\(suffix)")
            app.openTab("Bowls")
            shoot("empty-bowls\(suffix)")
            app.terminate()
        }
    }
}
