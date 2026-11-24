import XCTest
@testable import Porridge

/// To-dos suggested from the tasks of a summary.
@MainActor
final class TodoSuggestionsTests: XCTestCase {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// Friday, 20 November 2026, 10:00 in Berlin.
    private var meetingDate: Date {
        berlin.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 10))!
    }

    private let summary = """
    ## Zusammenfassung
    Wir haben den Launch geplant.

    ## Entscheidungen
    - [ ] Not a task here? It is a checkbox, so it counts.

    ## Aufgaben
    - [ ] Angebot an den Kunden schicken – Daniel – 2026-11-27
    - [ ] Raum buchen – Anna – 28.11.
    - [x] Protokoll verschicken – Ben
    - [ ] **Roadmap** aktualisieren – – nicht genannt
    - [ ] Angebot an den Kunden schicken – Daniel
    - [ ] Budget prüfen – Anna und Daniel – nächste Woche
    """

    private func suggestions(names: [String] = ["daniel"]) -> [TaskSuggestion] {
        TodoSuggestions.parse(summary, meetingDate: meetingDate, calendar: berlin, myNames: names)
    }

    func testOpenTasksBecomeSuggestionsOnceEach() {
        let all = suggestions()
        XCTAssertEqual(all.map(\.title), [
            "Not a task here? It is a checkbox, so it counts.", "Angebot an den Kunden schicken", "Raum buchen",
            "Roadmap aktualisieren", "Budget prüfen",
        ])
    }

    func testOwnerAndDueDayAreReadNothingIsGuessed() {
        let all = Dictionary(uniqueKeysWithValues: suggestions().map { ($0.title, $0) })
        XCTAssertEqual(all["Angebot an den Kunden schicken"]?.owner, "Daniel")
        XCTAssertEqual(all["Angebot an den Kunden schicken"]?.dueDay, "2026-11-27")
        XCTAssertEqual(all["Raum buchen"]?.owner, "Anna")
        XCTAssertEqual(all["Raum buchen"]?.dueDay, "2026-11-28")
        // Placeholders are no owner; "next week" is no date.
        XCTAssertNil(all["Roadmap aktualisieren"]?.owner)
        XCTAssertNil(all["Roadmap aktualisieren"]?.dueDay)
        XCTAssertEqual(all["Budget prüfen"]?.owner, "Anna und Daniel")
        XCTAssertNil(all["Budget prüfen"]?.dueDay)
    }

    func testMineIsTheUsersAndNobodys() {
        let all = Dictionary(uniqueKeysWithValues: suggestions().map { ($0.title, $0.isMine) })
        XCTAssertEqual(all["Angebot an den Kunden schicken"], true)
        XCTAssertEqual(all["Raum buchen"], false)
        XCTAssertEqual(all["Roadmap aktualisieren"], true)
        XCTAssertEqual(all["Budget prüfen"], true)
        XCTAssertEqual(suggestions(names: []).filter(\.isMine).map(\.title), ["Not a task here? It is a checkbox, so it counts.", "Roadmap aktualisieren"])
    }

    func testDueDaysInTheirWritings() {
        func due(_ text: String) -> String? { TodoSuggestions.dueDay(from: text, meetingDate: meetingDate, calendar: berlin) }
        XCTAssertEqual(due("2026-12-01"), "2026-12-01")
        XCTAssertEqual(due("1.12.2026"), "2026-12-01")
        XCTAssertEqual(due("01.12.26"), "2026-12-01")
        XCTAssertEqual(due("28 November"), "2026-11-28")
        XCTAssertEqual(due("28. Nov."), "2026-11-28")
        XCTAssertEqual(due("November 28, 2026"), "2026-11-28")
        XCTAssertEqual(due("Friday, 4 December 2026"), "2026-12-04")
        XCTAssertEqual(due("le 3 décembre"), "2026-12-03")
        // A day without a year before the meeting is next year's.
        XCTAssertEqual(due("15.1."), "2027-01-15")
        XCTAssertEqual(due("10 November"), "2027-11-10")
        // Words and impossible days are no date.
        XCTAssertNil(due("next Friday"))
        XCTAssertNil(due("Ende des Monats"))
        XCTAssertNil(due("in 2 weeks"))
        XCTAssertNil(due("31.2.2026"))
        XCTAssertNil(due("Anna"))
    }

    func testTheSameTaskAcrossSummaries() {
        XCTAssertEqual(TodoSuggestions.key("Send the offer!"), "send the offer")
        XCTAssertEqual(TodoSuggestions.key("Prüfe Ölstand"), "prufe olstand")
        XCTAssertTrue(TodoSuggestions.isSame("send the offer to the customer", "send the offer to customer"))
        XCTAssertFalse(TodoSuggestions.isSame("send the offer", "send the invoice"))
        XCTAssertFalse(TodoSuggestions.isSame("call", "call anna"))
    }

    func testTakenAndDismissedStayHandledAfterANewSummary() {
        let states = [
            TodoSuggestions.key("Angebot an den Kunden schicken"): TodoSuggestions.taken,
            TodoSuggestions.key("Raum buchen"): TodoSuggestions.dismissed,
        ]
        let rewritten = """
        ## Aufgaben
        - [ ] Angebot an die Kunden schicken – Daniel
        - [ ] Raum buchen – Anna
        - [ ] Neue Aufgabe
        """
        let pending = TodoSuggestions.pending(
            TodoSuggestions.parse(rewritten, meetingDate: meetingDate, calendar: berlin, myNames: []),
            states: states, madeTitles: [])
        XCTAssertEqual(pending.map(\.title), ["Neue Aufgabe"])
        // A to-do made some other way counts as taken too.
        let other = TodoSuggestions.pending(
            TodoSuggestions.parse("- [ ] Neue Aufgabe", meetingDate: meetingDate, calendar: berlin, myNames: []),
            states: [:], madeTitles: ["Neue Aufgabe"])
        XCTAssertTrue(other.isEmpty)
    }

    func testStatesAreStoredAsSortedJSON() {
        XCTAssertEqual(TodoSuggestions.encode(["b": "dismissed", "a": "taken"]), #"{"a":"taken","b":"dismissed"}"#)
        XCTAssertEqual(TodoSuggestions.states(#"{"a":"taken"}"#), ["a": "taken"])
        XCTAssertEqual(TodoSuggestions.states(nil), [:])
        XCTAssertEqual(TodoSuggestions.states("not json"), [:])
    }

    func testTakingMakesTodosInTheBucketAndDismissesTheRest() throws {
        let context = try TestStore.context()
        let meeting = Note()
        meeting.title = "Launch"
        meeting.projectIDs = ["B1"]
        meeting.summary = summary
        meeting.createdAt = meetingDate
        TodoSuggestions.offer(meeting)
        context.insert(meeting)
        let all = meeting.pendingTodoSuggestions(made: [])
        XCTAssertEqual(all.count, 5)
        let chosen = all.filter { $0.title.hasPrefix("Angebot") || $0.title.hasPrefix("Raum") }
        let rest = all.filter { !chosen.contains($0) }
        let made = TodoSuggestions.take(chosen, dismissing: rest, from: meeting, asOne: false, in: context)
        XCTAssertEqual(made.map(\.title), ["Angebot an den Kunden schicken", "Raum buchen"])
        XCTAssertTrue(made.allSatisfy { $0.isTodo && $0.projectIDs == ["B1"] && $0.todoSourceID == meeting.id.uuidString })
        XCTAssertEqual(made.map(\.todoDueDay), ["2026-11-27", "2026-11-28"])
        // Somebody else's task names its owner in the to-do.
        XCTAssertEqual(made[1].text, "Owner: Anna")
        XCTAssertTrue(meeting.pendingTodoSuggestions(made: made).isEmpty)

        // "Suggest To-dos" brings the dismissed ones back, not the taken ones.
        TodoSuggestions.suggestAgain(meeting, in: context)
        XCTAssertEqual(meeting.pendingTodoSuggestions(made: made).count, 3)
    }

    func testTakingAsOneTodoWithSubtasks() throws {
        let context = try TestStore.context()
        let meeting = Note()
        meeting.title = "Launch"
        meeting.summary = summary
        meeting.createdAt = meetingDate
        TodoSuggestions.offer(meeting)
        context.insert(meeting)
        let all = meeting.pendingTodoSuggestions(made: [])
        let made = TodoSuggestions.take(Array(all.prefix(3)), dismissing: [], from: meeting, asOne: true, in: context)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].title, "Follow-ups: Launch")
        XCTAssertEqual(made[0].todoProgress.total, 3)
        XCTAssertEqual(made[0].todoDueDay, "2026-11-27")
        XCTAssertTrue(made[0].text.contains("- [ ] Raum buchen (Anna)"))
    }

    func testNothingIsOfferedWithoutASummaryOrFromSavedPages() throws {
        let note = Note()
        XCTAssertFalse(note.offersTodoSuggestions)
        note.summary = summary
        XCTAssertFalse(note.offersTodoSuggestions, "suggestions only after a summary was written or asked for")
        TodoSuggestions.offer(note)
        XCTAssertTrue(note.offersTodoSuggestions)
        let link = Note()
        link.url = "https://example.com"
        link.summary = summary
        TodoSuggestions.offer(link)
        XCTAssertFalse(link.offersTodoSuggestions)
        XCTAssertTrue(link.pendingTodoSuggestions(made: []).isEmpty)
    }

    /// What the Apple model wrote for a German meeting on 20 November: the meeting's own date copied into every
    /// task, or the deadline only in the task's words.
    func testMeetingDayCopiedIntoTasksIsDroppedAndTheTasksOwnWordsCount() {
        func split(_ text: String) -> (String, String?, String?) {
            let p = TodoSuggestions.split(text, meetingDate: meetingDate, calendar: berlin)
            return (p.title, p.owner, p.dueDay)
        }
        XCTAssertNil(split("Aktualisiere die Roadmap bis Ende des Monats – Ben – 2026-11-20").2)
        XCTAssertEqual(split("Kläre bis zum 3. Dezember das Budget – Daniel – 2026-11-20").2, "2026-12-03")
        XCTAssertEqual(split("Kläre das Budget – Daniel – bis zum 3. Dezember").2, "2026-12-03")
        XCTAssertNil(split("Aktualisiere die Roadmap – Ben – Ende des Monats").2)
        XCTAssertEqual(split("Ben aktualisiere die Roadmap – Ben – Ende des Monats").1, "Ben")
        // Due today, said so: the meeting's day stays.
        XCTAssertEqual(split("Angebot heute an den Kunden schicken – Daniel – 2026-11-20").2, "2026-11-20")
    }

    // MARK: Each task once on the page

    private func meeting(_ summary: String, offered: Bool = true) -> Note {
        let note = Note()
        note.title = "Launch"
        note.summary = summary
        note.createdAt = meetingDate
        if offered { TodoSuggestions.offer(note) }
        return note
    }

    /// The lines that are left on the page, empty ones dropped.
    private func visible(_ text: String?) -> [String] {
        (text ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private let english = """
    ## Summary
    We planned the launch.

    ## Key Points
    - The date holds

    ## Decisions
    - Variant B

    ## Action Items
    - [ ] Send the offer to the customer – Daniel – 2026-11-27
    - [ ] Book the room – Anna

    #launch #q4
    """

    func testOfferedTasksLeaveTheSummaryWithTheirHeading() {
        let note = meeting(english)
        let offered = note.pendingTodoSuggestions(made: [])
        XCTAssertEqual(offered.count, 2)
        let shown = note.summaryShown(offered: offered, made: [])
        XCTAssertEqual(visible(shown), ["## Summary", "We planned the launch.", "## Key Points", "- The date holds", "## Decisions", "- Variant B", "#launch #q4"])
        // Line numbers stay, so a box still finds its line in the stored summary; the stored summary is untouched.
        XCTAssertEqual(shown?.components(separatedBy: "\n").count, english.components(separatedBy: "\n").count)
        XCTAssertEqual(note.summary, english)
    }

    func testWithoutTheCardTheTasksStayInTheSummary() {
        // A locked or read-only page shows no card: then the summary is the only place for the tasks.
        let note = meeting(english)
        XCTAssertEqual(note.summaryShown(offered: [], made: []), english)
        // Summarized before suggestions existed (nothing offered, nothing made): as it was.
        XCTAssertEqual(meeting(english, offered: false).summaryShown(offered: [], made: []), english)
    }

    func testTakenTasksAreShownAsTodosAndTheDismissedOnesStay() throws {
        let context = try TestStore.context()
        let note = meeting(summary)
        context.insert(note)
        let all = note.pendingTodoSuggestions(made: [])
        let chosen = all.filter { $0.title.hasPrefix("Angebot") || $0.title.hasPrefix("Raum") }
        let made = TodoSuggestions.take(chosen, dismissing: all.filter { !chosen.contains($0) }, from: note, asOne: false, in: context)
        let shown = visible(note.summaryShown(offered: note.pendingTodoSuggestions(made: made), made: made))
        XCTAssertFalse(shown.contains { $0.contains("Angebot") || $0.contains("Raum buchen") })
        // Dismissed tasks are shown nowhere else, so they stay, and with them the heading; so does the ticked one.
        XCTAssertTrue(shown.contains("## Aufgaben"))
        XCTAssertTrue(shown.contains("- [ ] Budget prüfen – Anna und Daniel – nächste Woche"))
        XCTAssertTrue(shown.contains("- [x] Protokoll verschicken – Ben"))
    }

    func testTasksOfTheOneTodoWithSubtasksLeaveTheSummary() throws {
        let context = try TestStore.context()
        let note = meeting(english)
        context.insert(note)
        let made = TodoSuggestions.take(note.pendingTodoSuggestions(made: []), dismissing: [], from: note, asOne: true, in: context)
        XCTAssertEqual(made.count, 1)
        XCTAssertFalse(visible(note.summaryShown(offered: [], made: made)).contains { $0.contains("Action Items") || $0.hasPrefix("- [") })
    }

    func testATaskTakenUnderAnEditedTitleCountsAsShown() throws {
        let context = try TestStore.context()
        let note = meeting(english)
        context.insert(note)
        var offer = note.pendingTodoSuggestions(made: [])
        offer[1].title = "Reserve a meeting space for Friday"
        let made = TodoSuggestions.take(offer, dismissing: [], from: note, asOne: false, in: context)
        XCTAssertFalse(visible(note.summaryShown(offered: [], made: made)).contains { $0.contains("Book the room") })
        // The to-dos deleted: the summary is where the tasks are again.
        XCTAssertEqual(note.summaryShown(offered: [], made: []), english)
    }

    func testHeadingVariants() {
        let variants = [
            "## Action Items", "### Aufgaben", "## Nächste Schritte", "## Next Steps", "## To-dos", "## Tasks",
            "# Offene Punkte", "**Action Items:**", "**Aufgaben**", "Next steps:", "__To-dos:__",
        ]
        for heading in variants {
            let text = "## Zusammenfassung\nKurz.\n\n\(heading)\n- [ ] Angebot schicken – Daniel\n- Raum buchen – Anna\n- Keine weiteren Aufgaben.\n\n#tag"
            let note = meeting(text)
            let offered = note.pendingTodoSuggestions(made: [])
            // Under a paragraph heading only the checkbox is a task; the plain bullet is text and stays.
            let rest = heading.hasPrefix("#") ? [] : ["- Raum buchen – Anna", "- Keine weiteren Aufgaben."]
            XCTAssertEqual(offered.count, heading.hasPrefix("#") ? 2 : 1, heading)
            XCTAssertEqual(visible(note.summaryShown(offered: offered, made: [])), ["## Zusammenfassung", "Kurz."] + (rest.isEmpty ? [] : [heading]) + rest + ["#tag"], heading)
        }
        // A paragraph heading over checkboxes only goes with them.
        let checkboxes = "**Next Steps:**\n- [ ] Send the offer – Daniel\n- [ ] Book the room – Anna"
        let note = meeting(checkboxes)
        XCTAssertEqual(visible(note.summaryShown(offered: note.pendingTodoSuggestions(made: []), made: [])), [])
    }

    func testOtherTextUnderTheTasksHeadingKeepsIt() {
        let text = "## Action Items\nEveryone agreed on these.\n- [ ] Send the offer – Daniel"
        let note = meeting(text)
        XCTAssertEqual(visible(note.summaryShown(offered: note.pendingTodoSuggestions(made: []), made: [])), ["## Action Items", "Everyone agreed on these."])
    }

    func testSummariesWithoutTasksAndOtherKindsAreUnchanged() {
        let plain = "## Summary\nNothing to do.\n\n## Action Items\n- No action items.\n\n## Decisions\n- None"
        let note = meeting(plain)
        XCTAssertEqual(note.summaryShown(offered: note.pendingTodoSuggestions(made: []), made: []), plain)
        // A saved page and a to-do show their summary as written.
        let link = meeting(english)
        link.url = "https://example.com"
        XCTAssertEqual(link.summaryShown(offered: TodoSuggestions.parse(english, meetingDate: meetingDate), made: []), english)
        let todo = meeting(english)
        todo.todoState = .open
        XCTAssertEqual(todo.summaryShown(offered: TodoSuggestions.parse(english, meetingDate: meetingDate), made: []), english)
        XCTAssertNil(Note().summaryShown(offered: [], made: []))
    }
}
