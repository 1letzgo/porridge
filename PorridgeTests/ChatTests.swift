import SwiftData
import XCTest
@testable import Porridge

/// The chat with the notes: what goes into the index, what a question finds, and what is kept.
@MainActor
final class ChatTests: XCTestCase {
    private func note(_ title: String, text: String = "", buckets: [String] = []) -> Note {
        let note = Note()
        note.title = title
        note.text = text
        note.projectIDs = buckets
        return note
    }

    func testEverythingANoteHoldsBecomesPassages() {
        let file = note("Rechnung")
        file.source = .share
        file.attachments = [Attachment(fileName: "a.pdf", name: "Rechnung-4711.pdf", kindRaw: "pdf")]
        file.pageText = "Rechnung 4711 über 129 Euro"
        file.summary = "Eine Rechnung über 129 Euro."
        let link = note("Artikel")
        link.url = "https://example.com/a"
        link.pageText = "Der Artikel handelt von Hafer."
        let meeting = note("Kickoff", text: "Eigene Notiz")
        meeting.segments = [TranscriptSegment(start: 0, end: 1, text: "Wir starten im Januar.")]

        let texts = ChatRetrieval.chunks(from: [file, link, meeting]).map(\.text)
        XCTAssertTrue(texts.contains("File: Rechnung-4711.pdf"))
        XCTAssertTrue(texts.contains("Text of the file: Rechnung 4711 über 129 Euro"))
        XCTAssertTrue(texts.contains("Summary: Eine Rechnung über 129 Euro."))
        XCTAssertTrue(texts.contains { $0.hasPrefix("Saved link (example.com)") })
        XCTAssertTrue(texts.contains("Article (example.com): Der Artikel handelt von Hafer."))
        XCTAssertTrue(texts.contains("Eigene Notiz"))
        XCTAssertTrue(texts.contains("Transcript: Wir starten im Januar."))

        let deleted = note("Weg", text: "gelöscht")
        deleted.deletedAt = Date()
        XCTAssertTrue(ChatRetrieval.chunks(from: [deleted]).isEmpty)
    }

    func testAQuestionFindsThePassageWithItsWords() {
        let notes = [
            note("Urlaub", text: "Die Fähre nach Norwegen fährt am Dienstag."),
            note("Haushalt", text: "Die Waschmaschine braucht einen neuen Schlauch."),
            note("Projekt", text: "Der Vertrag wird im März unterschrieben."),
        ]
        let chunks = ChatRetrieval.chunks(from: notes)
        XCTAssertEqual(ChatRetrieval.search("Wann fährt die Fähre?", in: chunks).first?.title, "Urlaub")
        XCTAssertEqual(ChatRetrieval.search("Verträge", in: chunks).first?.title, "Projekt", "word forms count")
        XCTAssertTrue(ChatRetrieval.search("Quantencomputer", in: chunks).isEmpty)
        XCTAssertEqual(ChatRetrieval.recent(from: chunks).count, 3)
    }

    private func link(_ title: String, url: String, page: String, daysAgo: Int, now: Date) -> Note {
        let link = note(title)
        link.url = url
        link.pageText = page
        link.createdAt = now.addingTimeInterval(-Double(daysAgo) * 86400)
        return link
    }

    /// The question of the screenshot: a long German note full of the words every text has used to take all the
    /// places, and the GitHub links of the last days were not found.
    func testTheLinksOfTheLastDaysAreFoundAmongALongNote() {
        let now = Date()
        let filler = (1...40).map { "Die Tage vor der Messe stelle ich mir vor, dass wir in den letzten Wochen der Planung die Bühne \($0) aufbauen." }
        let long = note("Fusion MV", text: filler.joined(separator: "\n"))
        long.createdAt = now.addingTimeInterval(-86400)
        let old = link("Old repo", url: "https://github.com/old/repo", page: "An old project.", daysAgo: 60, now: now)
        let links = [
            link("swift-format", url: "https://github.com/swiftlang/swift-format", page: "Formatting for Swift source code.", daysAgo: 1, now: now),
            link("ollama", url: "https://github.com/ollama/ollama", page: "Run large language models locally.", daysAgo: 2, now: now),
            link("zed", url: "https://github.com/zed-industries/zed", page: "A code editor from the creators of Atom.", daysAgo: 3, now: now),
        ]
        let chunks = ChatRetrieval.chunks(from: [long, old] + links)
        let question = "Stelle mir die GitHub Highlights der letzten Tage vor"

        XCTAssertEqual(ChatRetrieval.queryWords(question), ["github"])
        let picked = ChatRetrieval.select(question, in: chunks, now: now)
        let titles = Set(picked.map(\.title))
        XCTAssertTrue(titles.isSuperset(of: ["swift-format", "ollama", "zed"]), "\(titles)")
        XCTAssertFalse(titles.contains("Old repo"), "the last days come first")
        XCTAssertFalse(titles.contains("Fusion MV"))
    }

    func testAQuestionNamesItsTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // Wednesday, 11 November 2026, noon.
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
        func since(_ question: String) -> DateComponents? {
            ChatRetrieval.since(in: question, now: now, calendar: calendar).map { calendar.dateComponents([.month, .day, .hour], from: $0) }
        }
        XCTAssertEqual(since("Was steht heute an?"), DateComponents(month: 11, day: 11, hour: 0))
        XCTAssertEqual(since("Was kam gestern?"), DateComponents(month: 11, day: 10, hour: 0))
        XCTAssertEqual(since("Was war diese Woche?"), DateComponents(month: 11, day: 9, hour: 0), "weeks start on Monday")
        XCTAssertEqual(since("What happened last week?"), DateComponents(month: 11, day: 2, hour: 0))
        XCTAssertEqual(since("GitHub der letzten Tage"), DateComponents(month: 11, day: 4, hour: 0))
        XCTAssertEqual(since("Notizen der letzten 3 Tage"), DateComponents(month: 11, day: 8, hour: 0))
        XCTAssertEqual(since("links from the last two weeks"), DateComponents(month: 10, day: 28, hour: 0))
        XCTAssertEqual(since("Was ist neu diesen Monat?"), DateComponents(month: 11, day: 1, hour: 0))
        XCTAssertNil(since("Wann fährt die Fähre?"))
    }

    func testATimeWithoutMatchesStillAnswers() {
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let old = note("Urlaub", text: "Die Fähre nach Norwegen fährt am Dienstag.")
        old.createdAt = now.addingTimeInterval(-90 * 86400)
        let fresh = note("Einkauf", text: "Milch und Brot.")
        fresh.createdAt = now.addingTimeInterval(-3600)
        let chunks = ChatRetrieval.chunks(from: [old, fresh])
        // Nothing about the ferry this week: the ferry is found anyway.
        XCTAssertEqual(ChatRetrieval.select("Was gab es diese Woche zur Fähre?", in: chunks, now: now).first?.title, "Urlaub")
        // No word to search for: the newest notes of that time.
        XCTAssertEqual(ChatRetrieval.select("Was war heute?", in: chunks, now: now).map(\.title), ["Einkauf"])
        // Only words every text has: the newest notes.
        XCTAssertEqual(ChatRetrieval.select("Was ist das?", in: chunks, now: now).first?.title, "Einkauf")
    }

    func testOneNoteTakesAtMostThreePlaces() {
        let long = note("Lang", text: (1...20).map { "Absatz \($0) über Hafer und noch mehr Hafer." }.joined(separator: "\n\n" + String(repeating: "x", count: 680) + "\n"))
        let short = note("Kurz", text: "Hafer.")
        let picked = ChatRetrieval.search("Hafer", in: ChatRetrieval.chunks(from: [long, short]))
        XCTAssertLessThanOrEqual(picked.filter { $0.title == "Lang" }.count, ChatRetrieval.passagesPerNote)
        XCTAssertTrue(picked.contains { $0.title == "Kurz" })
    }

    func testThePromptNamesToday() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let prompt = ChatService.prompt(question: "?", history: [], passages: [], buckets: [:], bucket: nil, now: now)
        XCTAssertTrue(prompt.system.hasPrefix("Today is \(now.formatted(date: .complete, time: .omitted))."))
    }

    func testAChatIsAboutAllNotesOrOneBucket() {
        let inBucket = note("A", buckets: ["P1"])
        let elsewhere = note("B", buckets: ["P2"])
        let deleted = note("C", buckets: ["P1"])
        deleted.deletedAt = Date()
        XCTAssertEqual(ChatService.scope(of: ChatThread(), notes: [inBucket, elsewhere, deleted]).map(\.title), ["A", "B"])
        XCTAssertEqual(ChatService.scope(of: ChatThread(projectID: "P1"), notes: [inBucket, elsewhere, deleted]).map(\.title), ["A"])
    }

    func testThePromptNamesBucketsAndTheAnswerItsSources() {
        let notes = [note("Urlaub", text: "Fähre am Dienstag"), note("Projekt", text: "Vertrag im März")]
        let chunks = ChatRetrieval.chunks(from: notes)
        let prompt = ChatService.prompt(
            question: "Wann?", history: [(role: .user, text: "Hallo")], passages: chunks,
            buckets: [notes[0].id: ["Reisen"]], bucket: nil
        )
        XCTAssertTrue(prompt.user.contains("[1] «Urlaub»"))
        XCTAssertTrue(prompt.user.contains(", Reisen)"))
        XCTAssertTrue(prompt.user.contains(", Inbox)"))
        XCTAssertTrue(prompt.user.contains("User: Hallo"))
        XCTAssertTrue(prompt.user.hasSuffix("Question: Wann?"))
        XCTAssertTrue(ChatService.prompt(question: "?", history: [], passages: chunks, buckets: [:], bucket: "Reisen").system.contains("\"Reisen\""))

        XCTAssertEqual(ChatService.sources(in: "Am Dienstag [1].", passages: chunks).map(\.title), ["Urlaub"])
        XCTAssertEqual(ChatService.sources(in: "Siehe [2, 1] und [9].", passages: chunks).map(\.title), ["Projekt", "Urlaub"])
        // Without a number the best passages stand in.
        XCTAssertEqual(ChatService.sources(in: "Keine Angabe.", passages: chunks).map(\.title), ["Urlaub", "Projekt"])
    }

    func testChatsAndTheirMessagesAreKept() throws {
        let context = try TestStore.context()
        let first = ChatThread()
        first.title = ChatService.title(for: "Was haben wir im letzten Meeting beschlossen und wer kümmert sich darum, bitte ausführlich?")
        let second = ChatThread(projectID: "P1")
        context.insert(first)
        context.insert(second)
        let question = ChatEntry(threadID: first.id, role: .user, text: "Wann?")
        question.createdAt = Date(timeIntervalSince1970: 100)
        let answer = ChatEntry(threadID: first.id, role: .assistant, text: "Am Dienstag [1].")
        answer.createdAt = Date(timeIntervalSince1970: 101)
        answer.sources = [ChatSource(noteID: UUID(), title: "Urlaub", date: Date(timeIntervalSince1970: 0))]
        context.insert(question)
        context.insert(answer)
        try context.save()

        let threads = try context.fetch(FetchDescriptor<ChatThread>())
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(Set(threads.map(\.projectID)), [nil, "P1"])
        XCTAssertTrue(first.title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(first.title.count, 60)
        let id = first.id
        let entries = try context.fetch(FetchDescriptor<ChatEntry>(predicate: #Predicate { $0.threadID == id }, sortBy: [SortDescriptor(\.createdAt)]))
        XCTAssertEqual(entries.map(\.role), [.user, .assistant])
        XCTAssertEqual(entries.last?.sources.map(\.title), ["Urlaub"])
    }
}
