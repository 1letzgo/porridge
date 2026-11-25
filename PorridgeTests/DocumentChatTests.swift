import Foundation
import XCTest
@testable import Porridge

/// Documents in the chat and the search: questions are read for document kind, sender, year and amount, and the
/// search finds a document by the German or English name of its kind.
@MainActor
final class DocumentChatTests: XCTestCase {
    private let now = DocumentInfo.date(fromDay: "2026-11-21")!
    private let senders = ["Telekom Deutschland GmbH", "Vodafone", "Deutsche Bank AG"]

    // MARK: Reading the question

    func testAQuestionAboutInvoicesOfASenderInAYear() {
        let query = ChatQuery.parse("Welche Rechnungen von Telekom kamen 2026?", senders: senders, now: now, calendar: DocumentInfo.calendar)
        XCTAssertEqual(query.documentKinds, [.invoice])
        XCTAssertEqual(query.senders, ["telekom deutschland"])
        XCTAssertEqual(query.range?.start, DocumentInfo.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        XCTAssertEqual(query.range?.end, DocumentInfo.calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
        XCTAssertTrue(query.isStructured)
        XCTAssertFalse(query.words.contains("telekom"), "the sender is a filter, not a word to search for")
        XCTAssertFalse(query.words.contains("rechnungen"))
        XCTAssertTrue(query.describe(bucketNames: [:]).contains("document kind: invoice"))
    }

    func testKindsInEnglishAndGermanAndWordsThatMeanSomethingElse() {
        XCTAssertEqual(ChatQuery.parse("show my contracts", now: now).documentKinds, [.contract])
        XCTAssertEqual(ChatQuery.parse("Wo sind meine Verträge und Kontoauszüge?", now: now).documentKinds, [.contract, .statement])
        XCTAssertEqual(ChatQuery.parse("list receipts", now: now).documentKinds, [.receipt])
        XCTAssertTrue(ChatQuery.parse("give me a brief summary", now: now).documentKinds.isEmpty)
        XCTAssertTrue(ChatQuery.parse("did you notice the statement?", now: now).documentKinds.isEmpty)
        XCTAssertFalse(ChatQuery.parse("what did we decide in 2025?", now: now).range != nil, "a year counts only in a question about documents")
        // A sender only by a distinctive word: "Deutsche" names no one.
        XCTAssertTrue(ChatQuery.parse("Deutsche Post", senders: senders, now: now).senders.isEmpty)
        XCTAssertEqual(ChatQuery.parse("Briefe der Deutschen Bank", senders: senders, now: now).senders, [])
        XCTAssertEqual(ChatQuery.parse("Briefe von Deutsche Bank", senders: senders, now: now).senders, ["deutsche bank"])
    }

    func testAmounts() {
        let over = ChatQuery.parse("Rechnungen über 100 Euro", now: now)
        XCTAssertEqual(over.minAmount, 100)
        XCTAssertNil(over.maxAmount)
        XCTAssertEqual(ChatQuery.parse("receipts under $20", now: now).maxAmount, 20)
        XCTAssertEqual(ChatQuery.parse("Belege unter 20 €", now: now).maxAmount, 20)
        XCTAssertNil(ChatQuery.parse("mehr als 3 Tage", now: now).minAmount, "no currency, no amount")
    }

    /// Documents keep no payment status: "offene Rechnungen" asks for the invoices, not for to-dos or a state.
    func testNoPaymentStateInAQuestion() {
        for question in ["offene Rechnungen", "fällige Rechnungen", "überfällige Rechnungen"] {
            let query = ChatQuery.parse(question, now: now)
            XCTAssertEqual(query.documentKinds, [.invoice], question)
            XCTAssertNil(query.todo, question)
            XCTAssertTrue(query.kinds.isEmpty, question)
            XCTAssertEqual(query.dateField, .auto, question)
            XCTAssertFalse(query.describe(bucketNames: [:]).contains("pa"), question)
        }
        // Without a kind of document the state words are a to-do's, as always.
        XCTAssertEqual(ChatQuery.parse("offene Aufgaben", now: now).todo, .open)
        // The model's line: a fifth field (a payment day, from older prompts) is not read.
        XCTAssertNil(DocumentLine.parse("invoice | 2026-03-02 | Telekom | 119.00 EUR | 2026-03-16")?.dueDay)
        XCTAssertFalse(DocumentLine.prompt.contains("paid"))
        XCTAssertNil(DocumentExtractor.extract(from: "Rechnung\nTelekom\n02.03.2026\nZahlbar bis 16.03.2026", now: now).dueDay)
    }

    // MARK: Matching and the context

    func testTheContextListsTheMatchingDocumentsByTheirDate() {
        let telekom = document("Telekom März", kind: .invoice, day: "2026-03-02", sender: "Telekom Deutschland GmbH", amount: "119.00 EUR")
        // Came in last year, dated this year: counts for 2026.
        telekom.createdAt = DocumentInfo.date(fromDay: "2025-12-30")!
        let old = document("Telekom 2025", kind: .invoice, day: "2025-05-02", sender: "Telekom Deutschland GmbH", amount: "39.95 EUR")
        let vodafone = document("Vodafone", kind: .invoice, day: "2026-04-01", sender: "Vodafone", amount: "20.00 EUR")
        let contract = document("Vertrag", kind: .contract, day: "2026-01-01", sender: "Telekom Deutschland GmbH", amount: nil)
        let note = Note()
        note.title = "Telekom anrufen"
        note.text = "Wegen der Rechnung"
        let notes = [telekom, old, vodafone, contract, note]
        let documents = Dictionary(uniqueKeysWithValues: notes.map { ($0.id, ChatDocument(note: $0)) })

        XCTAssertEqual(documents[telekom.id]?.documentKind, "invoice")
        XCTAssertNil(documents[note.id]?.documentKind)
        XCTAssertTrue(documents[telekom.id]!.header(bucketNames: [:], now: now).contains("Document: Invoice from Telekom Deutschland GmbH, dated "))

        let context = ChatRetrieval.context(
            "Welche Rechnungen von Telekom kamen 2026?", documents: documents, chunks: ChatRetrieval.chunks(from: notes),
            bucketNames: [:], now: now, calendar: DocumentInfo.calendar
        )
        XCTAssertEqual(context.matched, 1)
        XCTAssertEqual(context.items.filter(\.isListing).map(\.noteID), [telekom.id])

        let expensive = ChatRetrieval.context(
            "Rechnungen über 30 Euro", documents: documents, chunks: ChatRetrieval.chunks(from: notes),
            bucketNames: [:], now: now, calendar: DocumentInfo.calendar
        )
        XCTAssertEqual(Set(expensive.items.filter(\.isListing).map(\.noteID)), [telekom.id, old.id])

        let contracts = ChatRetrieval.context(
            "show my contracts", documents: documents, chunks: ChatRetrieval.chunks(from: notes), bucketNames: [:], now: now
        )
        XCTAssertEqual(contracts.items.filter(\.isListing).map(\.noteID), [contract.id])
    }

    func testIndexFilesFromBeforeStillRead() throws {
        // An entry without the document's fields, as index files from before hold them.
        let plain = Note()
        plain.title = "Plain"
        let data = try JSONEncoder().encode(ChatDocument(note: plain))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("documentKind"))
        let decoded = try JSONDecoder().decode(ChatDocument.self, from: data)
        XCTAssertNil(decoded.documentInfo)
        XCTAssertFalse(ChatQuery(documentKinds: [.invoice]).matches(decoded))

        let invoice = document("A", kind: .invoice, day: "2026-03-02", sender: "Telekom", amount: "1.00 EUR")
        let round = try JSONDecoder().decode(ChatDocument.self, from: JSONEncoder().encode(ChatDocument(note: invoice)))
        XCTAssertEqual(round, ChatDocument(note: invoice))
    }

    func testADocumentIsCutAgainOnceForTheChatsNewEntry() {
        let invoice = document("A", kind: .invoice, day: "2026-03-02", sender: "Telekom", amount: nil)
        let hash = invoice.indexHash
        invoice.documentInfo = DocumentInfo(kind: .contract, day: "2026-03-02", correspondent: "Telekom")
        XCTAssertNotEqual(invoice.indexHash, hash, "what the document is belongs to its entry")
    }

    // MARK: Search

    func testTheSearchFindsADocumentByTheNameOfItsKind() {
        let invoice = document("Scan 3 Mar", kind: .invoice, day: "2026-03-02", sender: "Telekom", amount: nil)
        invoice.pageText = "Kundennummer 1234 Betrag 119,00"
        XCTAssertTrue(Documents.matches(invoice, query: "Rechnung"))
        XCTAssertTrue(Documents.matches(invoice, query: "rechnungen telekom"))
        XCTAssertTrue(Documents.matches(invoice, query: "invoices"))
        XCTAssertFalse(Documents.matches(invoice, query: "Vertrag"))
        XCTAssertFalse(Documents.matches(invoice, query: "Rechnung Vodafone"), "every other word has to be in it")
        XCTAssertFalse(Documents.matches(invoice, query: "Telekom"), "without a kind word it is the ordinary search")
        XCTAssertTrue(invoice.matches("Rechnungen"))

        let photo = Note()
        photo.source = .share
        photo.attachments = [Attachment(fileName: "x.jpg", name: "x.jpg", kindRaw: "image")]
        XCTAssertFalse(Documents.matches(photo, query: "Sonstiges"), "a photo that is no document has no kind")

        XCTAssertEqual(DocumentKind.named("Verträge"), .contract)
        XCTAssertEqual(DocumentKind.named("Quittungen"), .receipt)
        XCTAssertEqual(DocumentKind.named("Kontoauszug"), .statement)
        XCTAssertEqual(DocumentKind.named("payslips"), .payslip)
        XCTAssertNil(DocumentKind.named("Katze"))
    }

    // MARK: Helpers

    private func document(_ title: String, kind: DocumentKind?, day: String?, sender: String?, amount: String?) -> Note {
        let note = Note()
        note.source = .share
        note.title = title
        note.attachments = [Attachment(fileName: UUID().uuidString + ".pdf", name: title + ".pdf", kindRaw: "pdf")]
        note.documentInfo = DocumentInfo(kind: kind, day: day, correspondent: sender, amount: amount)
        return note
    }
}
