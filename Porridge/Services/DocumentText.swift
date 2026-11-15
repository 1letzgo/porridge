import Compression
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Reads the text out of office documents, on the device: Word (.docx, and the older .doc), OpenDocument (.odt)
/// and rich text (.rtf). Enough for searching and summarizing; layout, pictures and tables' shape are left behind.
enum DocumentText {
    /// Larger files are not read: they would be held in memory whole.
    static let maxBytes = 40_000_000

    /// The text of the document, or "" when it is not one of the kinds read here.
    static func read(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        guard ["docx", "docm", "dotx", "odt", "doc", "dot", "rtf"].contains(ext),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < maxBytes,
              let data = try? Data(contentsOf: url) else { return "" }
        switch ext {
        case "docx", "docm", "dotx": return wordXMLText(zipEntry("word/document.xml", in: data))
        case "odt": return openDocumentText(zipEntry("content.xml", in: data))
        case "rtf": return richText(data)
        default: return wordBinaryText(data)
        }
    }

    // MARK: Word (.docx) and OpenDocument (.odt): XML in a zip

    static func wordXMLText(_ xml: Data?) -> String {
        guard let xml, var text = String(data: xml, encoding: .utf8) else { return "" }
        text = text.replacingOccurrences(of: "</w:p>", with: "\n")
        text = text.replacingOccurrences(of: #"<w:(br|cr)\b[^>]*/>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<w:tab\b[^>]*/>"#, with: "\t", options: .regularExpression)
        return plain(text)
    }

    static func openDocumentText(_ xml: Data?) -> String {
        guard let xml, var text = String(data: xml, encoding: .utf8) else { return "" }
        text = text.replacingOccurrences(of: #"</text:(p|h)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<text:line-break\b[^>]*/>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<text:tab\b[^>]*/>"#, with: "\t", options: .regularExpression)
        return plain(text)
    }

    /// Takes the tags out and resolves the entities XML always knows.
    private static func plain(_ xml: String) -> String {
        var text = xml.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One file out of a zip archive, stored or deflated. Nil when it is not there or the archive is damaged.
    static func zipEntry(_ name: String, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { at + 2 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
        func u32(_ at: Int) -> Int { at + 4 <= bytes.count ? u16(at) | u16(at + 2) << 16 : 0 }
        // The end record is at the end, before at most a comment.
        guard bytes.count >= 22 else { return nil }
        var end = bytes.count - 22
        while end >= 0, u32(end) != 0x0605_4b50 { end -= 1 }
        guard end >= 0 else { return nil }
        var at = u32(end + 16)
        for _ in 0..<u16(end + 10) {
            guard at + 46 <= bytes.count, u32(at) == 0x0201_4b50 else { return nil }
            let method = u16(at + 10), packed = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), local = u32(at + 42)
            let entry = String(decoding: bytes[min(at + 46, bytes.count)..<min(at + 46 + nameLength, bytes.count)], as: UTF8.self)
            if entry == name {
                let start = local + 30 + u16(local + 26) + u16(local + 28)
                guard u32(local) == 0x0403_4b50, start + packed <= bytes.count, size < maxBytes else { return nil }
                let content = Array(bytes[start..<start + packed])
                if method == 0 { return Data(content) }
                guard method == 8, size > 0 else { return nil }
                var unpacked = [UInt8](repeating: 0, count: size)
                let written = compression_decode_buffer(&unpacked, size, content, packed, nil, COMPRESSION_ZLIB)
                return written == size ? Data(unpacked) : nil
            }
            at += 46 + nameLength + u16(at + 30) + u16(at + 32)
        }
        return nil
    }

    // MARK: Rich text

    static func richText(_ data: Data) -> String {
        let text = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        return (text?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Word 97–2003 (.doc)

    /// The text of an old Word file. The file keeps its text in one piece, as UTF-16 or as Windows Latin 1, between
    /// tables of formatting: the long runs of text are the document. Short ones (font names, properties) are left out.
    static func wordBinaryText(_ data: Data) -> String {
        let bytes = [UInt8](data)
        let wide = runs(count: bytes.count / 2, shortest: 24) { Int(bytes[$0 * 2]) | Int(bytes[$0 * 2 + 1]) << 8 }
        let narrow = runs(count: bytes.count, shortest: 48) { index in
            let byte = Int(bytes[index])
            // Windows Latin 1: 0x80–0x9F are quotes, dashes and the euro sign.
            return byte >= 0x80 && byte <= 0x9F ? Int(windowsLatin[byte - 0x80]) : byte
        }
        let text = wide.count >= narrow.count ? wide : narrow
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let windowsLatin: [UInt16] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ]

    /// The runs of text among `count` code units, joined by line breaks. A run is text when it is long enough, mostly
    /// letters and spaces, has words (spaces in it) and is not one sign over and over (filler between the tables).
    private static func runs(count: Int, shortest: Int, unit: (Int) -> Int) -> String {
        var result = ""
        var run = String.UnicodeScalarView()
        var letters = 0
        var spaces = 0
        var different = Set<Unicode.Scalar>()
        func flush() {
            if run.count >= shortest, letters * 10 >= run.count * 6, spaces * 40 >= run.count, different.count >= 8 {
                if !result.isEmpty { result += "\n" }
                result += String(run)
            }
            run = String.UnicodeScalarView()
            letters = 0
            spaces = 0
            different = []
        }
        for index in 0..<count {
            let code = unit(index)
            switch code {
            case 0x0D, 0x0B, 0x0C, 0x0A:
                // Paragraph, line and page ends.
                if !run.isEmpty { run.append("\n") }
            case 0x07, 0x09:
                // The end of a table cell, a tab.
                if !run.isEmpty { run.append("\t") }
            case 0x20...0x7E, 0xA0...0x24F, 0x2010...0x2026, 0x20AC, 0x2030, 0x2039, 0x203A, 0x2122, 0x0192, 0x02C6, 0x02DC:
                guard let scalar = Unicode.Scalar(code) else { flush(); continue }
                run.append(scalar)
                if scalar == " " { spaces += 1 }
                if scalar == " " || scalar.properties.isAlphabetic { letters += 1 }
                if different.count < 8 { different.insert(scalar) }
            default:
                flush()
            }
        }
        flush()
        return result
    }
}
