import XCTest
@testable import Porridge

/// The chat's data: one entry per note with its metadata (`ChatDocument`), questions read as filters (`ChatQuery`),
/// and the context a question gets (`ChatRetrieval.context`). A fixed set of entries of every kind; every question
/// checks which entries land in the context.
@MainActor
final class ChatDataTests: XCTestCase {
    // Friday, 20 November 2026, noon in Berlin; weeks start on Monday (16 – 22 November).
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.firstWeekday = 2
        return calendar
    }()
    private var now: Date { day(20, hour: 12) }

    private func day(_ day: Int, month: Int = 11, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private let travel = "B-TRAVEL", house = "B-HOUSE", work = "B-WORK"
    private var bucketNames: [String: String] { [travel: "Reisen", house: "Haus und Garten", work: "Arbeit"] }

    private struct Fixture {
        var notes: [String: Note] = [:]
        var all: [Note] { Array(notes.values) }
        subscript(_ title: String) -> UUID { notes[title]!.id }
    }

    private func makeFixture() -> Fixture {
        var fixture = Fixture()
        func add(_ title: String, text: String = "", created: Date, buckets: [String] = [], configure: (Note) -> Void = { _ in }) {
            let note = Note()
            note.title = title
            note.text = text
            note.createdAt = created
            note.projectIDs = buckets
            configure(note)
            fixture.notes[title] = note
        }
        add("Packliste Norwegen", text: "Regenjacke, Wanderschuhe und Fleece einpacken.", created: day(10), buckets: [travel])
        add("Kickoff Website", created: day(17), buckets: [work]) { note in
            note.audioFileName = "kickoff.m4a"
            note.speakers = [Speaker(id: "A", name: "Anna", colorIndex: 0), Speaker(id: "B", name: "Ben", colorIndex: 1)]
            note.segments = [
                TranscriptSegment(speakerId: "A", start: 0, end: 5, text: "Wir haben beschlossen, das Budget auf 20.000 Euro festzulegen."),
                TranscriptSegment(speakerId: "B", start: 5, end: 9, text: "Der Launch ist im Februar."),
            ]
            note.summary = "Beschlüsse: Budget 20.000 Euro. Launch im Februar."
        }
        add("Weekly", created: day(10), buckets: [work]) { note in
            note.audioFileName = "weekly.m4a"
            note.segments = [TranscriptSegment(start: 0, end: 5, text: "Die Entscheidung über das Logo verschieben wir.")]
        }
        add("Swift Concurrency Guide", created: day(18)) { note in
            note.url = "https://www.swift.org/documentation/concurrency"
            note.pageText = "Swift concurrency uses async and await. Actors protect mutable state."
        }
        add("Sauerteig Rezept", created: day(5), buckets: [house]) { note in
            note.url = "https://example.com/sauerteig"
            note.pageText = "Sauerteig braucht Roggenmehl, Wasser und viel Zeit."
        }
        add("Kotlin Coroutines", created: day(1), buckets: [work]) { note in
            note.url = "https://kotlinlang.org/docs/coroutines-overview.html"
            note.pageText = "Coroutines make asynchronous programming in Kotlin simple."
        }
        add("Angebot an Müller schicken", created: day(1), buckets: [work]) { note in
            note.todoState = .open
            note.todoDueDay = "2026-11-19"
        }
        add("Hecke schneiden", text: "- [x] Schere schärfen\n- [ ] Grünschnitt wegbringen", created: day(12), buckets: [house]) { note in
            note.todoState = .open
            note.todoDueDay = "2026-11-22"
        }
        add("Steuererklärung", created: day(2), buckets: []) { note in
            note.todoState = .open
            note.todoDueDay = "2026-12-10"
        }
        add("Fahrrad reparieren", text: "Schlauch hinten tauschen.", created: day(3), buckets: [house]) { note in
            note.todoState = .open
        }
        add("Fährtickets buchen", created: day(4), buckets: [travel]) { note in
            note.todoState = .done
            note.todoDueDay = "2026-11-18"
            note.todoDoneAt = day(18, hour: 9)
        }
        add("Whiteboard", created: day(19), buckets: [work]) { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "w.jpg", name: "IMG_0042.jpg", kindRaw: "image")]
            note.pageText = "Roadmap Q1: Login, Payments, Export"
        }
        add("Mietvertrag", created: day(1, month: 10), buckets: [house]) { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "m.pdf", name: "Mietvertrag.pdf", kindRaw: "pdf")]
            note.pageText = "Die Kaution beträgt 2.400 Euro und wird auf ein Sparbuch gezahlt."
        }
        add("Geheimes Projekt", text: "Codename Falke startet im Frühjahr.", created: day(15)) { note in
            note.deletedAt = self.day(16)
        }
        add("Altes Rezept", text: "Pfannkuchen mit Milch, Mehl und Eiern.", created: day(1, month: 3))
        return fixture
    }

    /// What the index holds for the fixture: the living notes' entries and passages, as `NoteIndex.refresh` builds them.
    private func context(_ question: String, _ fixture: Fixture, within: Set<UUID>? = nil) -> ChatContext {
        let living = fixture.all.filter { !$0.isDeleted && (within?.contains($0.id) ?? true) }
        let documents = Dictionary(uniqueKeysWithValues: living.map { ($0.id, ChatDocument(note: $0)) })
        return ChatRetrieval.context(question, documents: documents, chunks: ChatRetrieval.chunks(from: living), bucketNames: bucketNames, now: now, calendar: calendar)
    }

    private func listed(_ context: ChatContext) -> Set<UUID> { Set(context.items.filter(\.isListing).map(\.noteID)) }
    private func all(_ context: ChatContext) -> Set<UUID> { Set(context.items.map(\.noteID)) }

    // MARK: - The entry

    func testEveryKindBecomesAnEntryWithItsMetadata() {
        let f = makeFixture()
        let kinds = Dictionary(uniqueKeysWithValues: f.all.map { ($0.title, ChatDocument(note: $0).kind) })
        XCTAssertEqual(kinds["Packliste Norwegen"], .note)
        XCTAssertEqual(kinds["Kickoff Website"], .meeting)
        XCTAssertEqual(kinds["Swift Concurrency Guide"], .link)
        XCTAssertEqual(kinds["Hecke schneiden"], .todo)
        XCTAssertEqual(kinds["Whiteboard"], .image)
        XCTAssertEqual(kinds["Mietvertrag"], .file)

        let hedge = ChatDocument(note: f.notes["Hecke schneiden"]!)
        XCTAssertEqual(hedge.header(bucketNames: bucketNames, now: now, calendar: calendar),
                       "«Hecke schneiden» — To-do, open, due 22 November 2026, 1 of 2 subtasks done · created Thu 12 Nov 2026 · Bucket: Haus und Garten")
        let offer = ChatDocument(note: f.notes["Angebot an Müller schicken"]!)
        XCTAssertTrue(offer.header(bucketNames: bucketNames, now: now, calendar: calendar).contains("due 19 November 2026, overdue"))
        let link = ChatDocument(note: f.notes["Swift Concurrency Guide"]!)
        XCTAssertEqual(link.header(bucketNames: bucketNames, now: now, calendar: calendar),
                       "«Swift Concurrency Guide» — Link (swift.org) · created Wed 18 Nov 2026 · Inbox · https://www.swift.org/documentation/concurrency")
        let old = ChatDocument(note: f.notes["Altes Rezept"]!)
        XCTAssertFalse(old.header(bucketNames: bucketNames, now: now, calendar: calendar).contains("archived"), "notes are never archived")
        XCTAssertEqual(ChatDocument(note: f.notes["Kickoff Website"]!).snippet, "Beschlüsse: Budget 20.000 Euro. Launch im Februar.")
        XCTAssertEqual(ChatDocument(note: f.notes["Fahrrad reparieren"]!).snippet, "Schlauch hinten tauschen.")
    }

    func testTheEntryChangesWithBucketsAndState() {
        let note = makeFixture().notes["Packliste Norwegen"]!
        let before = note.indexHash
        note.projectIDs = [house]
        let moved = note.indexHash
        XCTAssertNotEqual(before, moved, "moving it to another bucket cuts it again")
        note.archivedAt = now
        XCTAssertNotEqual(moved, note.indexHash, "a note cleared by Archive.clearArchivedNotes is cut again")
    }

    // MARK: - Reading the question

    func testAQuestionIsReadAsFilters() {
        func parse(_ question: String) -> ChatQuery { ChatQuery.parse(question, buckets: bucketNames, now: now, calendar: calendar) }
        let due = parse("Welche To-dos sind diese Woche fällig?")
        XCTAssertEqual(due.kinds, [.todo])
        XCTAssertEqual(due.todo, .open)
        XCTAssertEqual(due.dateField, .due)
        XCTAssertEqual(due.range, DateInterval(start: day(16, hour: 0), end: day(23, hour: 0)))
        XCTAssertEqual(due.words, [])

        let meeting = parse("Was haben wir im Meeting am Dienstag beschlossen?")
        XCTAssertEqual(meeting.kinds, [.meeting])
        XCTAssertEqual(meeting.range, DateInterval(start: day(17, hour: 0), end: day(18, hour: 0)), "the last Tuesday")
        XCTAssertEqual(meeting.words, ["beschlossen"])

        let bucket = parse("Was liegt im Bucket Haus und Garten?")
        XCTAssertEqual(bucket.bucketIDs, [house])
        XCTAssertEqual(bucket.words, [])

        XCTAssertEqual(parse("Was ist bis Freitag fällig?").range, DateInterval(start: day(20, hour: 0), end: day(21, hour: 0)), "a due day looks ahead")
        XCTAssertEqual(parse("Was steht nächste Woche an?").range, DateInterval(start: day(23, hour: 0), end: day(30, hour: 0)))
        XCTAssertEqual(parse("Notizen vom 17.11.").range, DateInterval(start: day(17, hour: 0), end: day(18, hour: 0)))
        XCTAssertEqual(parse("Links der letzten 3 Tage").range, DateInterval(start: day(17, hour: 0), end: day(21, hour: 0)))
        XCTAssertFalse(parse("Wie hoch ist die Kaution?").isStructured)
        XCTAssertEqual(parse("Wie hoch ist die Kaution?").words, ["hoch", "kaution"])
    }

    // MARK: - Questions and their context

    /// 1. A list question by due day: every to-do due this week, open ones only, nothing else listed.
    func testToDosDueThisWeek() {
        let f = makeFixture()
        let context = context("Welche To-dos sind diese Woche fällig?", f)
        XCTAssertEqual(listed(context), [f["Angebot an Müller schicken"], f["Hecke schneiden"]])
        XCTAssertEqual(context.matched, 2)
        XCTAssertEqual(context.items.first?.noteID, f["Angebot an Müller schicken"], "earliest due first")
    }

    /// 2. Everything in a bucket, whatever its kind.
    func testEverythingInABucket() {
        let f = makeFixture()
        let context = context("Was liegt im Bucket Haus und Garten?", f)
        XCTAssertEqual(listed(context), [f["Sauerteig Rezept"], f["Hecke schneiden"], f["Fahrrad reparieren"], f["Mietvertrag"]])
    }

    /// 3. A meeting by its weekday, with the passage of the decision.
    func testTheDecisionOfTuesdaysMeeting() {
        let f = makeFixture()
        let context = context("Was haben wir im Meeting am Dienstag beschlossen?", f)
        XCTAssertEqual(listed(context), [f["Kickoff Website"]])
        XCTAssertTrue(context.items.contains { !$0.isListing && $0.text.contains("Budget auf 20.000 Euro") })
        XCTAssertFalse(all(context).contains(f["Weekly"]))
    }

    /// 4. Links about a topic: all links are listed, the one about it first, with its page.
    func testLinksAboutATopic() {
        let f = makeFixture()
        let context = context("Welche Links habe ich zum Thema Swift gespeichert?", f)
        XCTAssertEqual(listed(context), [f["Swift Concurrency Guide"], f["Sauerteig Rezept"], f["Kotlin Coroutines"]])
        XCTAssertEqual(context.items.first?.noteID, f["Swift Concurrency Guide"])
        XCTAssertTrue(context.items.first?.text.contains("mentions: swift") ?? false)
        XCTAssertTrue(context.items.contains { !$0.isListing && $0.noteID == f["Swift Concurrency Guide"] && $0.text.contains("Actors") })
    }

    /// 5. Overdue to-dos.
    func testOverdueToDos() {
        let f = makeFixture()
        XCTAssertEqual(listed(context("Welche Aufgaben sind überfällig?", f)), [f["Angebot an Müller schicken"]])
    }

    /// 6. To-dos done in a time, by the day they were done.
    func testToDosDoneThisWeek() {
        let f = makeFixture()
        XCTAssertEqual(listed(context("Welche To-dos habe ich diese Woche erledigt?", f)), [f["Fährtickets buchen"]])
    }

    /// 7. A question by content only reaches the text read out of a file.
    func testTheTextOfAFile() {
        let f = makeFixture()
        let context = context("Wie hoch ist die Kaution?", f)
        XCTAssertNil(context.matched)
        XCTAssertEqual(context.items.first?.noteID, f["Mietvertrag"])
        XCTAssertTrue(context.items.first?.header.contains("File · created") ?? false)
    }

    /// 8. An image by its kind and the text in it.
    func testTheTextInAnImage() {
        let f = makeFixture()
        let context = context("Was steht auf dem Foto zur Roadmap?", f)
        XCTAssertEqual(listed(context), [f["Whiteboard"]])
        XCTAssertTrue(context.items.contains { !$0.isListing && $0.text.contains("Payments") })
    }

    /// 9. A day: what was created then, and the to-dos due then.
    func testWhatWasYesterday() {
        let f = makeFixture()
        XCTAssertEqual(listed(context("Was war gestern?", f)), [f["Whiteboard"], f["Angebot an Müller schicken"]])
    }

    /// 10. Links in the Inbox only.
    func testLinksInTheInbox() {
        let f = makeFixture()
        XCTAssertEqual(listed(context("Welche Links liegen noch in der Inbox?", f)), [f["Swift Concurrency Guide"]])
    }

    /// 11. Meetings of last week, not this one.
    func testMeetingsOfLastWeek() {
        let f = makeFixture()
        XCTAssertEqual(listed(context("Welche Meetings hatten wir letzte Woche?", f)), [f["Weekly"]])
    }

    /// 12. Deleted entries never reach the chat; old ones do, unmarked (notes are never archived).
    func testDeletedNeverReachesTheChat() {
        let f = makeFixture()
        XCTAssertFalse(all(context("Was weißt du über Codename Falke?", f)).contains(f["Geheimes Projekt"]))
        let pancakes = context("Wie mache ich Pfannkuchen?", f)
        XCTAssertEqual(pancakes.items.first?.noteID, f["Altes Rezept"])
        XCTAssertFalse(pancakes.items.first?.header.contains("archived") ?? true)
    }

    /// 13. A chat about one bucket sees only it.
    func testABucketChat() {
        let f = makeFixture()
        let within = Set(f.all.filter { $0.projectIDs.contains(travel) }.map(\.id))
        let context = context("Was muss ich für Norwegen einpacken?", f, within: within)
        XCTAssertEqual(context.items.first?.noteID, f["Packliste Norwegen"])
        XCTAssertTrue(all(context).isSubset(of: within))
    }

    /// 14. Filters that match nothing: the model is told so, and gets the closest passages of all entries, marked outside.
    func testNothingMatchesTheFilters() {
        let f = makeFixture()
        let context = context("Welche Meetings gab es gestern zum Budget?", f)
        XCTAssertEqual(context.matched, 0)
        XCTAssertTrue(context.items.allSatisfy(\.isOutside))
        XCTAssertTrue(all(context).contains(f["Kickoff Website"]))
        let prompt = ChatService.prompt(question: "?", history: [], context: context, bucket: nil, now: now)
        XCTAssertTrue(prompt.user.contains("No entry matches (kind: meeting; created on Thu 19 Nov 2026)."), prompt.user)
        XCTAssertTrue(prompt.user.contains("Excerpts from other entries"))
    }

    // MARK: - The prompt

    func testThePromptListsTheMatchesAndNumbersEverything() {
        let f = makeFixture()
        let context = context("Welche To-dos sind diese Woche fällig?", f)
        let prompt = ChatService.prompt(question: "Welche To-dos sind diese Woche fällig?", history: [], context: context, bucket: nil, now: now)
        XCTAssertTrue(prompt.user.contains("Matching entries (kind: to-do; to-do state: open; due between Mon 16 Nov 2026 and Sun 22 Nov 2026): all 2 entries."), prompt.user)
        XCTAssertTrue(prompt.user.contains("[1] «Angebot an Müller schicken» — To-do, open, due 19 November 2026, overdue"))
        XCTAssertTrue(prompt.user.contains("[2] «Hecke schneiden» — To-do, open, due 22 November 2026"))
        XCTAssertTrue(prompt.system.contains("only from the entries and excerpts below"))
        XCTAssertTrue(prompt.system.contains("found nothing"))
        // The numbers of the prompt are the numbers of the sources.
        XCTAssertEqual(ChatService.sources(in: "Bis Sonntag [2].", items: context.items).map(\.title), ["Hecke schneiden"])
        // A small model gets the list first; it is told when it was cut.
        let many = ChatContext(
            items: (0..<50).map { ChatContextItem(noteID: UUID(), title: "T\($0)", date: now, header: "«T\($0)» — Note", text: String(repeating: "x", count: 150), isListing: true, isOutside: false) },
            matched: 50, filter: "kind: note"
        )
        XCTAssertTrue(ChatService.prompt(question: "?", history: [], context: many, bucket: nil, limit: 7000, now: now).user.contains("the first "))
    }

    // MARK: - Nothing found

    func testAQuestionWhoseWordsNoEntryHasGetsNoSources() {
        let f = makeFixture()
        // "Falke" is only in a deleted note: nothing has the words, the newest entries stand in.
        let falcon = context("Was weiß ich über den Codenamen Falke?", f)
        XCTAssertTrue(falcon.wordsNotFound)
        XCTAssertFalse(falcon.items.contains { $0.noteID == f["Geheimes Projekt"] })
        XCTAssertEqual(ChatService.sources(in: "Dazu habe ich nichts gefunden.", items: falcon.items, wordsNotFound: falcon.wordsNotFound), [])
        XCTAssertTrue(ChatService.prompt(question: "Was weiß ich über den Codenamen Falke?", history: [], context: falcon, bucket: nil).user.contains("No entry contains the words of the question"))
        // A question with words that are found keeps the fallback sources of an answer without numbers.
        let rent = context("Wie hoch ist die Kaution?", f)
        XCTAssertFalse(rent.wordsNotFound)
        XCTAssertEqual(ChatService.sources(in: "2.400 Euro.", items: rent.items, wordsNotFound: rent.wordsNotFound).first?.title, "Mietvertrag")
        // Without words to search for ("what was this week?") the newest entries are the answer, not a stand-in.
        XCTAssertFalse(context("Was war diese Woche?", f).wordsNotFound)
    }
}
