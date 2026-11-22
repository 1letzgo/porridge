import XCTest

final class NotesFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Creating a note must open it and keep it open.
    func testCreateNoteStaysOpen() throws {
        let app = launchApp()
        app.newNote()
        sleep(3)
        XCTAssertTrue(app.titleField.exists, "note closed again by itself")
        XCTAssertFalse(app.buttons["Create"].isHittable, "list is showing again")
    }

    /// Create a note, leave it empty, go back, create another one: it must open and stay open.
    func testCreateNoteTwiceAfterLeavingEmpty() throws {
        let app = launchApp()
        for attempt in 1...3 {
            app.newNote()
            sleep(2)
            XCTAssertTrue(app.titleField.exists, "note closed by itself (attempt \(attempt))")
            // Back to the list without typing anything, and give the animation time to finish.
            app.goBack()
            sleep(2)
        }
    }

    /// Settings and its subpages open in place; afterwards the list still answers as before.
    func testRecordNewNotesSwitchInSettings() throws {
        let app = launchApp()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "settings button missing")
        settings.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10), "settings did not open")
        // The settings are split into areas; the switch is in "Recording".
        app.buttons["Recording"].firstMatch.tap()
        XCTAssertTrue(app.reveal(app.switches["Record New Notes Automatically"].firstMatch), "switch missing")
    }

    func testSettingsSubpageAndBack() throws {
        let app = launchApp()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "settings button missing")
        settings.tap()
        let row = app.buttons["Acknowledgements"].firstMatch
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10), "settings did not open")
        // The settings are split into areas; the row is in "General", which is still chosen after coming back.
        app.buttons["General"].firstMatch.tap()
        XCTAssertTrue(app.reveal(row), "acknowledgements row missing")
        row.tap()
        XCTAssertTrue(app.staticTexts["Libraries"].waitForExistence(timeout: 10), "acknowledgements did not open")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 10), "settings missing after going back")
        app.goBack()
        app.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), "plus did not open its menu")
    }

    /// A note with content is kept and can be opened again from the search.
    func testNoteWithContentIsKeptAndReopens() throws {
        let app = launchApp()
        let name = unique("Kept")
        app.newNote(title: name)
        app.goBack()
        sleep(2)

        app.search(for: name)
        let row = try XCTUnwrap(app.searchResult(name), "note with a title was not kept")
        row.tap()
        // A filled title field is known by its value: the placeholder "Title" is gone.
        let reopened = app.textFields.matching(NSPredicate(format: "value == %@", name)).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10), "note did not open from the search")
    }

    /// VoiceOver sees what this test sees: a row of the list has to be something to press.
    func testNoteRowIsAButtonForAssistiveTechnologies() throws {
        let app = launchApp()
        let title = unique("Row")
        app.create("Note")
        let field = app.titleField
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title)
        app.buttons["Back"].firstMatch.tap()
        // A new note waits in the inbox, the first entry of the home list.
        let inbox = app.buttons["InboxCategory"]
        XCTAssertTrue(inbox.waitForExistence(timeout: 10), "Inbox missing on the home list")
        inbox.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "row is not a button:\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", title)).firstMatch.waitForExistence(timeout: 10), "row did not open the note")
    }

    /// The largest text size: a picture of the list to look at, and the buttons still there.
    func testLargestTextKeepsTheBottomButtons() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Create"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Create"].isHittable)
        app.buttons["Create"].tap()
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "largest-text-plus-menu"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// After an export from Settings and going back, the bar of the home screen shows its Import button right away.
    /// (Presented by UIKit over the root, the export sheet left the Import menu without its label for seconds.)
    func testImportButtonShowsAfterExport() throws {
        let app = launchApp()
        let importButton = app.buttons["Import"]
        let settings = app.buttons["Settings"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 30), "import button missing")
        settings.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10), "settings did not open")
        app.buttons["General"].firstMatch.tap()
        let export = app.buttons["Export…"].firstMatch
        XCTAssertTrue(app.reveal(export), "export button missing")
        export.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 120), "export did not finish")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "export sheet did not close")
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "home missing after going back")
        // The button is in the tree all along; what went missing was its picture. Compared with the gear next to it.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let shown = Self.inkedPixels(importButton.screenshot().image)
            let reference = Self.inkedPixels(settings.screenshot().image)
            XCTAssertGreaterThan(shown, reference / 3, "import button drawn without its icon (\(shown) of \(reference))")
            if shown <= reference / 3 { break }
        }
    }

    /// Pixels that differ clearly from the top left corner (the bar behind the button).
    private static func inkedPixels(_ image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let background = (Int(data[0]), Int(data[1]), Int(data[2]))
        var count = 0
        for index in stride(from: 0, to: data.count, by: 4) {
            let difference = abs(Int(data[index]) - background.0) + abs(Int(data[index + 1]) - background.1) + abs(Int(data[index + 2]) - background.2)
            if difference > 120 { count += 1 }
        }
        return count
    }
}
