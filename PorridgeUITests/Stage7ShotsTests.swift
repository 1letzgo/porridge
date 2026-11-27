import XCTest

/// Stage 7 (design E): the one-time What's New card on Today, the onboarding's last page with the places, the editor
/// bar (✦ with and without a selection, Link to Entry), a meeting and Settings. Pictures go to `SHOTS_DIR`
/// (`TEST_RUNNER_SHOTS_DIR` for xcodebuild) or /tmp/porridge-s7-shots when that folder exists; the text size and
/// dark mode are switched from outside (`xcrun simctl ui …`) and named by `SHOTS_SUFFIX`.
final class Stage7ShotsTests: XCTestCase {
    private lazy var folder = shotsFolder(default: "/tmp/porridge-s7-shots")
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
        app.launchArguments += ["-syncMode", "off", "-recordsNewNotes", "NO", "-quietNotifications", "YES"] + extra
        app.launch()
        return app
    }

    /// After the update: the card on top of Today, once; "Got It" puts it away.
    func testWhatsNewCardOnToday() throws {
        let app = launch(["-onboardingDone", "YES", "-resetWhatsNew", "YES", "-seedTodos", "Garden"])
        app.openTab("Today")
        let card = app.descendants(matching: .any)["WhatsNew"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no What's New card on Today")
        XCTAssertTrue(app.staticTexts["Three Places"].exists)
        shoot("whats-new")
        let done = app.buttons["WhatsNewDone"]
        // Small steps: a swipe flings the list past the card on a small screen, and "Got It" must end up above the
        // tab bar, not under it.
        let tabBar = app.placeTabBar
        func reachable() -> Bool {
            guard done.exists, done.isHittable else { return false }
            return !tabBar.exists || done.frame.maxY <= tabBar.frame.minY
        }
        for _ in 0..<12 where !reachable() {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        XCTAssertTrue(reachable(), "Got It cannot be reached above the tab bar")
        shoot("whats-new-end")
        done.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 5), "Got It did not put the card away")
        shoot("whats-new-gone")
    }

    /// A new install: the onboarding ends on the places (and no card after it).
    func testOnboardingShowsThePlaces() throws {
        let app = launch(["-onboardingDone", "NO", "-resetWhatsNew", "YES", "-emptyStore", "YES"])
        let start = app.buttons["Get Started"]
        XCTAssertTrue(start.waitForExistence(timeout: 15), "no onboarding")
        shoot("onboarding-welcome")
        start.tap()
        // The microphone is granted from outside (`simctl privacy`); without that the system asks.
        let allow = app.buttons["Allow Microphone"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let cont = app.buttons["Continue"]
        if cont.waitForExistence(timeout: 5) { cont.tap() }
        let later = app.buttons["Later"]
        if later.waitForExistence(timeout: 10) { later.tap() } else if cont.waitForExistence(timeout: 3) { cont.tap() }
        // The speaker model may be downloading first (the switch is on).
        XCTAssertTrue(app.staticTexts["All Set"].waitForExistence(timeout: 120), "the last page did not come")
        XCTAssertTrue(app.staticTexts["Bowls"].exists, "the last page names the places")
        shoot("onboarding-places")
        app.buttons["Done"].firstMatch.tap()
        app.openTab("Today")
        XCTAssertFalse(app.descendants(matching: .any)["WhatsNew"].waitForExistence(timeout: 3), "a new install saw the What's New card")
    }

    /// The editor bar: Aa · Checklist · Insert · ✦ · Outdent · Indent · Mic · Done; ✦ without a selection asks for
    /// one; Insert has Link to Entry.
    func testEditorBarAndMeeting() throws {
        let app = launch(["-onboardingDone", "YES", "-whatsNewSeen", "YES", "-seedEntryKinds", "YES"])
        app.openTab("Bowls")
        XCTAssertTrue(app.addButton.waitForExistence(timeout: 30))
        app.open(URL(string: "porridge://entry/5EED0000-0000-4000-8000-000000000005")!)
        let editor = app.bodyEditor
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the note did not open")
        editor.tap()
        let rewrite = app.buttons["EditorRewrite"]
        XCTAssertTrue(rewrite.waitForExistence(timeout: 5), "no ✦ in the editor bar")
        XCTAssertTrue(app.buttons["EditorDictate"].exists, "no mic in the editor bar")
        XCTAssertTrue(app.buttons["Checklist"].exists)
        shoot("editor-bar")
        rewrite.tap()
        XCTAssertTrue(app.alerts["Select Text to Rewrite"].waitForExistence(timeout: 5), "✦ without a selection says what to do")
        shoot("editor-rewrite-no-selection")
        app.alerts.buttons["OK"].tap()
        _ = app.alerts.firstMatch.waitForNonExistence(timeout: 5)
        let insert = app.buttons["Insert"].firstMatch
        // The menu's rows carry their symbol's name as identifier: they are found by their label.
        func button(_ label: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch }
        let link = button("Link to Entry [[")
        let rows = ["Link to Entry [[", "Heading", "Table", "Photo", "Image from Files", "Divider", "Quote", "Code Block"]
        func menuRow() -> XCUIElement? {
            rows.map(button).first { $0.exists && $0.isHittable }
        }
        insert.tap()
        // A press while the alert was still going away opens nothing: once more (only when no row of the menu is up,
        // a second press would close it).
        var waited = 0
        while menuRow() == nil, waited < 15 { usleep(200_000); waited += 1 }
        if menuRow() == nil { insert.tap() }
        // With the largest text sizes (or a small screen) the menu is taller than the room: Link to Entry is then
        // scrolled out of the menu (above or below, the menu may open either way round). The menu is flicked fast
        // (a slow drag that ends on a row chooses that row).
        let menu = app.collectionViews.containing(NSPredicate(format: "label == %@", "Heading")).firstMatch
        for direction in [true, false] {
            for _ in 0..<3 where menu.exists && !(link.exists && link.isHittable) {
                if direction { menu.swipeDown(velocity: .fast) } else { menu.swipeUp(velocity: .fast) }
                usleep(500_000)
            }
        }
        XCTAssertTrue(link.waitForExistence(timeout: 5), "no Link to Entry in Insert")
        shoot("editor-insert")
        link.tap()
        shoot("editor-link-suggestions")
        app.buttons["EditorDone"].tap()

        app.open(URL(string: "porridge://entry/5EED0000-0000-4000-8000-000000000001")!)
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "Design Review")).firstMatch.waitForExistence(timeout: 10))
        shoot("meeting")
        app.openSettings()
        shoot("settings-general")
    }
}
