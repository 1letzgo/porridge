import SwiftData
import XCTest
@testable import Porridge

/// Mails read from their source (.eml) and saved as one inbox entry each.
@MainActor
final class MailImportTests: XCTestCase {
    private func mail(_ lines: [String], lineEnd: String = "\r\n") -> Data {
        Data(lines.joined(separator: lineEnd).utf8)
    }

    // MARK: Reading

    func testAPlainMailWithQuotedPrintableAndEncodedHeaders() throws {
        let data = mail([
            "From: =?UTF-8?Q?J=C3=BCrgen_M=C3=BCller?= <juergen@example.de>",
            "To: \"Doe, Jane\" <jane@example.com>, bob@example.com",
            "Cc: Team <team@example.com>",
            "Subject: =?UTF-8?B?UmVjaG51bmcgZsO8cg==?=",
            " =?UTF-8?Q?_M=C3=A4rz?=",
            "Date: Tue, 3 Mar 2026 10:15:00 +0100 (CET)",
            "Message-ID: <abc@example.de>",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=\"utf-8\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "Hallo Jane,",
            "",
            "anbei die Rechnung f=C3=BCr M=C3=A4rz. Eine sehr lange Zeile, die umbrochen w=",
            "ird.",
            "",
            "Gr=C3=BC=C3=9Fe",
        ])
        let message = try MailMessage.parse(data)
        XCTAssertEqual(message.subject, "Rechnung für März")
        XCTAssertEqual(message.from, .init(name: "Jürgen Müller", email: "juergen@example.de"))
        XCTAssertEqual(message.to, [.init(name: "Doe, Jane", email: "jane@example.com"), .init(name: nil, email: "bob@example.com")])
        XCTAssertEqual(message.cc.map(\.email), ["team@example.com"])
        XCTAssertEqual(message.messageID, "abc@example.de")
        XCTAssertEqual(message.date, ISO8601DateFormatter().date(from: "2026-03-03T09:15:00Z"))
        XCTAssertEqual(message.body, "Hallo Jane,\n\nanbei die Rechnung für März. Eine sehr lange Zeile, die umbrochen wird.\n\nGrüße")
        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testMultipartPrefersPlainTextAndKeepsAttachmentsButNotInlinePictures() throws {
        let pdf = Data("%PDF-1.4 fake".utf8)
        let logo = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let data = mail([
            "From: Telekom <rechnung@telekom.de>",
            "Subject: Ihre Rechnung",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"outer\"",
            "",
            "This is a multi-part message in MIME format.",
            "--outer",
            "Content-Type: multipart/related; boundary=inner-rel",
            "",
            "--inner-rel",
            "Content-Type: multipart/alternative; boundary=\"alt\"",
            "",
            "--alt",
            "Content-Type: text/plain; charset=iso-8859-1",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "Sehr geehrter Kunde, Ihre Rechnung ist da. Gr=FC=DFe",
            "--alt",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<html><body><p>Sehr geehrter Kunde</p><img src=\"cid:logo123\"></body></html>",
            "--alt--",
            "--inner-rel",
            "Content-Type: image/png",
            "Content-Transfer-Encoding: base64",
            "Content-ID: <logo123>",
            "",
            logo.base64EncodedString(),
            "--inner-rel--",
            "--outer",
            "Content-Type: application/pdf; name=\"ignored.pdf\"",
            "Content-Disposition: attachment; filename*=UTF-8''Rechnung%20M%C3%A4rz.pdf",
            "Content-Transfer-Encoding: base64",
            "",
            String(pdf.base64EncodedString().prefix(8)),
            String(pdf.base64EncodedString().dropFirst(8)),
            "--outer",
            "Content-Type: application/pkcs7-signature; name=smime.p7s",
            "Content-Transfer-Encoding: base64",
            "",
            "AAAA",
            "--outer--",
        ])
        let message = try MailMessage.parse(data)
        XCTAssertEqual(message.body, "Sehr geehrter Kunde, Ihre Rechnung ist da. Grüße")
        XCTAssertEqual(message.attachments.count, 3)
        XCTAssertEqual(message.files.map(\.name), ["Rechnung März.pdf"])
        XCTAssertEqual(message.files.first?.data, pdf)
        XCTAssertEqual(message.attachments.first { $0.contentID == "logo123" }?.data, logo)
        XCTAssertTrue(message.attachments.first { $0.contentID == "logo123" }?.isInline ?? false)
    }

    func testAnHTMLOnlyMailInLatin1BecomesReadableText() throws {
        let html = """
        <html><head><style>p { color: red; }</style><title>x</title></head><body>
        <h1>Bestellbest&auml;tigung</h1>
        <p>Vielen Dank f\u{FC}r Ihre Bestellung.<br>Lieferung:   morgen</p>
        <ul><li>Kaffee &amp; Tee</li><li>Br&ouml;tchen&nbsp;&#8364;&#x20AC;</li></ul>
        <!-- tracking --><script>alert(1)</script>
        <p><a href="https://example.com">Zum Konto</a></p>
        </body></html>
        """
        var bytes = Data("From: shop@example.com\nSubject: Bestellung\nContent-Type: text/html; charset=ISO-8859-1\nContent-Transfer-Encoding: 8bit\n\n".utf8)
        bytes += html.data(using: .isoLatin1)!
        let message = try MailMessage.parse(bytes)
        XCTAssertEqual(message.body, "Bestellbestätigung\n\nVielen Dank für Ihre Bestellung.\nLieferung: morgen\n\n- Kaffee & Tee\n- Brötchen €€\n\nZum Konto")
        XCTAssertEqual(message.from?.senderName, "example.com")
    }

    func testAMailWithLineFeedsOnlyAndRFC2231Pieces() throws {
        let data = mail([
            "From: \"Stadtwerke\" <info@stadtwerke.de>",
            "Subject: Abschlag",
            "Content-Type: multipart/mixed; boundary=b1",
            "",
            "--b1",
            "",
            "Body without its own header.",
            "--b1",
            "Content-Type: application/octet-stream",
            "Content-Disposition: attachment;",
            " filename*0*=utf-8''Jahres;",
            " filename*1*=%C3%BCbersicht;",
            " filename*2=\".pdf\"",
            "",
            "raw bytes",
            "--b1--",
        ], lineEnd: "\n")
        let message = try MailMessage.parse(data)
        XCTAssertEqual(message.body, "Body without its own header.")
        XCTAssertEqual(message.files.map(\.name), ["Jahresübersicht.pdf"])
        XCTAssertEqual(message.files.first?.data, Data("raw bytes".utf8))
        XCTAssertEqual(message.from?.senderName, "Stadtwerke")
    }

    func testAForwardedMailIsKeptAsAFile() throws {
        let data = mail([
            "From: a@example.com",
            "Subject: Fwd: Hi",
            "Content-Type: multipart/mixed; boundary=x",
            "",
            "--x",
            "Content-Type: text/plain",
            "",
            "See below.",
            "--x",
            "Content-Type: message/rfc822",
            "",
            "From: b@example.com",
            "Subject: Hi",
            "",
            "Hello",
            "--x--",
        ])
        let message = try MailMessage.parse(data)
        XCTAssertEqual(message.body, "See below.")
        XCTAssertEqual(message.files.count, 1)
        XCTAssertEqual(MailNote.fileName(for: message.files[0]), "Forwarded Message 1.eml")
    }

    func testDeeplyNestedPartsAreReadOnlyToALimit() throws {
        // 300 multiparts inside each other: read in bounded time, down to `MIMEPart.maxDepth`.
        var body = "Content-Type: text/plain\r\n\r\ndeep text\r\n"
        for level in 0..<300 {
            body = "Content-Type: multipart/mixed; boundary=\"b\(level)\"\r\n\r\n--b\(level)\r\n" + body + "--b\(level)--\r\n"
        }
        let source = "From: a@b.de\r\nSubject: Deep\r\n" + body
        let start = Date()
        let message = try MailMessage.parse(Data(source.utf8))
        XCTAssertEqual(message.subject, "Deep")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        let file = MailMessage.Attachment(name: "../" + String(repeating: "x", count: 400) + ".pdf", mimeType: "application/pdf", data: Data([1]), isInline: false)
        let name = MailNote.fileName(for: file)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.hasPrefix("."))
        XCTAssertTrue(name.hasSuffix(".pdf"))
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
        XCTAssertEqual(MailNote.fileName(for: MailMessage.Attachment(name: "..", mimeType: "application/pdf", data: Data([1]), isInline: false)), "Attachment.pdf")
    }

    func testNoMailAtAllIsRefused() {
        XCTAssertThrowsError(try MailMessage.parse(Data("just some words without a header line".utf8)))
    }

    // MARK: The entry

    func testTheEntryTextNamesSenderAndDayForTheDocumentRecognition() throws {
        var message = MailMessage()
        message.subject = "Ihre Rechnung"
        message.from = .init(name: "Telekom Deutschland", email: "rechnung@telekom.de")
        message.to = [.init(name: nil, email: "me@example.com")]
        message.date = ISO8601DateFormatter().date(from: "2026-03-03T09:15:00Z")
        message.body = "Guten Tag"
        let text = MailNote.text(for: message, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertEqual(text, "**From:** Telekom Deutschland <rechnung@telekom.de>\n**To:** me@example.com\n**Date:** 2026-03-03 10:15\n\nGuten Tag")
        XCTAssertEqual(MailNote.sender(in: text), "Telekom Deutschland")
        XCTAssertEqual(MailNote.day(in: text), "2026-03-03")
        // A note of one's own is no mail.
        XCTAssertNil(MailNote.sender(in: "Notes\n**From:** someone"))

        // The PDF names no sender or date: the mail's are taken. A sender in the letterhead wins.
        let plain = DocumentExtractor.extract(from: "Rechnung\nGesamtbetrag 19,99 €", name: "Rechnung.pdf", senderHint: "Telekom", dayHint: "2026-03-03")
        XCTAssertEqual(plain.correspondent, "Telekom")
        XCTAssertEqual(plain.day, "2026-03-03")
        XCTAssertEqual(plain.kind, .invoice)
        let headed = DocumentExtractor.extract(from: "Muster GmbH · Hauptstr. 1\nRechnung vom 01.02.2026", name: "a.pdf", senderHint: "Telekom", dayHint: "2026-03-03")
        XCTAssertEqual(headed.correspondent, "Muster GmbH")
        XCTAssertEqual(headed.day, "2026-02-01")
        // A holiday photo from a friend does not become the friend's document.
        let photo = DocumentExtractor.extract(from: "", name: "IMG_1.jpg", senderHint: "Anna")
        XCTAssertNil(photo.correspondent)
    }

    func testPDFsComeFirstAmongTheFiles() {
        let files: [MailMessage.Attachment] = [
            .init(name: "photo.jpg", mimeType: "image/jpeg", data: Data([1]), isInline: false),
            .init(name: "notes", mimeType: "text/calendar", data: Data([1]), isInline: false),
            .init(name: "Vertrag.docx", mimeType: "application/octet-stream", data: Data([1]), isInline: false),
            .init(name: "Rechnung.pdf", mimeType: "application/pdf", data: Data([1]), isInline: false),
        ]
        XCTAssertEqual(MailNote.ordered(files).map(\.name), ["Rechnung.pdf", "Vertrag.docx", "photo.jpg", "notes"])
        XCTAssertEqual(MailNote.fileName(for: files[1]), "notes.ics")
    }

    func testADroppedMailBecomesOneEntryWithItsFilesAttached() throws {
        let context = try TestStore.context()
        let processing = ProcessingService(container: context.container)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MailImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Invoice.eml")
        try mail([
            "From: Telekom <rechnung@telekom.de>",
            "Subject: Ihre Rechnung",
            "Date: Tue, 3 Mar 2026 10:15:00 +0100",
            "Content-Type: multipart/mixed; boundary=\"b\"",
            "",
            "--b",
            "Content-Type: text/plain; charset=utf-8",
            "",
            "Anbei Ihre Rechnung.",
            "--b",
            "Content-Type: image/jpeg; name=\"scan.jpg\"",
            "Content-Disposition: attachment; filename=\"scan.jpg\"",
            "Content-Transfer-Encoding: base64",
            "",
            Data([0xFF, 0xD8, 0xFF]).base64EncodedString(),
            "--b",
            "Content-Type: application/pdf; name=\"Rechnung.pdf\"",
            "Content-Disposition: attachment; filename=\"Rechnung.pdf\"",
            "Content-Transfer-Encoding: base64",
            "",
            Data("%PDF-".utf8).base64EncodedString(),
            "--b--",
        ]).write(to: url)

        let bowl = NoteFolder(name: "Bills")
        context.insert(bowl)
        let note = try XCTUnwrap(ShareImport.add(files: [url], project: bowl.id.uuidString, context: context, processing: processing))
        addTeardownBlock { @MainActor in note.storedFileNames.forEach(AudioStore.delete) }

        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(note.title, "Ihre Rechnung")
        XCTAssertTrue(note.text.hasPrefix("**From:** Telekom <rechnung@telekom.de>"))
        XCTAssertTrue(note.text.hasSuffix("Anbei Ihre Rechnung."))
        XCTAssertEqual(note.source, .share)
        XCTAssertEqual(note.projectIDs, [bowl.id.uuidString])
        // The PDF first: what the entry is as a document is read from it.
        XCTAssertEqual(note.attachments.map(\.name), ["Rechnung.pdf", "scan.jpg"])
        XCTAssertEqual(note.attachments.map(\.kind), [.pdf, .image])
        XCTAssertTrue(note.attachments.allSatisfy(AttachmentStore.exists))
        XCTAssertTrue(note.isDocument)
        XCTAssertEqual(note.status, .recorded)

        // Read like a shared document: the mail's sender fills the sender the PDF does not name.
        XCTAssertTrue(Documents.read(note, text: "Rechnung\nRechnungsbetrag 39,95 €"))
        XCTAssertEqual(note.documentInfo?.kind, .invoice)
        XCTAssertEqual(note.documentInfo?.correspondent, "Telekom")
        XCTAssertEqual(note.documentInfo?.amount, "39.95 EUR")
        XCTAssertEqual(note.documentInfo?.day, "2026-03-03")
    }

    func testAMailSharedFromAMailAppBecomesItsEntryAndNothingElse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MailShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ShareInbox.rootOverride = root
        addTeardownBlock { @MainActor in
            ShareInbox.rootOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        var entry = ShareInbox.Entry(text: "Lunch?")
        let dir = try ShareInbox.folder(for: entry.id)
        try mail(["From: Anna <anna@example.com>", "Subject: Lunch?", "", "Tomorrow at noon?"]).write(to: dir.appendingPathComponent("x.eml"))
        entry.files = [.init(stored: "x.eml", name: "Lunch?.eml", kind: .file)]
        try ShareInbox.add(entry)

        let context = try TestStore.context()
        ShareImport.importInbox(context: context, processing: ProcessingService(container: context.container))

        let notes = try context.fetch(FetchDescriptor<Note>())
        XCTAssertEqual(notes.map(\.title), ["Lunch?"])
        XCTAssertEqual(notes.first?.text, "**From:** Anna <anna@example.com>\n\nTomorrow at noon?")
        XCTAssertNil(notes.first?.attachmentsData)
        XCTAssertTrue(notes.first?.isInInbox ?? false)
        XCTAssertTrue(ShareInbox.pending().isEmpty)
    }
}
