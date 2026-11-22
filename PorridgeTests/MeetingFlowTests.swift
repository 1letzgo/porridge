import XCTest
@testable import Porridge

@MainActor
final class MeetingFlowTests: XCTestCase {
    private func appointment(
        id: String = "e1", title: String = "Weekly", start: Date = Date(timeIntervalSince1970: 1_800_000_000),
        minutes: Double = 30, allDay: Bool = false, calendar: String = "work", attendees: [String] = ["Anna"],
        video: URL? = nil, declined: Bool = false
    ) -> CalendarAppointment {
        CalendarAppointment(
            id: id, title: title, start: start, end: start.addingTimeInterval(minutes * 60), isAllDay: allDay,
            calendarName: "Work", calendarID: calendar, attendees: attendees, videoURL: video, isDeclined: declined
        )
    }

    private func defaults() -> UserDefaults {
        let name = "MeetingFlowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Which appointments alert

    func testOnlyMeetingsWithPeopleOrAVideoCallAlert() {
        let zoom = URL(string: "https://zoom.us/j/1")!
        XCTAssertTrue(MeetingAlerts.qualifies(appointment()))
        XCTAssertTrue(MeetingAlerts.qualifies(appointment(attendees: [], video: zoom)))
        XCTAssertFalse(MeetingAlerts.qualifies(appointment(attendees: [])), "alone, no call: a block of time")
        XCTAssertFalse(MeetingAlerts.qualifies(appointment(allDay: true)))
        XCTAssertFalse(MeetingAlerts.qualifies(appointment(declined: true)))
        XCTAssertFalse(MeetingAlerts.qualifies(appointment(calendar: "home"), excluded: ["home"]))
    }

    func testUpcomingIsSortedAndDropsWhatIsLongPast() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = appointment(id: "later", start: now.addingTimeInterval(3600))
        let soon = appointment(id: "soon", start: now.addingTimeInterval(300))
        let begun = appointment(id: "begun", start: now.addingTimeInterval(-60))
        let past = appointment(id: "past", start: now.addingTimeInterval(-600))
        let result = MeetingAlerts.upcoming([later, past, soon, begun], excluded: [], now: now)
        XCTAssertEqual(result.map(\.id), ["begun", "soon", "later"])
    }

    func testAlertIsDueAMinuteBeforeAndShortlyAfterTheStart() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(MeetingAlerts.isAlertDue(start: start, now: start.addingTimeInterval(-61)))
        XCTAssertTrue(MeetingAlerts.isAlertDue(start: start, now: start.addingTimeInterval(-60)))
        XCTAssertTrue(MeetingAlerts.isAlertDue(start: start, now: start.addingTimeInterval(90)))
        XCTAssertFalse(MeetingAlerts.isAlertDue(start: start, now: start.addingTimeInterval(120)))
    }

    func testAMovedAppointmentAlertsAgain() {
        let first = appointment()
        let moved = appointment(start: first.start.addingTimeInterval(1800))
        XCTAssertNotEqual(MeetingAlerts.alertKey(first), MeetingAlerts.alertKey(moved))
    }

    func testCountdownShowsWithinHalfAnHour() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(MeetingAlerts.countdownText(until: start, now: start.addingTimeInterval(-31 * 60)))
        XCTAssertEqual(MeetingAlerts.countdownText(until: start, now: start.addingTimeInterval(-12 * 60)), "12m")
        XCTAssertEqual(MeetingAlerts.countdownText(until: start, now: start.addingTimeInterval(-90)), "2m")
        XCTAssertEqual(MeetingAlerts.countdownText(until: start, now: start.addingTimeInterval(-5)), "1m")
        XCTAssertNil(MeetingAlerts.countdownText(until: start, now: start))
    }

    func testTheSwitchIsSettledOnceFromTheCalendarAccess() {
        let granted = defaults()
        MeetingAlerts.settleDefault(granted: true, granted)
        XCTAssertTrue(granted.bool(forKey: MeetingAlerts.enabledKey))
        // Turned off later: an update does not turn it on again.
        granted.set(false, forKey: MeetingAlerts.enabledKey)
        MeetingAlerts.settleDefault(granted: true, granted)
        XCTAssertFalse(granted.bool(forKey: MeetingAlerts.enabledKey))

        let shut = defaults()
        MeetingAlerts.settleDefault(granted: false, shut)
        XCTAssertNotNil(shut.object(forKey: MeetingAlerts.enabledKey))
        XCTAssertFalse(shut.bool(forKey: MeetingAlerts.enabledKey))
    }

    // MARK: Reading an appointment

    func testVideoLinksAreFoundInPlaceAndNotes() {
        XCTAssertEqual(MeetingAlerts.videoLink(in: [nil, "https://company.zoom.us/j/123?pwd=x", nil])?.host, "company.zoom.us")
        XCTAssertEqual(
            MeetingAlerts.videoLink(in: [nil, "Room 4", "Agenda: https://example.com/doc\nJoin: <https://meet.google.com/abc-defg-hij>."])?.absoluteString,
            "https://meet.google.com/abc-defg-hij"
        )
        XCTAssertNotNil(MeetingAlerts.videoLink(in: ["https://teams.microsoft.com/l/meetup-join/19%3a"]))
        XCTAssertNil(MeetingAlerts.videoLink(in: ["https://example.com/zoom.us", "Meeting room 3"]))
        XCTAssertNil(MeetingAlerts.videoLink(in: ["https://notzoom.us/j/1"]))
    }

    func testAttendeeNamesComeFromTheNameOrTheAddress() {
        XCTAssertEqual(MeetingAlerts.attendeeName(name: "Anna Schmidt", address: "mailto:anna@x.de"), "Anna Schmidt")
        XCTAssertEqual(MeetingAlerts.attendeeName(name: nil, address: "mailto:anna.schmidt@firma.de"), "Anna Schmidt")
        XCTAssertEqual(MeetingAlerts.attendeeName(name: "tom_meier@firma.de", address: nil), "Tom Meier")
        XCTAssertNil(MeetingAlerts.attendeeName(name: nil, address: nil))
        XCTAssertEqual(MeetingAlerts.unique(["Anna", "anna", "Tom"]), ["Anna", "Tom"])
    }

    func testPeopleLineShortensLongLists() {
        XCTAssertNil(MeetingAlerts.peopleLine([]))
        XCTAssertEqual(MeetingAlerts.peopleLine(["Anna", "Tom"]), "Anna, Tom")
        XCTAssertEqual(MeetingAlerts.peopleLine(["Anna", "Tom", "Lisa", "Ben"]), "Anna, Tom and 2 more")
    }

    // MARK: Meetings and their appointment

    func testAMeetingFindsItsAppointmentByTitleAndTime() {
        let began = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = began.addingTimeInterval(1800)
        let right = appointment(id: "right", title: "Weekly", start: began.addingTimeInterval(-120))
        let otherDay = appointment(id: "other", title: "Weekly", start: began.addingTimeInterval(-86400))
        let otherTitle = appointment(id: "title", title: "Lunch", start: began)
        XCTAssertEqual(MeetingLinks.match(title: "weekly ", began: began, ended: ended, in: [otherDay, otherTitle, right])?.id, "right")
        XCTAssertNil(MeetingLinks.match(title: "Weekly", began: began, ended: ended, in: [otherDay, otherTitle]))
    }

    func testRememberedAppointmentsSurviveAndOldOnesAreDropped() throws {
        let defaults = defaults()
        let note = UUID()
        let recent = appointment(start: Date())
        MeetingLinks.remember(recent, for: note, defaults)
        XCTAssertEqual(MeetingLinks.stored(defaults)[note.uuidString]?.attendees, ["Anna"])
        let old = appointment(id: "old", start: Date().addingTimeInterval(-MeetingLinks.keepFor - 86400))
        MeetingLinks.remember(old, for: UUID(), defaults)
        MeetingLinks.remember(recent, for: UUID(), defaults)
        XCTAssertEqual(MeetingLinks.stored(defaults).count, 2)
    }

    // MARK: Naming speakers

    func testSpeakerChoicesAreTheInvitedNotYetGiven() {
        let speakers = [
            Speaker(id: "s1", name: "Speaker 1", colorIndex: 0),
            Speaker(id: "s2", name: "Tom", colorIndex: 1),
        ]
        XCTAssertEqual(
            SpeakerNaming.choices(attendees: ["Anna", "Tom", "Lisa"], myName: "Daniel", speakers: speakers, for: "s1"),
            ["Anna", "Lisa", "Daniel"]
        )
        // The speaker's own name is no choice; the other speaker's is taken.
        XCTAssertEqual(SpeakerNaming.choices(attendees: ["Anna", "Tom"], myName: nil, speakers: speakers, for: "s2"), ["Anna"])
        XCTAssertEqual(SpeakerNaming.choices(attendees: [], myName: "Daniel", speakers: speakers, for: "s1"), [], "no appointment, no menu")
    }

    // MARK: Summary after renames

    func testNamesAreReplacedAsWholeNames() {
        let text = "Speaker 1 sends the deck.\n- [ ] Send the deck – Speaker 1\n- [ ] Book a room – Speaker 10"
        XCTAssertEqual(
            SummaryRefresh.replacingName("Speaker 1", with: "Anna", in: text),
            "Anna sends the deck.\n- [ ] Send the deck – Anna\n- [ ] Book a room – Speaker 10"
        )
        XCTAssertEqual(SummaryRefresh.replacingName("Ann", with: "Anna", in: "Anna and Ann"), "Anna and Anna")
        XCTAssertEqual(SummaryRefresh.replacingName("Tom", with: "$1 \\o/", in: "Tom"), "$1 \\o/")
    }

    func testASummaryIsWrittenAgainOnlyWhenNothingOfTheUserIsLost() {
        let summary = "## Summary\nText\n\n## Action Items\n- [ ] Send – Speaker 1"
        let written = SummaryRefresh.hash(summary)
        XCTAssertTrue(SummaryRefresh.shouldRefresh(summary: summary, writtenHash: written, autoEnabled: true, hasModel: true))
        XCTAssertTrue(SummaryRefresh.shouldRefresh(summary: summary, writtenHash: nil, autoEnabled: true, hasModel: true), "written on another device")
        XCTAssertFalse(SummaryRefresh.shouldRefresh(summary: summary + " edited", writtenHash: written, autoEnabled: true, hasModel: true))
        XCTAssertFalse(SummaryRefresh.shouldRefresh(summary: summary.replacingOccurrences(of: "[ ]", with: "[x]"), writtenHash: nil, autoEnabled: true, hasModel: true))
        XCTAssertFalse(SummaryRefresh.shouldRefresh(summary: summary, writtenHash: written, autoEnabled: false, hasModel: true))
        XCTAssertFalse(SummaryRefresh.shouldRefresh(summary: summary, writtenHash: written, autoEnabled: true, hasModel: false))
        XCTAssertFalse(SummaryRefresh.shouldRefresh(summary: nil, writtenHash: nil, autoEnabled: true, hasModel: true), "never a summary nobody asked for")
    }

    func testTheHashIsStable() {
        XCTAssertEqual(SummaryRefresh.hash("Anna"), SummaryRefresh.hash("Anna"))
        XCTAssertNotEqual(SummaryRefresh.hash("Anna"), SummaryRefresh.hash("Anne"))
        XCTAssertEqual(SummaryRefresh.hash(""), "cbf29ce484222325")
    }

    func testTheModelOfTheLastSummaryIsKeptWhenItCanRun() {
        let mini = SummaryModel.cloud(.openRouter, "mini")
        let big = SummaryModel.cloud(.openRouter, "big")
        XCTAssertEqual(SummaryRefresh.model(lastLabel: big.label, available: [mini, big], isUsable: { _ in true }, fallback: mini), big)
        XCTAssertEqual(SummaryRefresh.model(lastLabel: big.label, available: [mini, big], isUsable: { $0 != big }, fallback: mini), mini)
        XCTAssertEqual(SummaryRefresh.model(lastLabel: "gone", available: [mini], isUsable: { _ in true }, fallback: mini), mini)
        XCTAssertNil(SummaryRefresh.model(lastLabel: nil, available: [mini], isUsable: { _ in true }, fallback: nil))
    }

    func testTemplateAndWrittenSummaryAreRememberedPerMeeting() {
        let defaults = defaults()
        let id = UUID()
        XCTAssertNil(SummaryRefresh.templateID(id, defaults))
        SummaryRefresh.rememberTemplate("team", for: id, defaults)
        XCTAssertEqual(SummaryRefresh.templateID(id, defaults), "team")
        SummaryRefresh.recordWritten(id, summary: "Text", defaults)
        XCTAssertEqual(SummaryRefresh.writtenHash(id, defaults), SummaryRefresh.hash("Text"))
        SummaryRefresh.recordWritten(id, summary: nil, defaults)
        XCTAssertNil(SummaryRefresh.writtenHash(id, defaults))
    }

    // MARK: The meeting template

    func testDefaultMeetingSummaryHasDecisionsAndOwnedActionItems() {
        let prompt = SummaryService.systemPrompt(SummaryLanguage(code: "en"), template: .general)
        XCTAssertTrue(prompt.contains("## Decisions"))
        XCTAssertTrue(prompt.contains("keep this heading"))
        XCTAssertTrue(prompt.contains("## Action Items"))
        XCTAssertTrue(prompt.contains("– <owner> –"))
        XCTAssertTrue(prompt.contains("The owner is the person who takes the task on"))
    }

    func testMeetingTemplatesAskForDecisionsAndCustomOnesStayAsGiven() throws {
        for id in ["team", "customer"] {
            let template = try XCTUnwrap(SummaryTemplate.builtIn.first { $0.id == id })
            XCTAssertTrue(template.sections?.contains("Decisions") == true, id)
        }
        let custom = SummaryTemplate(id: "c", name: "Prices", focus: "Note every price.", sections: ["Prices"])
        let prompt = SummaryService.systemPrompt(SummaryLanguage(code: "en"), template: custom)
        XCTAssertTrue(prompt.contains("## <\"Prices\" in English>"))
        XCTAssertFalse(prompt.contains("## Decisions"))
        // Every template ends with action items that have an owner.
        XCTAssertTrue(prompt.contains("– <owner> –"))
    }
}
