import CoreText
import Foundation
import PDFKit
import Vision

/// Makes a scanned PDF searchable: pages that are only a picture get the text Vision reads on them as an invisible
/// layer at the place it was read, so the PDF can be searched and its text selected anywhere (Preview, Finder,
/// Spotlight, other apps). Pages that have text already are left exactly as they are and are not read again.
/// Pure and not on the main actor: it runs in a background task (`DocumentFiles`).
enum PDFTextLayer {
    /// A line of text Vision read, with its box in the page's picture (0…1, origin bottom left, as Vision gives it).
    struct Line: Equatable, Sendable {
        var text: String
        var box: CGRect
    }

    /// At most this many pages are read per file; a longer scan gets its first pages searchable.
    static let maxPages = 50
    /// A layered file may grow by this much over the original at most; beyond it the original is kept (the text is
    /// in the note anyway). Redrawing a page keeps its pictures as they are, so this is a guard, not the rule.
    static let maxGrowth = 2.0

    /// The pages (indices) without any text of their own.
    static func pagesWithoutText(_ document: PDFDocument) -> [Int] {
        (0..<document.pageCount).filter { index in
            (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The file with a text layer on the pages that had none; nil when there is nothing to add (every page has text,
    /// nothing could be read) or the result would be far larger than the file.
    static func searchableData(of data: Data, recognize: (CGImage) -> [Line] = recognizeLines) -> Data? {
        guard let document = PDFDocument(data: data), !document.isEncrypted else { return nil }
        guard addTextLayer(to: document, recognize: recognize) > 0, let result = document.dataRepresentation() else { return nil }
        guard Double(result.count) <= Double(data.count) * maxGrowth + 200_000 else {
            print("[pdf] text layer skipped: \(data.count) → \(result.count) bytes")
            return nil
        }
        return result
    }

    /// The pages that get a layer: without text, upright (a turned page would be read sideways; it keeps being read
    /// for the note's text the usual way) and without annotations (signatures, form fields and links would not survive
    /// the page being drawn again).
    static func pagesToLayer(_ document: PDFDocument) -> [Int] {
        pagesWithoutText(document).filter { index in
            guard let page = document.page(at: index) else { return false }
            return page.rotation % 360 == 0 && page.annotations.isEmpty
        }
    }

    /// Puts a text layer on every page that can get one (`pagesToLayer`, up to `maxPages`). Returns how many did.
    @discardableResult
    static func addTextLayer(to document: PDFDocument, recognize: (CGImage) -> [Line] = recognizeLines) -> Int {
        var changed = 0
        for index in pagesToLayer(document).prefix(maxPages) {
            autoreleasepool {
                guard let page = document.page(at: index), let image = render(page) else { return }
                let lines = recognize(image).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !lines.isEmpty, let layered = self.page(page, with: lines) else { return }
                document.removePage(at: index)
                document.insert(layered, at: index)
                changed += 1
            }
        }
        return changed
    }

    /// The page drawn into a picture of about 150 dpi (its media box, unrotated, so the boxes Vision finds map
    /// straight back onto the page).
    static func render(_ page: PDFPage) -> CGImage? {
        guard let cgPage = page.pageRef else { return nil }
        let bounds = cgPage.getBoxRect(.mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2.0, 2200 / max(bounds.width, bounds.height))
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.drawPDFPage(cgPage)
        return context.makeImage()
    }

    /// The lines of text Vision reads in a picture, with their boxes.
    static func recognizeLines(_ image: CGImage) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { Line(text: $0.string, box: observation.boundingBox) }
        }
    }

    /// A copy of the page with the lines written invisibly over it: the page's own drawing is replayed unchanged,
    /// then each line in a font as high as its box, stretched to its width. Its rotation is kept.
    static func page(_ page: PDFPage, with lines: [Line]) -> PDFPage? {
        guard let cgPage = page.pageRef else { return nil }
        var box = cgPage.getBoxRect(.mediaBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.drawPDFPage(cgPage)
        for line in lines {
            let rect = CGRect(
                x: box.minX + line.box.minX * box.width, y: box.minY + line.box.minY * box.height,
                width: line.box.width * box.width, height: line.box.height * box.height
            )
            guard rect.width > 1, rect.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height * 0.8), nil)
            let text = NSAttributedString(string: line.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(text)
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.2)
            context.scaleBy(x: rect.width / width, y: 1)
            context.textPosition = .zero
            // Invisible: in the file and found by every search, never drawn.
            context.setTextDrawingMode(.invisible)
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        guard let layered = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        layered.rotation = page.rotation
        // The page's other boxes as they were: what is shown and printed of it does not change.
        for box in [PDFDisplayBox.cropBox, .bleedBox, .trimBox, .artBox] {
            layered.setBounds(page.bounds(for: box), for: box)
        }
        return layered
    }
}

/// Page work on a PDF in memory: turn, move, delete and add pages, and put several PDFs together. The editors work
/// on a copy and `DocumentFiles.save` writes it back.
enum PDFPages {
    /// Turns the pages by a quarter turn or more (positive is clockwise).
    static func rotate(_ document: PDFDocument, pages: [Int], by degrees: Int) {
        for index in Set(pages) {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
    }

    /// Takes the pages out; the last page is never taken (a document without pages is no document). Returns how
    /// many went.
    @discardableResult
    static func delete(_ document: PDFDocument, pages: [Int]) -> Int {
        var removed = 0
        for index in Set(pages).sorted(by: >) where index < document.pageCount && document.pageCount > 1 {
            document.removePage(at: index)
            removed += 1
        }
        return removed
    }

    /// Moves the pages at `offsets` before the page at `destination`, as a list moves its rows.
    static func move(_ document: PDFDocument, from offsets: IndexSet, to destination: Int) {
        var order = Array(0..<document.pageCount)
        let moving = offsets.filter { $0 < order.count }
        guard !moving.isEmpty else { return }
        let items = moving.map { order[$0] }
        let before = moving.filter { $0 < destination }.count
        for index in moving.sorted(by: >) { order.remove(at: index) }
        order.insert(contentsOf: items, at: min(max(0, destination - before), order.count))
        reorder(document, to: order)
    }

    /// Puts the pages in the order given (old indices).
    static func reorder(_ document: PDFDocument, to order: [Int]) {
        let pages = order.compactMap { document.page(at: $0) }
        guard pages.count == document.pageCount, Set(order).count == order.count else { return }
        for index in (0..<document.pageCount).reversed() { document.removePage(at: index) }
        for (index, page) in pages.enumerated() { document.insert(page, at: index) }
    }

    /// Adds copies of the pages of `other` at the end.
    static func append(_ document: PDFDocument, contentsOf other: PDFDocument) {
        for index in 0..<other.pageCount {
            guard let page = other.page(at: index)?.copy() as? PDFPage else { continue }
            document.insert(page, at: document.pageCount)
        }
    }

    /// A new document of copies of the pages, in their order in the document.
    static func extract(_ document: PDFDocument, pages: [Int]) -> PDFDocument {
        let result = PDFDocument()
        for index in Set(pages).sorted() where index < document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            result.insert(page, at: result.pageCount)
        }
        return result
    }

    /// How a PDF is split: the chosen pages into one new document, or every page into one of its own.
    enum Split: Equatable {
        case pages([Int])
        case everyPage
    }

    /// The groups of pages that become new documents; the pages not in any stay in the original, which always
    /// keeps at least one (with "every page" its first). Empty when nothing can be split off.
    static func groups(for split: Split, pageCount: Int) -> [[Int]] {
        guard pageCount > 1 else { return [] }
        switch split {
        case .everyPage:
            return (1..<pageCount).map { [$0] }
        case .pages(let pages):
            let chosen = Set(pages).filter { $0 >= 0 && $0 < pageCount }.sorted()
            guard !chosen.isEmpty, chosen.count < pageCount else { return [] }
            return [chosen]
        }
    }

    /// "Pages 2–4", "Page 3", "Pages 1, 3, 5" for page indices (shown counting from 1).
    static func label(_ pages: [Int]) -> String {
        let numbers = Set(pages).sorted().map { $0 + 1 }
        guard let first = numbers.first, let last = numbers.last else { return "" }
        if numbers.count == 1 { return String(localized: "Page \(first)") }
        if last - first + 1 == numbers.count { return String(localized: "Pages \(first)–\(last)") }
        // Many pages here and there: the first few and how many, so a title stays short.
        if numbers.count > 4 {
            return String(localized: "Pages \(numbers.prefix(3).map(String.init).joined(separator: ", ")), … (\(numbers.count) pages)")
        }
        return String(localized: "Pages \(numbers.map(String.init).joined(separator: ", "))")
    }

    /// One document of all pages, in order.
    static func merged(_ documents: [PDFDocument]) -> PDFDocument {
        let result = PDFDocument()
        for document in documents { append(result, contentsOf: document) }
        return result
    }
}
