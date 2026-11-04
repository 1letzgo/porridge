import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
private typealias ExportFont = UIFont
private typealias ExportColor = UIColor
#else
import AppKit
private typealias ExportFont = NSFont
private typealias ExportColor = NSColor
#endif

/// A meeting's summary and transcript as a text file or a formatted PDF. Holds plain values, so the file can be
/// made away from the main thread.
struct MeetingExport: Sendable {
    enum Format: String, CaseIterable, Hashable, Sendable {
        case text, pdf

        var title: String { self == .text ? "Text" : "PDF" }
    }

    struct Line: Sendable, Equatable {
        var time: String
        var speaker: String?
        var text: String
    }

    let title: String
    let date: String
    /// Only what was chosen.
    let summary: String?
    let transcript: [Line]

    init(title: String, date: String, summary: String?, transcript: [Line]) {
        self.title = title
        self.date = date
        self.summary = summary
        self.transcript = transcript
    }

    @MainActor
    init(note: Note, includeSummary: Bool, includeTranscript: Bool) {
        let speakers = note.speakers
        self.init(
            title: note.displayTitle,
            date: note.createdAt.formatted(date: .long, time: .shortened),
            summary: includeSummary ? note.summary : nil,
            transcript: includeTranscript ? note.segments.map { segment in
                Line(
                    time: segment.start.clockString,
                    speaker: segment.speakerId.flatMap { id in speakers.first { $0.id == id }?.name },
                    text: segment.text
                )
            } : []
        )
    }

    var isEmpty: Bool { (summary ?? "").isEmpty && transcript.isEmpty }

    /// Writes the file for sharing, named after the meeting.
    func write(_ format: Format) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let name = title.components(separatedBy: illegal).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let url = folder.appendingPathComponent(name.isEmpty ? "Meeting" : name).appendingPathExtension(format == .pdf ? "pdf" : "txt")
        switch format {
        case .text: try plainText.write(to: url, atomically: true, encoding: .utf8)
        case .pdf: try pdfData().write(to: url, options: .atomic)
        }
        return url
    }

    // MARK: - Text

    var plainText: String {
        var parts = [title, date]
        if let summary, !summary.isEmpty {
            parts.append("Summary\n\n" + Self.plain(summary))
        }
        if !transcript.isEmpty {
            parts.append("Transcript\n\n" + transcript.map { line in
                "[\(line.time)] " + (line.speaker.map { $0 + ": " } ?? "") + line.text
            }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// The summary without its Markdown marks; lists stay lists.
    private static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            let text = line.hasPrefix("#") ? line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) : line
            return text.replacingOccurrences(of: "**", with: "")
        }.joined(separator: "\n")
    }

    // MARK: - PDF

    private static let navy = ExportColor(red: 0x1F / 255, green: 0x36 / 255, blue: 0x67 / 255, alpha: 1)
    private static let body = ExportColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1)
    private static let muted = ExportColor(red: 0.45, green: 0.45, blue: 0.48, alpha: 1)

    /// A4 pages with the title on the first and page numbers on all.
    func pdfData() -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let textRect = page.insetBy(dx: 56, dy: 56)
        let data = NSMutableData()
        var box = page
        let info = [kCGPDFContextTitle: title] as CFDictionary
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return Data() }

        let content = attributedContent()
        let setter = CTFramesetterCreateWithAttributedString(content)
        var position = 0
        var number = 1
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: position, length: 0), CGPath(rect: textRect, transform: nil), nil)
            CTFrameDraw(frame, context)
            drawPageNumber(number, on: context, width: page.width)
            context.endPDFPage()
            let shown = CTFrameGetVisibleStringRange(frame).length
            if shown == 0 { break }
            position += shown
            number += 1
        } while position < content.length
        context.closePDF()
        return data as Data
    }

    private func drawPageNumber(_ number: Int, on context: CGContext, width: CGFloat) {
        let text = NSAttributedString(string: "\(number)", attributes: [.font: ExportFont.systemFont(ofSize: 9), .foregroundColor: Self.muted])
        let line = CTLineCreateWithAttributedString(text)
        context.textPosition = CGPoint(x: width / 2 - CTLineGetTypographicBounds(line, nil, nil, nil) / 2, y: 30)
        CTLineDraw(line, context)
    }

    private func attributedContent() -> NSAttributedString {
        let out = NSMutableAttributedString()
        add(title, to: out, font: .systemFont(ofSize: 22, weight: .bold), color: Self.navy, after: 4)
        add(date, to: out, font: .systemFont(ofSize: 11), color: Self.muted, after: 14)
        if let summary, !summary.isEmpty {
            add("Summary", to: out, font: .systemFont(ofSize: 15, weight: .bold), color: Self.navy, before: 6, after: 8)
            addSummary(summary, to: out)
        }
        if !transcript.isEmpty {
            add("Transcript", to: out, font: .systemFont(ofSize: 15, weight: .bold), color: Self.navy, before: 12, after: 8)
            for line in transcript { addTranscript(line, to: out) }
        }
        return out
    }

    private func addSummary(_ markdown: String, to out: NSMutableAttributedString) {
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let heading = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                add(heading.replacingOccurrences(of: "**", with: ""), to: out, font: .systemFont(ofSize: 12.5, weight: .semibold), color: Self.navy, before: 6, after: 4)
            } else if let (mark, text) = Self.listItem(line) {
                addParagraph(Self.bold(mark + "\t" + text), to: out, indent: 16, after: 3)
            } else {
                addParagraph(Self.bold(line), to: out, indent: 0, after: 5)
            }
        }
    }

    /// The mark to print and the text of a list line, nil for a paragraph.
    private static func listItem(_ line: String) -> (String, String)? {
        for (prefix, mark) in [("- [ ] ", "☐"), ("- [x] ", "☑"), ("- [X] ", "☑"), ("- ", "•"), ("* ", "•"), ("• ", "•")] where line.hasPrefix(prefix) {
            return (mark, String(line.dropFirst(prefix.count)))
        }
        return nil
    }

    /// `**bold**` becomes bold; the rest is body text.
    private static func bold(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, piece) in text.components(separatedBy: "**").enumerated() where !piece.isEmpty {
            out.append(NSAttributedString(string: piece, attributes: [
                .font: ExportFont.systemFont(ofSize: 11, weight: index % 2 == 1 ? .semibold : .regular),
                .foregroundColor: body,
            ]))
        }
        return out
    }

    private func addTranscript(_ line: Line, to out: NSMutableAttributedString) {
        let text = NSMutableAttributedString(string: line.time + "  ", attributes: [.font: ExportFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: Self.muted])
        if let speaker = line.speaker {
            text.append(NSAttributedString(string: speaker + ": ", attributes: [.font: ExportFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Self.navy]))
        }
        text.append(NSAttributedString(string: line.text, attributes: [.font: ExportFont.systemFont(ofSize: 11), .foregroundColor: Self.body]))
        addParagraph(text, to: out, indent: 0, after: 5)
    }

    private func add(_ text: String, to out: NSMutableAttributedString, font: ExportFont, color: ExportColor, before: CGFloat = 0, after: CGFloat) {
        let piece = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        addParagraph(piece, to: out, indent: 0, before: before, after: after)
    }

    private func addParagraph(_ text: NSAttributedString, to out: NSMutableAttributedString, indent: CGFloat, before: CGFloat = 0, after: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineSpacing = 2
        if indent > 0 {
            style.headIndent = indent
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        }
        let piece = NSMutableAttributedString(attributedString: text)
        piece.append(NSAttributedString(string: "\n"))
        piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
        out.append(piece)
    }
}
