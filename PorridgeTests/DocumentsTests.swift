import PDFKit
import SwiftData
import UIKit
import XCTest
@testable import Porridge

/// The small document management: what a document is (read on the device and by the model, or set by hand), how
/// documents are listed and filtered, and which bowl one is suggested for.
@MainActor
final class DocumentsTests: XCTestCase {
    private let now = DocumentInfo.date(fromDay: "2026-11-21")!

    private let germanInvoice = """
    Telekom Deutschland GmbH · Landgrabenweg 151 · 53227 Bonn
    Herrn Max Mustermann
    Musterstraße 1
    12345 Berlin
    Rechnung
    Rechnungsnummer: 1234567890
    Rechnungsdatum: 02.03.2026
    Kundennummer 99887766
    Leistungszeitraum 01.02.2026 bis 28.02.2026
    MagentaMobil M        39,95 €
    Summe netto           100,00 €
    zzgl. 19 % MwSt.       19,00 €
    Gesamtbetrag          119,00 €
    Zahlbar bis 16.03.2026
    Mit freundlichen Grüßen
    """

    private let englishReceipt = """
    BLUE BOTTLE COFFEE
    123 Main St, Oakland
    March 3, 2026 9:41 AM
    Latte                 5.50
    Croissant             4.25
    Subtotal              9.75
    Tax                   0.88
    Total               $10.63
    Thank you for your purchase
    """

    // MARK: Extraction on the device

    func testAGermanInvoiceIsReadWhole() {
        let info = DocumentExtractor.extract(from: germanInvoice, name: "Telekom.pdf", now: now)
        XCTAssertEqual(info.kind, .invoice)
        XCTAssertEqual(info.day, "2026-03-02", "the invoice date, not the period or the due date")
        XCTAssertEqual(info.correspondent, "Telekom Deutschland GmbH")
        XCTAssertEqual(info.amount, "119.00 EUR", "the total, not the net amount or the tax")
    }

    func testAnEnglishReceiptIsRead() {
        let info = DocumentExtractor.extract(from: englishReceipt, now: now)
        XCTAssertEqual(info.kind, .receipt)
        XCTAssertEqual(info.day, "2026-03-03")
        XCTAssertEqual(info.amount, "10.63 USD")
    }

    func testKindsFollowTheirWords() {
        XCTAssertEqual(DocumentExtractor.kind(in: "Gehaltsabrechnung für März 2026\nAuszahlungsbetrag 2.345,67"), .payslip)
        XCTAssertEqual(DocumentExtractor.kind(in: "Kontoauszug Nr. 3\nAlter Kontostand 1.000,00"), .statement)
        XCTAssertEqual(DocumentExtractor.kind(in: "Einkommensteuerbescheid für 2025\nFinanzamt Berlin"), .notice)
        XCTAssertEqual(DocumentExtractor.kind(in: "Angebot Nr. 17\nGültig bis 31.12.2026"), .offer)
        XCTAssertEqual(DocumentExtractor.kind(in: "Mietvertrag\nzwischen den Vertragspartnern"), .contract)
        XCTAssertEqual(DocumentExtractor.kind(in: "Sehr geehrte Damen und Herren,\nwir freuen uns.\nMit freundlichen Grüßen"), .letter)
        XCTAssertNil(DocumentExtractor.kind(in: "A photo of a cat"))
        // The file's name counts more than a word in the text.
        XCTAssertEqual(DocumentExtractor.kind(in: "Sehr geehrte Frau Muster", name: "Versicherungsschein Hausrat.pdf"), .insurance)
    }

    func testDatesInEveryUsualWriting() {
        XCTAssertEqual(DocumentExtractor.dates(in: "Datum: 2.3.26"), ["2026-03-02"])
        XCTAssertEqual(DocumentExtractor.dates(in: "Berlin, den 14. März 2026"), ["2026-03-14"])
        XCTAssertEqual(DocumentExtractor.dates(in: "Invoice date 2026-01-31"), ["2026-01-31"])
        XCTAssertEqual(DocumentExtractor.dates(in: "Issued on January 5th, 2026"), ["2026-01-05"])
        XCTAssertEqual(DocumentExtractor.dates(in: "14/03/2026 and 03/04/2026"), ["2026-03-14", "2026-03-04"])
        XCTAssertEqual(DocumentExtractor.dates(in: "31.02.2026 is no day"), [])
        XCTAssertEqual(DocumentExtractor.dates(in: "Total 12.50 EUR"), [])
    }

    func testTheDateOfTheDocumentWinsOverDueAndFarFutureDates() {
        let text = "Fällig am 30.04.2026\nVertragsende 01.01.2030\nBerlin, 15.04.2026"
        XCTAssertEqual(DocumentExtractor.day(in: text, now: now), "2026-04-15")
        XCTAssertEqual(DocumentExtractor.day(in: "Zahlbar bis 30.04.2026", now: now), "2026-04-30", "a due date is better than none")
        XCTAssertNil(DocumentExtractor.day(in: "no date here", now: now))
    }

    func testNumbersAreReadInGermanAndEnglishWriting() {
        XCTAssertEqual(DocumentExtractor.parseNumber("1.234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(DocumentExtractor.parseNumber("1,234.56"), Decimal(string: "1234.56"))
        XCTAssertEqual(DocumentExtractor.parseNumber("19,99"), Decimal(string: "19.99"))
        XCTAssertEqual(DocumentExtractor.parseNumber("-5.00"), Decimal(string: "-5"))
        XCTAssertNil(DocumentExtractor.parseNumber("12,5"))
        XCTAssertEqual(DocumentExtractor.format(Decimal(string: "1234.5")!), "1234.50")
        XCTAssertEqual(DocumentExtractor.format(Decimal(119)), "119.00")
    }

    func testTheTotalIsFoundAmongOtherAmounts() {
        let text = "Zwischensumme 50,00 EUR\nRabatt 5,00 EUR\nZu zahlen 45,00 EUR\nGegeben 50,00 EUR\nRückgeld 5,00 EUR"
        XCTAssertEqual(DocumentExtractor.amount(in: text)?.value, "45.00 EUR")
        XCTAssertEqual(DocumentExtractor.amount(in: "Preis: CHF 1'250.00")?.value, "1250.00 CHF")
        XCTAssertNil(DocumentExtractor.amount(in: "Artikel 3 4,99\nMenge 2 3,50"), "numbers in a table without currency or label are no total")
        // "ust" counts as a word, not inside "August".
        XCTAssertEqual(DocumentExtractor.amount(in: "Rechnung August 2026: 80,00 €")?.value, "80.00 EUR")
    }

    func testASenderIsTakenFromTheLetterheadOnly() {
        XCTAssertEqual(DocumentExtractor.correspondent(in: "Stadtwerke München\nPostfach 1\nKundin Frau Muster"), "Stadtwerke München")
        XCTAssertEqual(DocumentExtractor.correspondent(in: "Muster AG | Hauptstr. 1 | 10115 Berlin\nRechnung"), "Muster AG")
        XCTAssertNil(DocumentExtractor.correspondent(in: "Bankverbindung: Sparkasse Berlin"), "a field, not a name")
        XCTAssertNil(DocumentExtractor.correspondent(in: "Liebe Anna,\nwie geht es dir?"))
        XCTAssertEqual(DocumentExtractor.correspondent(in: "Acme Inc.\n1 Infinite Loop"), "Acme Inc.")
    }

    func testItemsOfAReceiptAreNoSender() {
        XCTAssertNil(DocumentExtractor.correspondent(in: "Bananen 1,2 kg\nÄpfel 2,99 EUR"), "a weight is no legal form")
        XCTAssertNil(DocumentExtractor.correspondent(in: "Obst AG 3,99"), "a line with a price is an item")
        XCTAssertNil(DocumentExtractor.correspondent(in: "Filiale 12 AG"), "a name with a number is an address")
        XCTAssertNil(DocumentExtractor.correspondent(in: "danke se"), "a legal form only after a capitalised name")
        XCTAssertNil(DocumentExtractor.correspondent(in: "AG"))
    }

    func testSpellingsOfOneSenderAreTheSame() {
        XCTAssertEqual(DocumentExtractor.correspondentKey("Telekom Deutschland GmbH"), DocumentExtractor.correspondentKey("telekom deutschland"))
        XCTAssertEqual(DocumentExtractor.correspondentKey("Müller & Co. KG"), "muller")
        XCTAssertNotEqual(DocumentExtractor.correspondentKey("Vodafone"), DocumentExtractor.correspondentKey("Telekom"))
    }

    func testTypedAmounts() {
        XCTAssertEqual(DocumentExtractor.typedAmount("119", currency: "EUR"), "119.00 EUR")
        XCTAssertEqual(DocumentExtractor.typedAmount("119,5", currency: nil), "119.50")
        XCTAssertEqual(DocumentExtractor.typedAmount("1.234,56", currency: "EUR"), "1234.56 EUR")
        XCTAssertNil(DocumentExtractor.typedAmount("abc", currency: "EUR"))
        XCTAssertNil(DocumentExtractor.typedAmount("  ", currency: "EUR"))
    }

    // MARK: The model's line

    func testTheModelsLineIsTakenOffTheSummaryAndRead() {
        let answer = "## Summary\nA phone bill.\n\nTAGS: phone, bill\nDOCUMENT: Invoice | 2026-03-02 | Telekom Deutschland GmbH | 119.00 EUR"
        let (text, info) = DocumentLine.split(answer)
        XCTAssertEqual(text, "## Summary\nA phone bill.\n\nTAGS: phone, bill")
        XCTAssertEqual(info, DocumentInfo(kind: .invoice, day: "2026-03-02", correspondent: "Telekom Deutschland GmbH", amount: "119.00 EUR"))
    }

    func testUnknownFieldsOfTheModelsLineStayUnknown() {
        XCTAssertEqual(DocumentLine.parse(" letter | none | \"Finanzamt Berlin\" | none"), DocumentInfo(kind: .letter, correspondent: "Finanzamt Berlin"))
        // A kind the model made up is unknown, so the device's guess stays; German words are understood.
        XCTAssertEqual(DocumentLine.parse("memo | 3. März 2026 | - | 12,50 €"), DocumentInfo(day: "2026-03-03", amount: "12.50 EUR"))
        XCTAssertEqual(DocumentLine.parse("Rechnung | none | none | none")?.kind, .invoice)
        XCTAssertEqual(DocumentLine.parse("Vertrag | none | Vermieter | none")?.kind, .contract)
        XCTAssertEqual(DocumentLine.parse("Quittung | none | Bäckerei | none")?.kind, .receipt)
        XCTAssertEqual(DocumentLine.parse("Brief | none | Anna | none")?.kind, .letter)
        XCTAssertEqual(DocumentLine.parse("other | none | Anna | none")?.kind, .other)
        XCTAssertNil(DocumentLine.parse("none | none | none | none"))
        XCTAssertEqual(DocumentLine.split("No line here").info, nil)
        XCTAssertTrue(DocumentLine.prompt.contains("invoice | receipt"))
    }

    // MARK: Stored with the attachment

    func testTheInfoTravelsInsideTheAttachmentListAndOldListsStillRead() throws {
        var attachment = Attachment(fileName: "a.pdf", name: "Rechnung.pdf", kindRaw: "pdf", bytes: 10)
        attachment.document = DocumentInfo(kind: .invoice, day: "2026-03-02", correspondent: "Telekom", amount: "119.00 EUR")
        let data = try Attachment.encoder.encode([attachment])
        XCTAssertEqual(try JSONDecoder().decode([Attachment].self, from: data), [attachment])
        XCTAssertEqual(try Attachment.encoder.encode([attachment]), data, "the same bytes every time, for the sync")

        let old = #"[{"bytes":10,"fileName":"a.pdf","id":"X","kindRaw":"pdf","name":"Rechnung.pdf"}]"#
        let decoded = try JSONDecoder().decode([Attachment].self, from: Data(old.utf8))
        XCTAssertNil(decoded.first?.document)
    }

    func testWhatCountsAsADocument() {
        let pdf = storedNote(kind: "pdf", name: "Brief.pdf")
        XCTAssertTrue(pdf.isDocument)

        let photo = storedNote(kind: "image", name: "IMG_1.jpg")
        XCTAssertFalse(photo.isDocument, "a photo is no document until it was read as one")
        photo.documentInfo = DocumentInfo(kind: .receipt)
        XCTAssertTrue(photo.isDocument)
        photo.documentInfo = DocumentInfo(kind: .other)
        XCTAssertFalse(photo.isDocument)
        // Marked as one by hand (the chip after the bowls): a screenshot counts as a document.
        photo.documentInfo = DocumentInfo(kind: .other, isEdited: true)
        XCTAssertTrue(photo.isDocument)
        photo.documentInfo = DocumentInfo(day: "2026-03-02", isEdited: true)
        XCTAssertTrue(photo.isDocument)
        photo.documentInfo = DocumentInfo(isEdited: true)
        XCTAssertFalse(photo.isDocument, "everything taken away: no document any more")

        XCTAssertFalse(storedNote(kind: "file", name: "backup.zip").isDocument)
        XCTAssertTrue(storedNote(kind: "file", name: "Vertrag.docx").isDocument)

        // A note with a file attached stays a note.
        let note = storedNote(kind: "pdf", name: "Plan.pdf")
        note.source = .note
        XCTAssertFalse(note.isDocument)
    }

    func testReadingKeepsWhatWasSetByHandAndTheModelRefinesTheGuess() throws {
        let context = try TestStore.context()
        let note = storedNote(kind: "pdf", name: "Telekom.pdf")
        context.insert(note)

        XCTAssertTrue(Documents.read(note, text: germanInvoice, now: now))
        XCTAssertEqual(note.documentInfo?.kind, .invoice)

        Documents.apply(DocumentInfo(correspondent: "Telekom"), to: note)
        XCTAssertEqual(note.documentInfo?.correspondent, "Telekom")
        XCTAssertEqual(note.documentInfo?.amount, "119.00 EUR", "what the model did not say stays")

        Documents.set(DocumentInfo(kind: .contract, correspondent: "  Telekom AG  "), on: note, in: context)
        XCTAssertEqual(note.documentInfo?.correspondent, "Telekom AG")
        XCTAssertTrue(note.documentInfo?.edited ?? false)

        XCTAssertFalse(Documents.read(note, text: englishReceipt, now: now))
        Documents.apply(DocumentInfo(kind: .receipt), to: note)
        XCTAssertEqual(note.documentInfo?.kind, .contract, "set by hand, kept")
    }

    func testAFreshGuessNeverReplacesWhatIsKnownAndNothingReadChangesNothing() throws {
        let note = storedNote(kind: "pdf", name: "scan.pdf")
        // What the model found, maybe on another device.
        note.documentInfo = DocumentInfo(kind: .invoice, day: "2026-02-01", correspondent: "Telekom")
        XCTAssertFalse(Documents.read(note, text: "", now: now), "a file iCloud did not deliver yet")
        XCTAssertFalse(Documents.read(note, text: "  \n ", now: now))
        XCTAssertEqual(note.documentInfo, DocumentInfo(kind: .invoice, day: "2026-02-01", correspondent: "Telekom"))

        // Read again on this device: only what was missing is filled in.
        XCTAssertTrue(Documents.read(note, text: germanInvoice, now: now))
        XCTAssertEqual(note.documentInfo, DocumentInfo(kind: .invoice, day: "2026-02-01", correspondent: "Telekom", amount: "119.00 EUR"))

        // "Other" says less than a kind: it fills, it never replaces.
        XCTAssertEqual(DocumentInfo(kind: .invoice).merged(with: DocumentInfo(kind: .other)).kind, .invoice)
        XCTAssertEqual(DocumentInfo().merged(with: DocumentInfo(kind: .other)).kind, .other)
        XCTAssertEqual(DocumentInfo(kind: .other).merged(with: DocumentInfo(kind: .receipt)).kind, .receipt)
        let guessedOther = storedNote(kind: "pdf", name: "x.pdf")
        guessedOther.documentInfo = DocumentInfo(kind: .other)
        Documents.read(guessedOther, text: germanInvoice, now: now)
        XCTAssertEqual(guessedOther.documentInfo?.kind, .invoice)
    }

    func testRemovingTheFirstFileKeepsWhatTheDocumentIs() {
        let note = storedNote(kind: "pdf", name: "a.pdf")
        let second = Attachment(fileName: "b.pdf", name: "b.pdf", kindRaw: "pdf")
        note.attachments += [second]
        note.documentInfo = DocumentInfo(kind: .contract, correspondent: "Vermieter", isEdited: true)
        let first = note.attachments[0].id

        note.removeAttachment(id: first)
        XCTAssertEqual(note.attachments.map(\.id), [second.id])
        XCTAssertEqual(note.documentInfo, DocumentInfo(kind: .contract, correspondent: "Vermieter", isEdited: true))

        note.removeAttachment(id: "unknown")
        XCTAssertEqual(note.attachments.count, 1)
        note.removeAttachment(id: second.id)
        XCTAssertTrue(note.attachments.isEmpty)
    }

    func testDayKeysAreGregorianWhateverTheCalendar() {
        XCTAssertEqual(DocumentInfo.calendar.identifier, .gregorian)
        let date = DocumentInfo.date(fromDay: "2026-03-02")!
        XCTAssertEqual(DocumentInfo.dayKey(date), "2026-03-02")
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = .current
        XCTAssertEqual(buddhist.component(.year, from: date), 2569, "what Calendar.current would give in Thailand")
    }

    func testSearchFindsADocumentByItsSender() {
        let note = storedNote(kind: "pdf", name: "scan.pdf")
        note.documentInfo = DocumentInfo(kind: .invoice, correspondent: "Stadtwerke München")
        XCTAssertTrue(note.matches("stadtwerke"))
        XCTAssertTrue(note.matches("Invoice"))
        XCTAssertFalse(note.matches("Telekom"))
    }

    // MARK: Order

    func testDocumentsAreOrderedByTheirDate() {
        let a = document("A", kind: .invoice, day: "2026-03-02", sender: "Telekom GmbH")
        let b = document("B", kind: .receipt, day: "2025-12-24", sender: "Bäckerei Schmidt")
        let c = document("C", kind: .invoice, day: "2026-05-01", sender: "telekom")
        let d = document("D", kind: nil, day: nil, sender: nil)
        d.createdAt = DocumentInfo.date(fromDay: "2024-01-01")!
        XCTAssertEqual(Documents.sorted([a, b, c, d]).map(\.title), ["C", "A", "B", "D"], "without a date, by when it came in")
        XCTAssertEqual(d.documentDate, d.createdAt)
    }

    func testTheLineOfARow() {
        let info = DocumentInfo(kind: .invoice, day: "2026-03-02", correspondent: "Telekom", amount: "119.00 EUR")
        XCTAssertTrue(info.line.hasPrefix("Invoice · Telekom · "))
        // The chip after the bowls: kind and sender only.
        XCTAssertEqual(info.shortLabel, "Invoice · Telekom")
        XCTAssertEqual(DocumentInfo(correspondent: "Telekom").shortLabel, "Telekom")
        XCTAssertEqual(DocumentInfo(day: "2026-03-02").shortLabel, "Document")
        XCTAssertTrue(info.sentence.hasPrefix("Invoice from Telekom, dated "))
        XCTAssertEqual(DocumentInfo(kind: .letter, amount: "5.00 EUR").line, "Letter", "a letter's amount says nothing")
    }

    // MARK: Filing

    func testADocumentIsSuggestedTheBowlItsSendersDocumentsWentInto() throws {
        let context = try TestStore.context()
        let home = NoteFolder(name: "Haushalt")
        let work = NoteFolder(name: "Arbeit")
        let archived = NoteFolder(name: "Alt")
        archived.archivedAt = Date()
        [home, work, archived].forEach(context.insert)
        let filed: [(NoteFolder, String)] = [
            (home, "Telekom Deutschland GmbH"), (home, "Telekom"), (home, "Telekom"), (work, "Telekom"),
            // Archived bowls are never suggested, however many documents went there.
            (archived, "Telekom"), (archived, "Telekom"), (archived, "Telekom"),
        ]
        for (bowl, sender) in filed {
            let filed = document("old", kind: .invoice, day: "2025-01-01", sender: sender)
            filed.projectIDs = [Projects.key(bowl)]
            context.insert(filed)
        }
        let new = document("new", kind: .invoice, day: "2026-03-02", sender: "telekom deutschland")
        context.insert(new)
        try context.save()

        XCTAssertEqual(Documents.suggestedBowl(for: new, in: context), Projects.key(home))

        let unknown = document("other", kind: .invoice, day: "2026-03-02", sender: "Vodafone")
        context.insert(unknown)
        XCTAssertNil(Documents.suggestedBowl(for: unknown, in: context))

        // Set by hand, a known sender brings the suggestion along.
        let scanned = storedNote(kind: "pdf", name: "scan.pdf")
        context.insert(scanned)
        Documents.set(DocumentInfo(kind: .invoice, correspondent: "Telekom"), on: scanned, in: context)
        XCTAssertEqual(scanned.suggestedProjectIDs, [Projects.key(home)])
    }

    func testFilesReadBeforeDocumentsWereLookedAtGetTheirGuessOnce() throws {
        let context = try TestStore.context()
        let read = storedNote(kind: "pdf", name: "Rechnung.pdf")
        read.pageText = germanInvoice
        let unread = storedNote(kind: "pdf", name: "x.pdf")
        let photo = storedNote(kind: "image", name: "cat.jpg")
        photo.pageText = ""
        [read, unread, photo].forEach(context.insert)
        try context.save()

        XCTAssertEqual(Documents.backfill(in: context, now: now), 2)
        XCTAssertEqual(read.documentInfo?.kind, .invoice)
        XCTAssertNil(unread.documentInfo, "not read yet: comes when its text is")
        XCTAssertEqual(photo.documentInfo, DocumentInfo(), "looked at, nothing found")
        XCTAssertEqual(Documents.backfill(in: context, now: now), 0)
    }

    // MARK: Scans

    func testScannedPagesBecomeOnePDF() throws {
        let page = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 141)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 141))
        }
        let url = try XCTUnwrap(ScannedPDF.write([page, page, page], title: "Scanned Document"))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Scan "))
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 3)
        XCTAssertNil(ScannedPDF.write([], title: ""))
        XCTAssertEqual(ScannedPDF.fileName(title: "Mietvertrag 2026/27"), "Mietvertrag 2026-27.pdf")
    }

    func testScannedPagesAreMadeSmallAndReadOneAtATime() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 4000), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 4000))
        }
        let small = try XCTUnwrap(ScannedPDF.compressed(big))
        XCTAssertEqual(small.size.width * small.scale, ScannedPDF.pixelWidth)
        XCTAssertEqual(small.size.height * small.scale, (4000 * ScannedPDF.pixelWidth / 3000).rounded())
        let tiny = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { _ in }
        XCTAssertEqual(try XCTUnwrap(ScannedPDF.compressed(tiny)).size.width, 400, "never made larger")

        var asked: [Int] = []
        let url = try XCTUnwrap(ScannedPDF.write(pageCount: 2, title: "") { index in
            asked.append(index)
            return big
        })
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(asked, [0, 1])
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 2)
    }

    // MARK: Helpers

    private func storedNote(kind: String, name: String) -> Note {
        let note = Note()
        note.source = .share
        note.title = (name as NSString).deletingPathExtension
        note.attachments = [Attachment(fileName: UUID().uuidString + "." + (name as NSString).pathExtension, name: name, kindRaw: kind)]
        return note
    }

    private func document(_ title: String, kind: DocumentKind?, day: String?, sender: String?) -> Note {
        let note = storedNote(kind: "pdf", name: title + ".pdf")
        note.title = title
        note.documentInfo = DocumentInfo(kind: kind, day: day, correspondent: sender)
        return note
    }
}
