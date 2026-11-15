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
