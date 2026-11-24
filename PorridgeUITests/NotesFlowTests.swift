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
        XCTAssertFalse(app.buttons.matching(identifier: "PlaceAdd").allElementsBoundByIndex.contains { $0.isHittable }, "list is showing again")
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
        // Settings is the gear in the Bowls bar.
        app.openTab("Bowls")
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
        app.openTab("Bowls")
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
        app.addButton.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5), "plus did not open the Add sheet")
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
        // A new note waits in the Inbox, the second tab.
        app.openTab("Inbox")
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
        XCTAssertTrue(app.addButton.waitForExistence(timeout: 30))
        XCTAssertTrue(app.addButton.isHittable, "the bar's + is cut off")
        for tab in ["Inbox", "Bowls", "Today"] {
            app.openTab(tab)
            XCTAssertTrue(app.addButton.isHittable, "\(tab): the bar's + is cut off")
        }
        app.addButton.tap()
        sleep(1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "largest-text-add-sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// After an export from Settings and going back, the Bowls bar shows its sort menu right away. (Presented by UIKit
    /// over the root, the export sheet once left a menu of the bar without its label for seconds.)
    func testBarMenuShowsAfterExport() throws {
        let app = launchApp()
        app.openTab("Bowls")
        let importButton = app.buttons["BowlSort"]
        let settings = app.buttons["Settings"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 30), "sort menu missing")
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
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Bowls missing after going back")
        // The button is in the tree all along; what went missing was its picture. Compared with the gear next to it.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let shown = Self.inkedPixels(importButton.screenshot().image)
            let reference = Self.inkedPixels(settings.screenshot().image)
            XCTAssertGreaterThan(shown, reference / 3, "sort menu drawn without its icon (\(shown) of \(reference))")
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

    /// The three places and the search are tabs; each place's bar ends in "+"; Today ends in its fixed rows, Bowls in
    /// Smart Filters, Archive and Recently Deleted, also when they are empty.
    func testThreePlacesAsTabs() throws {
        let app = launchApp()
        for tab in ["Today", "Inbox", "Bowls", "Chat", "Search"] {
            XCTAssertTrue(app.tabBars.buttons[tab].waitForExistence(timeout: 30), "tab \(tab) missing")
        }
        app.openTab("Today")
        XCTAssertTrue(app.addButton.waitForExistence(timeout: 10), "Today has no +")
        XCTAssertTrue(app.buttons["TodayNextDay"].exists, "Today has no day paging")
        XCTAssertTrue(app.reveal(app.buttons["TodayOpenTodos"]), "Open To-dos row missing in Today")
        XCTAssertTrue(app.buttons["TodayWeeklyReview"].exists, "Weekly Review row missing in Today")
        app.buttons["TodayOpenTodos"].tap()
        XCTAssertTrue(app.staticTexts["Open To-dos"].waitForExistence(timeout: 5), "Open To-dos did not open")
        app.buttons["Back"].firstMatch.tap()
        app.openTab("Inbox")
        XCTAssertTrue(app.segmentedControls["InboxSegment"].waitForExistence(timeout: 5), "Inbox has no New / Later")
        XCTAssertTrue(app.buttons["Select"].exists, "Inbox has no Select")
        app.openTab("Bowls")
        XCTAssertTrue(app.buttons["BowlSort"].waitForExistence(timeout: 5), "Bowls has no sort menu")
        XCTAssertTrue(app.buttons["Settings"].exists, "Bowls has no Settings gear")
        let archive = app.buttons["BowlsArchive"]
        XCTAssertTrue(app.reveal(archive), "Archive row missing")
        XCTAssertTrue(app.buttons["BowlsRecentlyDeleted"].exists, "Recently Deleted row missing")
        XCTAssertTrue(app.buttons["NewSmartFilter"].exists, "New Smart Filter… missing")
        archive.tap()
        XCTAssertTrue(app.staticTexts["Archive"].waitForExistence(timeout: 5), "Archive did not open")
        app.buttons["Back"].firstMatch.tap()
        app.openTab("Search")
        XCTAssertTrue(app.textFields["SearchField"].waitForExistence(timeout: 5), "the search tab has no field")
        app.openTab("Chat")
        XCTAssertTrue(app.buttons["Chat About"].waitForExistence(timeout: 5), "the Chat tab shows no chat")
    }

    /// "+" in a bowl: the Add sheet puts new things into that bowl ("Into:"); its ⋯ holds the bowl's management.
    func testAddSheetAndBowlMenu() throws {
        let app = launchApp()
        let name = unique("Bowl")
        app.openTab("Bowls")
        app.create("Bowl")
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(name)
        app.confirmAlert("Create")
        // The new bowl opens on the Bowls tab.
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10), "the new bowl did not open")
        let menu = app.buttons["BowlMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "bowl has no ⋯")
        menu.tap()
        for item in ["Select Entries", "Pin", "Rename…", "Ask About This Bowl", "Export Bowl…", "Archive", "Delete Bowl…"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 3), "bowl menu lacks \(item)")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.6)).tap()
        app.addButton.tap()
        let into = app.buttons["AddInto"]
        XCTAssertTrue(into.waitForExistence(timeout: 5), "Add sheet has no Into")
        XCTAssertTrue(into.label.contains(name), "Into is not the open bowl: \(into.label)")
        for item in ["Note", "To-do", "Meeting", "Link", "Photo or File"] {
            XCTAssertTrue(app.buttons[item].exists, "Add sheet lacks \(item)")
        }
        app.collectionViews.firstMatch.swipeUp()
        for item in ["Import Audio", "Import from Plaud", "New Bowl…"] {
            XCTAssertTrue(app.buttons[item].waitForExistence(timeout: 3), "Add sheet lacks \(item)")
        }
        app.collectionViews.firstMatch.swipeDown()
        app.buttons["Note"].tap()
        XCTAssertTrue(app.waitForTitleField(), "the note did not open")
        app.titleField.tap()
        app.titleField.typeText(unique("In bowl"))
        app.goBack()
        XCTAssertTrue(app.staticTexts[name].exists, "back is not the bowl")
    }

    /// A `porridge://entry/<id>` link opens the entry at once, on the tab in front, without another tap.
    func testEntryLinkOpensAtOnce() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-seedEntryKinds", "YES"]
        app.launch()
        app.openTab("Bowls")
        XCTAssertTrue(app.addButton.waitForExistence(timeout: 30))
        app.open(URL(string: "porridge://entry/5EED0000-0000-4000-8000-000000000005")!)
        let opened = app.textFields.matching(NSPredicate(format: "value == %@", "Packing list & plan")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 5), "the entry of the link did not open by itself")
        // Again from another tab, with an entry open.
        app.openTab("Today")
        app.open(URL(string: "porridge://entry/5EED0000-0000-4000-8000-000000000002")!)
        let todo = app.textFields.matching(NSPredicate(format: "value == %@", "Choose worktop colour")).firstMatch
        XCTAssertTrue(todo.waitForExistence(timeout: 5), "the second link did not open by itself")
        // `porridge://bowls` brings the Bowls place to the front.
        app.open(URL(string: "porridge://bowls")!)
        XCTAssertTrue(app.buttons["BowlSort"].waitForExistence(timeout: 5), "porridge://bowls did not open Bowls")
    }

    /// An entry's head opens Details at the section of a value; the bowl is changed there.
    func testMeetingDetailsFromMetaValueChangesBowl() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-seedEntryKinds", "YES"]
        app.launch()
        app.search(for: "Design Review")
        let row = try XCTUnwrap(app.searchResult("Design Review"), "seeded meeting missing")
        row.tap()
        // The speakers value of the meta line opens Details at Speakers.
        let speakers = app.buttons["4 Speakers · 1 unnamed"]
        XCTAssertTrue(speakers.waitForExistence(timeout: 10), "meta value missing")
        speakers.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5), "Details did not open")
        XCTAssertTrue(app.buttons["Known Voices…"].waitForExistence(timeout: 5), "Speakers section missing")
        let bowl = app.buttons["Bowl"].firstMatch
        // Back up to Organize inside the sheet (a swipe on the app would close the sheet).
        let form = app.collectionViews.firstMatch
        app.navigationBars["Details"].swipeUp()
        for _ in 0..<4 where !bowl.isHittable { form.swipeDown() }
        XCTAssertTrue(bowl.isHittable, "bowl row missing")
        let before = bowl.value as? String ?? ""
        let target = before == "Inbox" ? "Q4 Planning" : "Inbox"
        bowl.tap()
        // The tab bar has an "Inbox" button too (behind the sheet): the menu's row is another one. The menu can take a
        // moment to open; it is opened again when it did not.
        let tab = app.tabBars.buttons[target]
        let tabFrame = tab.exists ? tab.frame : .zero
        func menuRow() -> XCUIElement? {
            app.buttons.matching(identifier: target).allElementsBoundByIndex.last { $0.exists && $0.isHittable && $0.frame != tabFrame }
        }
        var choice: XCUIElement?
        for attempt in 0..<3 where choice == nil {
            if attempt > 0 { bowl.tap() }
            let deadline = Date().addingTimeInterval(4)
            while choice == nil, Date() < deadline {
                choice = menuRow()
                if choice == nil { usleep(250_000) }
            }
        }
        XCTAssertNotNil(choice, "\(target) missing in the bowl menu")
        choice?.tap()
        let changed = NSPredicate(format: "value == %@", target)
        expectation(for: changed, evaluatedWith: bowl)
        waitForExpectations(timeout: 5)
        app.navigationBars["Details"].buttons["Done"].tap()
        // A name in the transcript opens the speaker menu, with "Only This Line".
        app.buttons["Transcript"].firstMatch.tap()
        let name = app.buttons.matching(NSPredicate(format: "label == 'Speaker Speaker 4'")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5), "speaker name is no button")
        name.tap()
        XCTAssertTrue(app.buttons["Only This Line"].waitForExistence(timeout: 5), "speaker menu did not open")
        XCTAssertTrue(app.buttons["Other Name…"].exists)
    }

    /// ✦ AI · Share · ⋯ More of every kind show the items of `EntryMenus` (design table 3.1); screenshots of each
    /// open menu go to /tmp/porridge-s3-shots when that folder exists (simulator only).
    func testEntryPillsPerKind() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-onboardingDone", "YES", "-syncMode", "off", "-recordsNewNotes", "NO", "-seedEntryKinds", "YES"]
        app.launch()
        let kinds: [(name: String, title: String, ai: [String], notAI: [String], more: [String], notMore: [String])] = [
            ("note", "Packing list & plan", ["Enhance with AI…", "Rewrite Selection…", "Split into Bowl…", "Ask About This Bowl"], ["Suggest To-dos"],
             ["Pin", "Convert to To-do", "Save as Template…", "Delete"], ["Later"]),
            ("todo", "Choose worktop colour", ["Enhance with AI…", "Rewrite Selection…", "Split into Bowl…"], ["Suggest To-dos", "Summarize…"],
             ["Pin", "Mark as Done", "Convert to Note", "Save as Template…", "Delete"], []),
            ("meeting", "Design Review", ["Suggest To-dos", "Split into Bowl…", "Ask About This Bowl"], ["Enhance with AI…"],
             ["Pin", "Continue Recording", "Transcribe Again", "Merge with…", "Copy Transcript", "Delete Recording…", "Save as Template…", "Delete"], ["Convert to To-do"]),
            ("link", "The Case for Slow Software", ["Ask About This Bowl"], ["Suggest To-dos", "Enhance with AI…"],
             ["Pin", "Open in Browser", "Copy Link", "Load Page Again", "Delete"], ["Convert to To-do", "Save as Template…"]),
            ("image", "Whiteboard", ["Ask About This Bowl"], ["Suggest To-dos"], ["Pin", "Delete"], ["Save as Template…"]),
            ("pdf", "Invoice INV-2026-1142", [], ["Suggest To-dos", "Ask About This Bowl"],
             ["Pin", "Mark as Paid", "Edit Pages…", "Later", "Delete"], ["Save as Template…"]),
        ]
        let shots = URL(fileURLWithPath: "/tmp/porridge-s3-shots")
        func shoot(_ name: String) {
            guard FileManager.default.fileExists(atPath: shots.path) else { return }
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appendingPathComponent("ios-\(name).png"))
        }
        func dismissMenu() {
            // The left margin of the page: nothing there reacts to a tap.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.6)).tap()
        }
        var searched = false
        for kind in kinds {
            if searched { app.searchAgain(for: kind.title) } else { app.search(for: kind.title) }
            searched = true
            let row = try XCTUnwrap(app.searchResult(kind.title), "seeded \(kind.name) missing")
            row.tap()
            let ai = app.buttons["entry.ai"]
            XCTAssertTrue(ai.waitForExistence(timeout: 10), "\(kind.name): ✦ AI pill missing")
            XCTAssertTrue(app.buttons["entry.share"].exists, "\(kind.name): Share pill missing")
            shoot("\(kind.name)-bar")
            ai.tap()
            for title in kind.ai {
                XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "\(kind.name): AI lacks \(title)")
            }
            for title in kind.notAI { XCTAssertFalse(app.buttons[title].exists, "\(kind.name): AI has \(title)") }
            shoot("\(kind.name)-ai")
            dismissMenu()
            let more = app.buttons["entry.more"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
            for title in kind.more {
                XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), "\(kind.name): More lacks \(title)")
            }
            for title in kind.notMore { XCTAssertFalse(app.buttons[title].exists, "\(kind.name): More has \(title)") }
            shoot("\(kind.name)-more")
            dismissMenu()
            let back = app.buttons["Back"].firstMatch
            if !back.waitForHittable(timeout: 5) { shoot("\(kind.name)-stuck") }
            back.tap()
        }
    }
}

private extension XCUIElement {
    func waitForHittable(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isHittable { return true }
            usleep(200_000)
        }
        return false
    }
}
