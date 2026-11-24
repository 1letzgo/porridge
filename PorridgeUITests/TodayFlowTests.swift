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
}
