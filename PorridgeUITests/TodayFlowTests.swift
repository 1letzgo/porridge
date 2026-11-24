import XCTest

/// Today, the first tab: its page with appointments and to-dos, and linking an entry to an appointment.
final class TodayFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTodayCardOpensTheDayAndAnEntryOffersAnAppointment() throws {
        let prefix = unique("Today")
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-seedTodos", prefix]
        app.launch()

        // Today is the first tab.
        app.openTab("Today")
        XCTAssertTrue(app.staticTexts["Appointments"].waitForExistence(timeout: 10), "no appointments on the Today page")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Due'")).firstMatch.exists, "no to-dos due on the Today page")
        // The seeded to-do due today and the one long overdue are there; the one due later is not.
        XCTAssertTrue(app.staticTexts["\(prefix) long overdue"].waitForExistence(timeout: 5), "an overdue to-do is missing")
        screenshot("today-page", app)

        // A note is linked to an appointment from the Appointment section of Details ("Link…").
        app.newNote(title: unique("Appointment note"))
        app.titleField.typeText("\n")
        app.openDetails()
        let link = app.buttons["Link…"].firstMatch
        let form = app.collectionViews.firstMatch
        for _ in 0..<4 where !(link.exists && link.isHittable) { form.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5), "no Link… in the Appointment section of Details")
        link.tap()
        XCTAssertTrue(app.navigationBars["Appointment"].waitForExistence(timeout: 5), "the appointment picker did not open")
        screenshot("appointment-picker", app)
        app.buttons["Cancel"].tap()
    }

    /// Today shows only what is open: a to-do ticked there leaves the list with the undo toast, Undo brings it back,
    /// and no other day shows done to-dos either. It stays in Open To-dos under "Done Today".
    func testTickedTodoLeavesToday() throws {
        let prefix = unique("Tick")
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-emptyStore", "YES", "-seedTodos", prefix]
        app.launch()
        app.openTab("Today")

        let title = app.staticTexts["\(prefix) today"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "the to-do due today is missing")
        let open = app.switches.matching(NSPredicate(format: "label == 'To-do' AND value == 'Not Done'"))
        let done = app.switches.matching(NSPredicate(format: "label == 'To-do' AND value == 'Done'"))
        let before = open.count
        XCTAssertGreaterThanOrEqual(before, 2, "the due and the overdue to-do should have boxes")
        open.firstMatch.tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 5), "ticking in Today offers no Undo")
        let gone = NSPredicate(format: "count == %d", before - 1)
        expectation(for: gone, evaluatedWith: open)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(done.count, 0, "a done to-do is still shown in Today")
        screenshot("today-ticked", app)

        app.buttons["Undo"].tap()
        expectation(for: NSPredicate(format: "count == %d", before), evaluatedWith: open)
        waitForExpectations(timeout: 5)

        // Ticked again; no other day shows it (yesterday, tomorrow).
        open.firstMatch.tap()
        expectation(for: gone, evaluatedWith: open)
        waitForExpectations(timeout: 5)
        app.buttons["TodayPreviousDay"].tap()
        XCTAssertEqual(done.count, 0, "yesterday shows a done to-do")
        app.buttons["TodayNextDay"].tap()
        app.buttons["TodayNextDay"].tap()
        XCTAssertEqual(done.count, 0, "tomorrow shows a done to-do")
        app.buttons["TodayPreviousDay"].tap()

        // Open To-dos keeps it under Done Today.
        let entry = app.buttons["TodayOpenTodos"]
        XCTAssertTrue(app.reveal(entry), "Open To-dos missing in Today")
        entry.tap()
        XCTAssertTrue(app.reveal(app.staticTexts["Done Today"]), "the ticked to-do is not under Done Today in Open To-dos")
    }
}
