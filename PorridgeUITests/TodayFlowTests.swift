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

        // A note offers its appointment in the row of its bowl and tags.
        app.newNote(title: unique("Appointment note"))
        let chip = app.buttons["Link to Appointment"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "no appointment button beside the tags")
        app.titleField.typeText("\n")
        chip.tap()
        XCTAssertTrue(app.navigationBars["Appointment"].waitForExistence(timeout: 5), "the appointment picker did not open")
        screenshot("appointment-picker", app)
        app.buttons["Cancel"].tap()
    }
}
