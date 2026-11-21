import PDFKit
import SwiftData
import UIKit
import XCTest
@testable import Porridge

/// The PDF work of the documents: the invisible text layer of scans, page edits, splitting and merging, and changing
/// several documents at once.
@MainActor
final class PDFToolsTests: XCTestCase {
    // MARK: Text layer

    func testAScannedPageBecomesSearchableAndLooksTheSame() throws {
        let scan = try XCTUnwrap(scannedPDF(lines: ["RECHNUNG 4711", "Telekom Deutschland GmbH"]))
        let original = try XCTUnwrap(PDFDocument(data: scan))
        XCTAssertEqual(PDFTextLayer.pagesWithoutText(original), [0])

        let layered = try XCTUnwrap(PDFTextLayer.searchableData(of: scan))
        let document = try XCTUnwrap(PDFDocument(data: layered))
        XCTAssertEqual(document.pageCount, 1)
        let text = document.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("4711"), "found by search: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Telekom"))
        XCTAssertEqual(PDFTextLayer.pagesWithoutText(document), [])
        XCTAssertFalse(document.findString("4711", withOptions: .caseInsensitive).isEmpty)

        // Invisible: the page draws the same as before.
        let before = try XCTUnwrap(PDFTextLayer.render(try XCTUnwrap(original.page(at: 0))))
        let after = try XCTUnwrap(PDFTextLayer.render(try XCTUnwrap(document.page(at: 0))))
        XCTAssertLessThan(differingPixels(before, after), before.width * before.height / 200)

        // A reasonable size: the picture is not stored twice.
        XCTAssertLessThan(Double(layered.count), Double(scan.count) * PDFTextLayer.maxGrowth + 200_000)
        // Nothing left to do: the file is not read again.
        XCTAssertNil(PDFTextLayer.searchableData(of: layered) { _ in
            XCTFail("a page with text is read again")
            return []
        })
    }

    func testOnlyPagesWithoutTextAreReadAndTheirRotationStays() throws {
        let text = try XCTUnwrap(PDFDocument(data: textPDF("Already text")))
        let scan = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(scannedPDF(lines: ["SCAN"]))))
        let document = PDFPages.merged([text, scan])
        document.page(at: 1)?.rotation = 90
        var read = 0
        let changed = PDFTextLayer.addTextLayer(to: document) { _ in
            read += 1
            return [PDFTextLayer.Line(text: "Fake line", box: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.05))]
        }
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(read, 1)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Already text") ?? false)
        XCTAssertTrue(document.page(at: 1)?.string?.contains("Fake line") ?? false)
        XCTAssertEqual(document.page(at: 1)?.rotation, 90)
        // Nothing read: nothing changes.
        let empty = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(scannedPDF(lines: ["X"]))))
        XCTAssertEqual(PDFTextLayer.addTextLayer(to: empty) { _ in [] }, 0)
    }

    // MARK: Pages

    func testRotateMoveAndDeletePages() throws {
        let document = try numbered(4)
        PDFPages.rotate(document, pages: [0, 2], by: 90)
        PDFPages.rotate(document, pages: [0], by: -180)
        XCTAssertEqual((0..<4).map { document.page(at: $0)!.rotation }, [270, 0, 90, 0])

        PDFPages.move(document, from: [3], to: 0)
        XCTAssertEqual(order(document), ["Page 4", "Page 1", "Page 2", "Page 3"])
        PDFPages.move(document, from: [0, 1], to: 4)
        XCTAssertEqual(order(document), ["Page 2", "Page 3", "Page 4", "Page 1"])

        XCTAssertEqual(PDFPages.delete(document, pages: [1, 2]), 2)
        XCTAssertEqual(order(document), ["Page 2", "Page 1"])
        XCTAssertEqual(PDFPages.delete(document, pages: [0, 1]), 1, "the last page stays")
        XCTAssertEqual(document.pageCount, 1)
    }

    func testMergeAndExtract() throws {
        let merged = PDFPages.merged([try numbered(2), try numbered(1)])
        XCTAssertEqual(order(merged), ["Page 1", "Page 2", "Page 1"])
        XCTAssertEqual(order(PDFPages.extract(try numbered(5), pages: [4, 1, 1])), ["Page 2", "Page 5"])
    }

    func testSplitGroupsAndLabels() {
        XCTAssertEqual(PDFPages.groups(for: .everyPage, pageCount: 3), [[1], [2]], "the original keeps the first page")
        XCTAssertEqual(PDFPages.groups(for: .pages([3, 1, 1]), pageCount: 4), [[1, 3]])
        XCTAssertEqual(PDFPages.groups(for: .pages([0, 1]), pageCount: 2), [], "one page has to stay")
        XCTAssertEqual(PDFPages.groups(for: .pages([7]), pageCount: 2), [])
        XCTAssertEqual(PDFPages.groups(for: .everyPage, pageCount: 1), [])
        XCTAssertEqual(PDFPages.label([1, 2, 3]), "Pages 2–4")
        XCTAssertEqual(PDFPages.label([2]), "Page 3")
        XCTAssertEqual(PDFPages.label([0, 2, 4]), "Pages 1, 3, 5")
    }

    // MARK: Files

    func testReplacingTheFileKeepsTheAttachmentAndWhatTheDocumentIs() throws {
        let context = try TestStore.context()
        let note = try storedPDF(try numbered(2), in: context)
        let before = note.attachments[0]
        note.documentInfo = DocumentInfo(kind: .invoice, correspondent: "Telekom", isEdited: true)
        note.pageText = "old text"

        let data = try XCTUnwrap(try numbered(3).dataRepresentation())
        try DocumentFiles.replace(before.id, of: note, with: data)
        let after = note.attachments[0]
        XCTAssertEqual(after.id, before.id)
        XCTAssertNotEqual(after.fileName, before.fileName, "a new name: no device keeps a stale copy")
        XCTAssertEqual(after.bytes, Int64(data.count))
        XCTAssertEqual(after.document, DocumentInfo(kind: .invoice, correspondent: "Telekom", isEdited: true))
        XCTAssertEqual(note.pageText, "old text", "kept until the new file is read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioStore.localURL(for: before.fileName).path))
        XCTAssertEqual(PDFDocument(url: AudioStore.localURL(for: after.fileName))?.pageCount, 3)
        AudioStore.delete(after.fileName)
    }

    func testSplittingMakesNewDocumentsInTheSameBowl() async throws {
        let context = try TestStore.context()
        let processing = ProcessingService(container: context.container)
        let note = try storedPDF(try numbered(4), in: context)
        note.title = "Brief"
        note.projectIDs = ["BOWL"]
        note.documentInfo = DocumentInfo(kind: .letter, day: "2026-01-02", correspondent: "Finanzamt", amount: "5.00 EUR", isEdited: true)

        let parts = try await DocumentFiles.split(note, .pages([1, 2]), context: context, processing: processing)
        XCTAssertEqual(parts.count, 1)
        let part = try XCTUnwrap(parts.first)
        XCTAssertEqual(part.title, "Brief (Pages 2–3)")
        XCTAssertEqual(part.projectIDs, ["BOWL"])
        XCTAssertEqual(part.documentInfo, DocumentInfo(kind: .letter, correspondent: "Finanzamt"), "only what was set by hand, not its date or amount")
        XCTAssertEqual(order(try XCTUnwrap(PDFDocument(url: AttachmentStore.url(for: part.attachments[0])))), ["Page 2", "Page 3"])
        XCTAssertEqual(order(try XCTUnwrap(PDFDocument(url: AttachmentStore.url(for: note.attachments[0])))), ["Page 1", "Page 4"])
        XCTAssertEqual(note.documentInfo?.amount, "5.00 EUR", "the original keeps what it is")

        let every = try await DocumentFiles.split(note, .everyPage, context: context, processing: processing)
        XCTAssertEqual(every.map(\.title), ["Brief (Page 2)"])
        XCTAssertEqual(PDFDocument(url: AttachmentStore.url(for: note.attachments[0]))?.pageCount, 1)
        XCTAssertNil(DocumentFiles.carriedInfo(DocumentInfo(kind: .invoice, correspondent: "X")), "read, not set: read again")
        for item in [note] + parts + every { item.attachments.forEach { AudioStore.delete($0.fileName) } }
    }

    func testMergingKeepsTheTargetsInfoAndLeavesTheOthers() async throws {
        let context = try TestStore.context()
        let processing = ProcessingService(container: context.container)
        let target = try storedPDF(try numbered(1), in: context)
        target.documentInfo = DocumentInfo(kind: .contract, correspondent: "Vermieter")
        let other = try storedPDF(try numbered(2), in: context)
        other.documentInfo = DocumentInfo(kind: .invoice, day: "2026-02-01", correspondent: "Hausverwaltung")

        try await DocumentFiles.merge([other], into: target, context: context, processing: processing)
        XCTAssertEqual(order(try XCTUnwrap(PDFDocument(url: AttachmentStore.url(for: target.attachments[0])))), ["Page 1", "Page 1", "Page 2"])
        XCTAssertEqual(target.documentInfo, DocumentInfo(kind: .contract, day: "2026-02-01", correspondent: "Vermieter"))
        XCTAssertFalse(other.isDeleted, "deleting the others is asked for separately")
        XCTAssertEqual(DocumentFiles.mergeable([target, other, Note()]).count, 2)
        XCTAssertEqual(DocumentFiles.mergedInfo(target: nil, others: [nil, DocumentInfo(kind: .receipt)]), DocumentInfo(kind: .receipt))
        for item in [target, other] { item.attachments.forEach { AudioStore.delete($0.fileName) } }
    }

    // MARK: Several at once

    func testBulkChanges() throws {
        let context = try TestStore.context()
        let a = try storedPDF(try numbered(1), in: context)
        a.suggestedProjectIDs = ["S"]
        let b = try storedPDF(try numbered(1), in: context)
        b.projectIDs = ["OLD", "OTHER"]
        b.documentInfo = DocumentInfo(kind: .invoice, day: "2026-01-01", correspondent: "Telekom")
        let plain = Note()
        context.insert(plain)

        XCTAssertEqual(Documents.apply(.move(toBowl: "NEW"), to: [a, b, plain], in: context), 3)
        XCTAssertEqual([a, b, plain].map(\.projectIDs), [["NEW"], ["NEW"], ["NEW"]])
        XCTAssertNotNil(a.filedAt)
        XCTAssertEqual(a.suggestedProjectIDs, [])
        XCTAssertEqual(Documents.apply(.move(toBowl: "NEW"), to: [a], in: context), 0, "nothing to change")
        Documents.apply(.move(toBowl: nil), to: [a], in: context)
        XCTAssertTrue(a.isInInbox)

        XCTAssertEqual(Documents.apply(.kind(.receipt), to: [a, b, plain], in: context), 2, "only documents have a kind")
        XCTAssertEqual(b.documentInfo, DocumentInfo(kind: .receipt, day: "2026-01-01", correspondent: "Telekom", isEdited: true))
        Documents.apply(.sender("  Vodafone "), to: [a, b], in: context)
        XCTAssertEqual(a.documentInfo?.correspondent, "Vodafone")
        XCTAssertTrue(a.documentInfo?.edited ?? false)
        Documents.apply(.sender(""), to: [b], in: context)
        XCTAssertNil(b.documentInfo?.correspondent)
        // Set by hand: reading again keeps it.
        XCTAssertFalse(Documents.read(b, text: "Rechnung\nMuster AG", now: Date()))
        for item in [a, b] { item.attachments.forEach { AudioStore.delete($0.fileName) } }
    }

    // MARK: Helpers

    /// A PDF whose single page is only a picture of the lines, as a scan is.
    private func scannedPDF(lines: [String]) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 1190, height: 1684)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 120, y: 200 + CGFloat(index) * 120), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: UIColor.black,
                ])
            }
        }
        guard let url = ScannedPDF.write([image], title: "Test") else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? Data(contentsOf: url)
    }

    private func textPDF(_ text: String) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            (text as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
        }
    }

    private func numbered(_ count: Int) throws -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            for index in 1...count {
                context.beginPage()
                ("Page \(index)" as NSString).draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func order(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func storedPDF(_ document: PDFDocument, in context: ModelContext) throws -> Note {
        let name = AudioStore.newFileName(extension: "pdf")
        try XCTUnwrap(document.dataRepresentation()).write(to: AudioStore.localURL(for: name))
        let note = Note()
        note.source = .share
        note.attachments = [Attachment(fileName: name, name: "doc.pdf", kindRaw: "pdf")]
        context.insert(note)
        return note
    }

    private func differingPixels(_ a: CGImage, _ b: CGImage) -> Int {
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = CGContext(
                data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return data
        }
        guard a.width == b.width, a.height == b.height else { return .max }
        let x = pixels(a), y = pixels(b)
        var count = 0
        for index in stride(from: 0, to: x.count, by: 4) where abs(Int(x[index]) - Int(y[index])) > 24 { count += 1 }
        return count
    }
}
