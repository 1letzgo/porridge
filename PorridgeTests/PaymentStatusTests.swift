import Foundation
import XCTest
@testable import Porridge

/// Bills that are open, overdue or paid: kept inside the document's JSON (old JSON still reads), the due day read in
/// German and English (also as a term in days), the state, the paid mark at once for several, and the search and
/// the chat asking for open, unpaid or overdue bills.
@MainActor
final class PaymentStatusTests: XCTestCase {
    private let now = DocumentInfo.date(fromDay: "2026-11-21")!

    // MARK: Stored in the attachment's JSON

    func testOldDocumentJSONStillReadsAndTheNewFieldsTravel() throws {
        let old = #"[{"bytes":10,"document":{"amount":"119.00 EUR","correspondent":"Telekom","day":"2026-03-02","isEdited":true,"kindRaw":"invoice"},"fileName":"a.pdf","id":"X","kindRaw":"pdf","name":"Rechnung.pdf"}]"#
        let decoded = try JSONDecoder().decode([Attachment].self, from: Data(old.utf8))
        let info = try XCTUnwrap(decoded.first?.document)
        XCTAssertEqual(info.kind, .invoice)
        XCTAssertNil(info.dueDay)
        XCTAssertNil(info.isPaid)
        XCTAssertNil(info.paymentStatus(now: now), "an old invoice without a due day has no state")

        var attachment = decoded[0]
        attachment.document?.dueDay = "2026-12-12"
        attachment.document?.setPaid(true, on: "2026-11-20")
        let data = try Attachment.encoder.encode([attachment])
        let round = try JSONDecoder().decode([Attachment].self, from: data)
        XCTAssertEqual(round.first?.document?.dueDay, "2026-12-12")
        XCTAssertEqual(round.first?.document?.paid, true)
        XCTAssertEqual(round.first?.document?.paidDay, "2026-11-20")
    }

    // MARK: Reading the due day

    func testDueDaysNamedInGermanAndEnglish() {
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Rechnungsdatum: 02.12.2026\nZahlbar bis 16.12.2026", documentDay: "2026-12-02"), "2026-12-16")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Der Betrag ist fällig am 15.01.2027.", documentDay: "2026-12-02"), "2027-01-15")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Invoice date: Dec 1, 2026\nDue date: December 31, 2026", documentDay: "2026-12-01"), "2026-12-31")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Payable by 2026-12-20", documentDay: nil), "2026-12-20")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Bitte überweisen Sie den Betrag bis zum 10.12.2026 auf unser Konto.", documentDay: "2026-11-30"), "2026-12-10")
        // A label alone, its day on the line below (a table).
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Fälligkeitsdatum\n18.12.2026", documentDay: "2026-12-01"), "2026-12-18")
        // The day of the document on the same line does not count as the due day.
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Rechnung vom 01.12.2026, fällig am 15.12.2026", documentDay: "2026-12-01"), "2026-12-15")
        XCTAssertNil(DocumentExtractor.dueDay(in: "Leistungszeitraum 01.02.2026 bis 28.02.2026", documentDay: "2026-03-02"))
        XCTAssertNil(DocumentExtractor.dueDay(in: "Zahlbar bis 01.01.2026", documentDay: "2026-03-02"), "not before the document's day")
    }

    func testTermsInDaysAreCountedFromTheDocumentsDay() {
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Zahlungsziel: 14 Tage", documentDay: "2026-12-02"), "2026-12-16")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Zahlbar innerhalb von 30 Tagen ohne Abzug", documentDay: "2026-12-02"), "2027-01-01")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "2 % Skonto bei Zahlung innerhalb 10 Tagen, 30 Tage netto", documentDay: "2026-11-01"), "2026-12-01")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Payment terms: net 30", documentDay: "2026-11-01"), "2026-12-01")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Please pay within 14 days.", documentDay: "2026-11-01"), "2026-11-15")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Sofort zahlbar ohne Abzug.", documentDay: "2026-11-01"), "2026-11-01")
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Due upon receipt", documentDay: "2026-11-01"), "2026-11-01")
        XCTAssertNil(DocumentExtractor.dueDay(in: "Zahlungsziel: 14 Tage", documentDay: nil), "a term needs the document's day")
        XCTAssertNil(DocumentExtractor.dueDay(in: "Lieferung in 3 Tagen", documentDay: "2026-11-01"), "a delivery time is no term of payment")
        // A day named wins over a term.
        XCTAssertEqual(DocumentExtractor.dueDay(in: "Zahlungsziel 14 Tage\nZahlbar bis 20.11.2026", documentDay: "2026-11-01"), "2026-11-20")
    }

    func testAWholeInvoiceGetsItsDueDayAndOnlyBillsDo() {
        let invoice = """
        Stadtwerke München GmbH · Emmy-Noether-Str. 2 · 80992 München
        Rechnung
        Rechnungsdatum: 10.11.2026
        Gesamtbetrag 84,20 €
        Zahlungsziel: 14 Tage
        """
        let info = DocumentExtractor.extract(from: invoice, now: now)
        XCTAssertEqual(info.kind, .invoice)
        XCTAssertEqual(info.day, "2026-11-10")
        XCTAssertEqual(info.dueDay, "2026-11-24")
        XCTAssertEqual(info.paymentStatus(now: now), .open)

        let quote = "Angebot\nAngebotsnummer 12\nDatum 10.11.2026\nGültig bis 10.12.2026\nZahlbar bis 20.12.2026"
        XCTAssertNil(DocumentExtractor.extract(from: quote, now: now).dueDay, "a quote is not paid")

        let reminder = "Mahnung\nDatum: 15.11.2026\nBitte zahlen Sie bis 25.11.2026."
        let read = DocumentExtractor.extract(from: reminder, now: now)
        XCTAssertEqual(read.kind, .invoice, "a reminder is a bill")
        XCTAssertEqual(read.dueDay, "2026-11-25")
    }

    func testADueDayReadLongAfterItPassedIsFromTheArchive() {
        let old = "Rechnung\nRechnungsdatum: 02.03.2026\nGesamtbetrag 119,00 €\nZahlbar bis 16.03.2026"
        XCTAssertNil(DocumentExtractor.extract(from: old, now: now).dueDay, "an old bill scanned late does not turn up as overdue")
        let recent = "Rechnung\nRechnungsdatum: 02.11.2026\nGesamtbetrag 119,00 €\nZahlbar bis 16.11.2026"
        XCTAssertEqual(DocumentExtractor.extract(from: recent, now: now).dueDay, "2026-11-16")
    }

    func testTheModelsLineMayNameTheDueDay() {
        let info = DocumentLine.parse("invoice | 2026-11-02 | Telekom | 39.95 EUR | 2026-11-16")
        XCTAssertEqual(info?.dueDay, "2026-11-16")
        XCTAssertNil(DocumentLine.parse("invoice | 2026-11-02 | Telekom | 39.95 EUR | none")?.dueDay)
        XCTAssertNil(DocumentLine.parse("contract | 2026-11-02 | Vermieter | none | 2026-12-01")?.dueDay, "a contract is not a bill")
        XCTAssertNil(DocumentLine.parse("invoice | 2026-11-02 | Telekom | none")?.dueDay, "answers with four fields still read")
        XCTAssertTrue(DocumentLine.prompt.contains("paid by"))
    }

    // MARK: State

    func testOpenOverdueAndPaid() {
        var info = DocumentInfo(kind: .invoice, day: "2026-11-01", dueDay: "2026-11-21")
        XCTAssertEqual(info.paymentStatus(now: now), .open, "due today is not late yet")
        XCTAssertTrue(info.isOpen)
        XCTAssertFalse(info.isOverdue(now: now))
        let tomorrow = DocumentInfo.calendar.date(byAdding: .day, value: 1, to: now)!
        XCTAssertEqual(info.paymentStatus(now: tomorrow), .overdue)
        XCTAssertTrue(info.isOverdue(now: tomorrow))
        XCTAssertTrue(info.matches(.open, now: tomorrow), "open takes overdue ones too")

        info.setPaid(true, now: tomorrow)
        XCTAssertEqual(info.paymentStatus(now: tomorrow), .paid)
        XCTAssertEqual(info.paidDay, "2026-11-22")
        XCTAssertFalse(info.isOpen)
        info.setPaid(false)
        XCTAssertNil(info.isPaid)
        XCTAssertNil(info.paidDay)

        XCTAssertNil(DocumentInfo(kind: .invoice).paymentStatus(now: now), "no due day, not paid: not followed")
        XCTAssertEqual(DocumentInfo(kind: .invoice, isPaid: true).paymentStatus(now: now), .paid)
        XCTAssertNil(DocumentInfo(kind: .contract, dueDay: "2026-01-01").paymentStatus(now: now), "a contract is never overdue")
        XCTAssertEqual(DocumentInfo(dueDay: "2026-01-01").paymentStatus(now: now), .overdue, "a paper without a kind can be a bill")
        XCTAssertFalse(DocumentInfo(dueDay: "2026-01-01").isEmpty)
    }

    func testTheChipsLabel() {
        XCTAssertTrue(DocumentInfo(kind: .invoice, dueDay: "2099-12-12").paymentLabel()?.hasPrefix("Open · due ") == true)
        XCTAssertEqual(DocumentInfo(kind: .invoice, dueDay: "2020-12-12").paymentLabel(), "Overdue")
        XCTAssertEqual(DocumentInfo(kind: .invoice, isPaid: true).paymentLabel(), "Paid")
        XCTAssertNil(DocumentInfo(kind: .invoice).paymentLabel())
    }

    func testPaidByHandIsKeptWhenTheDocumentIsReadAgain() throws {
        let note = document("Bill", DocumentInfo(kind: .invoice, day: "2026-11-02"))
        let context = try TestStore.context()
        context.insert(note)
        Documents.apply(.paid(true), to: [note], in: context, now: now)
        XCTAssertEqual(note.documentInfo?.paid, true)
        XCTAssertNotEqual(note.documentInfo?.edited, true, "the paid mark does not stop reading")
        Documents.apply(DocumentInfo(kind: .invoice, correspondent: "Telekom", dueDay: "2026-11-16"), to: note, now: now)
        XCTAssertEqual(note.documentInfo?.paid, true)
        XCTAssertEqual(note.documentInfo?.dueDay, "2026-11-16")
        XCTAssertEqual(note.paymentStatus(now: now), .paid)

        // A due day set by hand wins over what the model reads.
        var edited = note.documentInfo!
        edited.dueDay = "2026-12-24"
        Documents.set(edited, on: note, in: context)
        Documents.apply(DocumentInfo(kind: .invoice, dueDay: "2026-11-30"), to: note, now: now)
        XCTAssertEqual(note.documentInfo?.dueDay, "2026-12-24")
    }

    func testMarkingSeveralAsPaidLeavesOtherPapersAlone() throws {
        let context = try TestStore.context()
        let a = document("A", DocumentInfo(kind: .invoice, dueDay: "2026-11-01"))
        let b = document("B", DocumentInfo(kind: .notice, dueDay: "2026-12-01"))
        let c = document("C", DocumentInfo(kind: .contract))
        [a, b, c].forEach(context.insert)
        XCTAssertEqual(Documents.payable([a, b, c]).map(\.title), ["A", "B"])
        XCTAssertEqual(Documents.apply(.paid(true), to: [a, b, c], in: context, now: now), 2)
        XCTAssertEqual(a.paymentStatus(now: now), .paid)
        XCTAssertEqual(b.paymentStatus(now: now), .paid)
        XCTAssertNil(c.documentInfo?.isPaid)
        XCTAssertEqual(Documents.apply(.paid(false), to: [a], in: context, now: now), 1)
        XCTAssertEqual(a.paymentStatus(now: now), .overdue)
    }

    // MARK: Search and chat

    func testTheSearchFindsOpenUnpaidAndOverdueBills() {
        let late = document("Late", DocumentInfo(kind: .invoice, correspondent: "Telekom", dueDay: "2026-11-01"))
        let soon = document("Soon", DocumentInfo(kind: .invoice, correspondent: "Vodafone", dueDay: "2026-12-01"))
        let paid = document("Paid", DocumentInfo(kind: .invoice, dueDay: "2026-11-01", isPaid: true))
        let old = document("Old", DocumentInfo(kind: .invoice))
        func found(_ query: String) -> [String] {
            [late, soon, paid, old].filter { Documents.matches($0, query: query, now: now) }.map(\.title)
        }
        XCTAssertEqual(found("offene Rechnungen"), ["Late", "Soon"])
        XCTAssertEqual(found("unbezahlt"), ["Late", "Soon"])
        XCTAssertEqual(found("überfällig"), ["Late"])
        XCTAssertEqual(found("overdue invoices"), ["Late"])
        XCTAssertEqual(found("bezahlte Rechnungen"), ["Paid"])
        XCTAssertEqual(found("unbezahlt Vodafone"), ["Soon"])
    }

    func testTheChatReadsPaymentQuestions() {
        let open = ChatQuery.parse("Welche Rechnungen sind noch offen?", now: now, calendar: DocumentInfo.calendar)
        XCTAssertEqual(open.payment, .open)
        XCTAssertNil(open.todo, "open bills are no to-dos")
        XCTAssertFalse(open.kinds.contains(.todo))
        XCTAssertEqual(ChatQuery.parse("unbezahlte Rechnungen", now: now).payment, .open)
        XCTAssertEqual(ChatQuery.parse("Was ist noch nicht bezahlt?", now: now).payment, .open)
        XCTAssertEqual(ChatQuery.parse("überfällige Rechnungen", now: now).payment, .overdue)
        XCTAssertEqual(ChatQuery.parse("show unpaid bills", now: now).payment, .open)
        XCTAssertEqual(ChatQuery.parse("bezahlte Rechnungen 2026", now: now).payment, .paid)
        // To-dos stay to-dos.
        let todos = ChatQuery.parse("offene Aufgaben", now: now)
        XCTAssertEqual(todos.todo, .open)
        XCTAssertNil(todos.payment)
        XCTAssertEqual(ChatQuery.parse("was ist überfällig?", now: now).todo, .overdue)

        let late = ChatDocument(note: document("Late", DocumentInfo(kind: .invoice, correspondent: "Telekom", dueDay: "2026-11-01")))
        let soon = ChatDocument(note: document("Soon", DocumentInfo(kind: .invoice, dueDay: "2026-12-01")))
        let paid = ChatDocument(note: document("Paid", DocumentInfo(kind: .invoice, dueDay: "2026-11-01", isPaid: true)))
        let overdue = ChatQuery.parse("überfällige Rechnungen", now: now)
        XCTAssertEqual([late, soon, paid].filter { overdue.matches($0, now: now, calendar: DocumentInfo.calendar) }.map(\.title), ["Late"])
        XCTAssertEqual([late, soon, paid].filter { open.matches($0, now: now, calendar: DocumentInfo.calendar) }.map(\.title), ["Late", "Soon"])
        XCTAssertTrue(late.header(bucketNames: [:], now: now, calendar: DocumentInfo.calendar).contains("overdue (not paid)"))
        XCTAssertTrue(overdue.describe(bucketNames: [:]).contains("payment: overdue"))
    }

    func testAPaidMarkCutsTheChatsEntryAgain() {
        let note = document("Bill", DocumentInfo(kind: .invoice, dueDay: "2099-12-01"))
        let hash = note.indexHash
        var info = note.documentInfo!
        info.setPaid(true)
        note.documentInfo = info
        XCTAssertNotEqual(note.indexHash, hash)
    }

    // MARK: Helpers

    private func document(_ title: String, _ info: DocumentInfo) -> Note {
        let note = Note()
        note.source = .share
        note.title = title
        note.attachments = [Attachment(fileName: UUID().uuidString + ".pdf", name: title + ".pdf", kindRaw: "pdf")]
        note.documentInfo = info
        return note
    }
}
