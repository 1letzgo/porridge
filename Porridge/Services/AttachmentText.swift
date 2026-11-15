import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Reads the text out of attachments, on the device: printed text in images (screenshots, photos of pages), the
/// text of PDFs (scanned pages are read like images), office documents (`DocumentText`) and plain text files. The text becomes the note's `pageText`,
/// so it is searched and summarized like a saved page.
enum AttachmentText {
    /// Longer than any model reads and any search needs.
    static let limit = 200_000
    /// Scanned pages read as images, at most; text PDFs are read whole.
    static let scannedPages = 30

    /// The text of all files, in order; a PDF's pages are marked ("Page 3") so a search hit says where it is.
    static func read(_ files: [(url: URL, attachment: Attachment)]) async -> String {
        await Task.detached(priority: .userInitiated) {
            var parts: [String] = []
            var length = 0
            for file in files where length < limit {
                let text: String
                switch file.attachment.kind {
                case .image: text = recognize(imageAt: file.url)
                case .pdf: text = pdfText(file.url)
                case .file: text = plainText(file.url)
                }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { continue }
                // Several files: each starts with its name.
                parts.append(files.count > 1 ? "\(file.attachment.name)\n\(clean)" : clean)
                length += clean.count
            }
            return String(parts.joined(separator: "\n\n").prefix(limit))
        }.value
    }

    static func pdfText(_ url: URL) -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var pages: [String] = []
        var scanned = 0
        var length = 0
        for index in 0..<document.pageCount where length < limit {
            guard let page = document.page(at: index) else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty, scanned < scannedPages {
                scanned += 1
                text = recognize(page)
            }
            guard !text.isEmpty else { continue }
            pages.append(document.pageCount > 1 ? "Page \(index + 1)\n\(text)" : text)
            length += text.count
        }
        return pages.joined(separator: "\n\n")
    }

    private static func recognize(_ page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return "" }
        // About 150 dpi: enough for print, small enough for memory.
        let scale = min(2.0, 2200 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return "" }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage().map(recognize) ?? ""
    }

    static func recognize(imageAt url: URL) -> String {
        // Downsampled while decoding: a 48 MP photo would not fit otherwise.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return "" }
        return recognize(image)
    }

    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func plainText(_ url: URL) -> String {
        // Word, OpenDocument and rich text have their own reader.
        let document = DocumentText.read(url)
        if !document.isEmpty { return document }
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .text),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 2_000_000,
              let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
