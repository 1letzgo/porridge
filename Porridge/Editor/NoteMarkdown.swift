import Foundation
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

extension NSAttributedString.Key {
    /// Kind of the paragraph: "h1", "h2", "h3", "quote", "bullet", "numbered", "checklist" or "code". Plain paragraphs have none.
    static let noteBlock = NSAttributedString.Key("PorridgeNoteBlock")
    /// Nesting level of a list paragraph (Int).
    static let noteIndent = NSAttributedString.Key("PorridgeNoteIndent")
    /// On the checkbox attachment: whether it is ticked.
    static let noteChecked = NSAttributedString.Key("PorridgeNoteChecked")
}

/// The note as rich text for the text view, and back to Markdown for storage. Markdown stays the format of
/// the note (sync, search, tags, summaries); the text view only ever sees attributed text.
///
/// Every paragraph carries its kind as an attribute. Lists have their marker as text at the start of the
/// paragraph ("•" or "1." and a tab, then a hanging indent); a checklist line starts with a checkbox
/// attachment. The text view cannot keep a list in its typing attributes (it strips `NSTextList`), which is
/// why the markers are characters. Inline: bold and italic are font traits; `#tags` are colored for display.
enum NoteMarkdown {
    static let indentStep: CGFloat = 22
    /// Width of the marker column of a list (marker text, then the tab to the text).
    static let markerWidth: CGFloat = 24
    static let checkboxGap: CGFloat = 8
    /// The circle of a checklist line: 18 pt at the standard text size; on iOS it grows with the body text (up to
    /// 40 pt) like the text beside it.
    static var checkboxSize: CGFloat {
        #if os(macOS)
        18
        #else
        min(UIFontMetrics(forTextStyle: .body).scaledValue(for: 18), 40)
        #endif
    }

    // MARK: - Markdown → attributed

    /// Tables, images and dividers become one attachment character each (`NoteBlockAttachment`) that keeps its
    /// Markdown; lines in fenced code blocks are `code` paragraphs.
    static func attributed(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let segments = NoteRichText.scan(markdown)
        var counters: [Int: Int] = [:]
        for (i, segment) in segments.enumerated() {
            let isLast = i == segments.count - 1
            let block: NoteBlock
            switch segment {
            case .block(let rich, let source):
                _ = next(counters: &counters, kind: .paragraph, indent: 0)
                let paragraph = NSMutableAttributedString(attributedString: blockString(rich, source: source))
                if !isLast {
                    paragraph.append(NSAttributedString(string: "\n", attributes: paragraph.attributes(at: 0, effectiveRange: nil).filter { $0.key != .attachment && $0.key != .noteRawBlock }))
                }
                result.append(paragraph)
                continue
            case .line(let line, let code):
                block = code ? NoteBlock(kind: .code, text: line) : NoteBlock.parse(line: line)
            }
            let number = next(counters: &counters, kind: block.kind, indent: block.indent)
            let paragraph = NSMutableAttributedString(attributedString: inline(block.text, kind: block.kind))
            if !isLast { paragraph.append(NSAttributedString(string: "\n")) }
            paragraph.insert(marker(kind: block.kind, number: number), at: 0)
            let whole = NSRange(location: 0, length: paragraph.length)
            paragraph.addAttributes(paragraphAttributes(kind: block.kind, indent: block.indent), range: whole)
            colorTags(in: paragraph, range: whole, kind: block.kind)
            result.append(paragraph)
        }
        return result
    }

    /// Numbering: items at a level count on; a paragraph that is no numbered item at that level ends them.
    static func next(counters: inout [Int: Int], kind: NoteBlock.Kind, indent: Int) -> Int {
        if kind == .numbered {
            counters = counters.filter { $0.key <= indent }
            counters[indent, default: 0] += 1
            return counters[indent]!
        }
        if kind.isList {
            counters = counters.filter { $0.key < indent }
        } else {
            counters = [:]
        }
        return 0
    }

    /// What stands in front of the text of a paragraph: the list marker, the checkbox, or nothing.
    static func marker(kind: NoteBlock.Kind, number: Int) -> NSAttributedString {
        switch kind {
        case .bullet: markerText("•\t")
        case .numbered: markerText("\(max(1, number)).\t")
        case .checklist(let checked): checkbox(checked: checked)
        default: NSAttributedString()
        }
    }

    private static func markerText(_ text: String) -> NSAttributedString {
        var attributes = inlineAttributes(kind: .paragraph, bold: false, italic: false)
        attributes[.foregroundColor] = secondaryColor
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// How many characters at the start of a paragraph are its marker.
    static func markerLength(in attributed: NSAttributedString, paragraph: NSRange) -> Int {
        guard paragraph.length > 0 else { return 0 }
        let (kind, _) = paragraphKind(in: attributed, at: paragraph.location)
        switch kind {
        case .bullet, .numbered:
            let text = (attributed.string as NSString).substring(with: paragraph)
            guard let tab = text.firstIndex(of: "\t") else { return 0 }
            // Only a real marker ("•" or "12."): a line pasted into a list has none, and cutting up to its
            // first tab would take text away.
            let head = text[..<tab]
            let isNumber = head.count > 1 && head.last == "." && head.dropLast().allSatisfy(\.isNumber)
            guard head == "•" || isNumber else { return 0 }
            return (text[...tab] as NSString).length
        case .checklist:
            let isBox = attributed.attribute(.attachment, at: paragraph.location, effectiveRange: nil) != nil
                && attributed.attribute(.noteEntryLink, at: paragraph.location, effectiveRange: nil) == nil
            return isBox ? 1 : 0
        default:
            return 0
        }
    }

    /// Bold (`**`) and italic (`*`) of one line as fonts; everything else stays as typed.
    static func inline(_ text: String, kind: NoteBlock.Kind) -> NSAttributedString {
        // Code is shown as typed.
        if kind == .code { return NSAttributedString(string: text, attributes: inlineAttributes(kind: kind, bold: false, italic: false)) }
        let result = NSMutableAttributedString()
        // Links to entries are pieces of their own (their labels hold no marks); the text between them is taken
        // apart into characters piece by piece, by UTF-16 ranges, so nothing in it can be taken for a link.
        enum Piece { case character(Character), link(EntryLinks.Link) }
        let ns = text as NSString
        var pieces: [Piece] = []
        var texts: [String] = []
        var location = 0
        for link in EntryLinks.links(in: text) {
            let between = ns.substring(with: NSRange(location: location, length: link.range.location - location))
            texts.append(between)
            pieces += between.map(Piece.character)
            pieces.append(.link(link))
            location = link.range.location + link.range.length
        }
        let rest = ns.substring(from: location)
        texts.append(rest)
        pieces += rest.map(Piece.character)
        // Marks are only marks when they come in pairs; otherwise the stars are text. No pair runs across a link.
        let plain = texts.joined(separator: "\n")
        let strong = occurrences(of: "**", in: plain)
        let emphasis = occurrences(of: "*", in: plain) - 2 * strong
        let strongPairs = strong % 2 == 0 && strong > 0
        let emphasisPairs = emphasis % 2 == 0 && emphasis > 0
        var bold = false, italic = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            result.append(NSAttributedString(string: run, attributes: inlineAttributes(kind: kind, bold: bold, italic: italic)))
            run = ""
        }
        func isStar(_ index: Int) -> Bool {
            guard index < pieces.count, case .character("*") = pieces[index] else { return false }
            return true
        }
        var i = 0
        while i < pieces.count {
            switch pieces[i] {
            case .link(let link):
                flush()
                result.append(entryLinkString(id: link.id, label: link.label, attributes: inlineAttributes(kind: kind, bold: bold, italic: italic)))
                i += 1
            case .character(let character):
                if strongPairs, isStar(i), isStar(i + 1) {
                    flush(); bold.toggle(); i += 2
                } else if emphasisPairs, character == "*" {
                    flush(); italic.toggle(); i += 1
                } else {
                    run.append(character); i += 1
                }
            }
        }
        flush()
        return result
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - Attributed → Markdown

    /// - Parameter openEnded: the text is cut off at the cursor: bold or italic running at its end is not closed,
    ///   so the length of the result is the place of the cursor in the Markdown of the whole text.
    static func markdown(from attributed: NSAttributedString, openEnded: Bool = false) -> String {
        let string = attributed.string as NSString
        var lines: [String] = []
        var counters: [Int: Int] = [:]
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            var content = range
            if string.character(at: range.location + range.length - 1) == 0x0A { content.length -= 1 }
            let (kind, indent) = paragraphKind(in: attributed, at: range.location)
            let isLast = range.location + range.length >= string.length
            if let blockLines = blockLines(in: attributed, content: content, closes: !(openEnded && isLast)) {
                // A table, image or divider: its source, and any text typed beside it on lines of their own.
                _ = next(counters: &counters, kind: .paragraph, indent: 0)
                lines.append(contentsOf: blockLines)
                location = range.location + range.length
                continue
            }
            let marker = markerLength(in: attributed, paragraph: range)
            let text = NSRange(location: content.location + marker, length: max(0, content.length - marker))
            let body = kind == .code
                ? codeText(attributed, range: text)
                : inlineMarkdown(attributed, range: text, kind: kind, closes: !(openEnded && isLast))
            let block = NoteBlock(kind: kind, indent: indent, text: body)
            let number = next(counters: &counters, kind: kind, indent: indent)
            lines.append(block.mark(number: number) + block.text)
            location = range.location + range.length
        }
        // A text that ends with a newline has one more, empty, paragraph (no characters, so no kind).
        if string.length == 0 || string.character(at: string.length - 1) == 0x0A { lines.append("") }
        return lines.joined(separator: "\n")
    }

    /// The Markdown lines of a paragraph that holds blocks (nil when it has none): each block's source, and the
    /// text before or after it as plain lines.
    static func blockLines(in attributed: NSAttributedString, content: NSRange, closes: Bool = true) -> [String]? {
        guard content.length > 0 else { return nil }
        var hasBlock = false
        attributed.enumerateAttribute(.noteRawBlock, in: content, options: []) { value, _, stop in
            if value is String { hasBlock = true; stop.pointee = true }
        }
        guard hasBlock else { return nil }
        var lines: [String] = []
        attributed.enumerateAttribute(.noteRawBlock, in: content, options: []) { value, range, _ in
            if let source = value as? String {
                // Two equal blocks side by side are one run: one source per character.
                for _ in 0..<range.length { lines.append(source) }
            } else {
                let text = inlineMarkdown(attributed, range: range, kind: .paragraph, closes: closes)
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
            }
        }
        return lines
    }

    /// The text of a code line as typed (no marks; attachments left out).
    static func codeText(_ attributed: NSAttributedString, range: NSRange) -> String {
        var out = ""
        attributed.enumerateAttribute(.attachment, in: range, options: []) { value, runRange, _ in
            if value is EntryLinkAttachment {
                for offset in 0..<runRange.length { out += entryLinkMarkdown(in: attributed, at: runRange.location + offset) ?? "" }
            }
            guard value == nil else { return }
            out += (attributed.string as NSString).substring(with: runRange)
        }
        return out
    }

    /// Kind and indent of the paragraph that starts at `location`.
    static func paragraphKind(in attributed: NSAttributedString, at location: Int) -> (NoteBlock.Kind, Int) {
        guard location < attributed.length else { return (.paragraph, 0) }
        return kind(of: attributed.attributes(at: location, effectiveRange: nil))
    }

    static func kind(of attributes: [NSAttributedString.Key: Any]) -> (NoteBlock.Kind, Int) {
        let indent = attributes[.noteIndent] as? Int ?? 0
        switch attributes[.noteBlock] as? String {
        case "h1": return (.heading(1), 0)
        case "h2": return (.heading(2), 0)
        case "h3": return (.heading(3), 0)
        case "quote": return (.quote, 0)
        case "bullet": return (.bullet, indent)
        case "numbered": return (.numbered, indent)
        case "checklist": return (.checklist(checked: attributes[.noteChecked] as? Bool ?? false), indent)
        case "code": return (.code, 0)
        default: return (.paragraph, 0)
        }
    }

    /// The text of a paragraph with `**` and `*` around bold and italic runs.
    static func inlineMarkdown(_ attributed: NSAttributedString, range: NSRange, kind: NoteBlock.Kind, closes: Bool = true) -> String {
        var out = ""
        var bold = false, italic = false
        var headingBold = false
        if case .heading = kind { headingBold = true }
        attributed.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            let isLink = attributes[.noteEntryLink] != nil
            guard attributes[.attachment] == nil || isLink else { return }
            let text = isLink
                ? (0..<runRange.length).compactMap { entryLinkMarkdown(in: attributed, at: runRange.location + $0) }.joined()
                : (attributed.string as NSString).substring(with: runRange)
            let font = attributes[.font] as? PlatformFont
            let runBold = !headingBold && (font.map(isBold) ?? false)
            let runItalic = font.map(isItalic) ?? false
            // Marks around whitespace are not marks in Markdown: open them after the space, close before it.
            if text.allSatisfy(\.isWhitespace) {
                if italic { out += "*"; italic = false }
                if bold { out += "**"; bold = false }
                out += text
                return
            }
            // Italic sits inside bold. Only what changes is closed and opened: italic words in a bold sentence
            // are "**a *b* c**", not bold closed and opened again around them.
            if bold != runBold {
                if italic { out += "*"; italic = false }
                out += "**"
                bold = runBold
            }
            if italic != runItalic {
                out += "*"
                italic = runItalic
            }
            out += text
        }
        if closes {
            if italic { out += "*" }
            if bold { out += "**" }
        }
        return out
    }

    // MARK: - Attributes

    static func paragraphAttributes(kind: NoteBlock.Kind, indent: Int) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: paragraphStyle(kind: kind, indent: indent)]
        switch kind {
        case .heading(let level): attributes[.noteBlock] = "h\(level)"
        case .quote: attributes[.noteBlock] = "quote"
        case .bullet: attributes[.noteBlock] = "bullet"
        case .numbered: attributes[.noteBlock] = "numbered"
        case .checklist: attributes[.noteBlock] = "checklist"
        case .code: attributes[.noteBlock] = "code"
        case .paragraph: break
        }
        if kind.isList { attributes[.noteIndent] = indent }
        return attributes
    }

    /// The paragraph-level attributes a plain paragraph must not carry.
    static let blockKeys: [NSAttributedString.Key] = [.noteBlock, .noteIndent]

    static func paragraphStyle(kind: NoteBlock.Kind, indent: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 4
        style.lineSpacing = 2
        switch kind {
        case .heading: style.paragraphSpacingBefore = 12
        case .bullet, .numbered:
            let head = indentStep * CGFloat(indent)
            style.firstLineHeadIndent = head
            style.headIndent = head + markerWidth
            style.tabStops = [NSTextTab(textAlignment: .left, location: head + markerWidth)]
            style.defaultTabInterval = markerWidth
        case .checklist:
            let head = indentStep * CGFloat(indent)
            style.firstLineHeadIndent = head
            style.headIndent = head + checkboxSize + checkboxGap
        case .quote:
            style.firstLineHeadIndent = 14
            style.headIndent = 14
        case .code:
            style.paragraphSpacing = 0
            style.lineSpacing = 1
            style.firstLineHeadIndent = 10
            style.headIndent = 10
        case .paragraph: break
        }
        return style
    }

    /// Font and color of a run. Quotes and code get no `.backgroundColor`: their bar and tint are drawn per
    /// paragraph (`NoteLayoutFragment`), across the whole width and every line.
    static func inlineAttributes(kind: NoteBlock.Kind, bold: Bool, italic: Bool) -> [NSAttributedString.Key: Any] {
        [.font: font(kind: kind, bold: bold, italic: italic), .foregroundColor: textColor(kind: kind)]
    }

    /// The bar beside a quote.
    static var quoteBarColor: PlatformColor {
        #if os(macOS)
        .tertiaryLabelColor
        #else
        .tertiaryLabel
        #endif
    }

    /// The tint behind a code block.
    /// Opaque (light and dark), so the tints of two code lines may overlap by a point without a darker seam.
    static var codeBackground: PlatformColor {
        #if os(macOS)
        NSColor(name: "PorridgeCodeBackground") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.94, alpha: 1)
        }
        #else
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : UIColor(white: 0.94, alpha: 1) }
        #endif
    }

    static func textColor(kind: NoteBlock.Kind) -> PlatformColor {
        kind == .quote ? secondaryColor : primaryColor
    }

    static var primaryColor: PlatformColor {
        #if os(macOS)
        .labelColor
        #else
        .label
        #endif
    }

    static var secondaryColor: PlatformColor {
        #if os(macOS)
        .secondaryLabelColor
        #else
        .secondaryLabel
        #endif
    }

    static var tagColor: PlatformColor {
        #if os(macOS)
        NSColor(named: "AccentColor") ?? .controlAccentColor
        #else
        UIColor(named: "AccentColor") ?? .tintColor
        #endif
    }

    /// `#tags` in the accent color; the rest in the color of the kind. `range` is the text after the marker.
    static func colorTags(in text: NSMutableAttributedString, range: NSRange, kind: NoteBlock.Kind) {
        guard range.length > 0 else { return }
        let line = (text.string as NSString).substring(with: range)
        // The fences of a code block ("```") are dimmed: they frame the code, they are not part of it.
        let isFence = kind == .code && NoteRichText.isFence(line.trimmingCharacters(in: .newlines))
        text.addAttribute(.foregroundColor, value: isFence ? secondaryColor : textColor(kind: kind), range: range)
        // In code a "#" is no tag (`NoteText.tags` skips fenced blocks too).
        guard kind != .code else { return }
        for tag in NoteText.tagRanges(in: line) {
            text.addAttribute(.foregroundColor, value: tagColor, range: NSRange(location: range.location + tag.location, length: tag.length))
        }
    }

    // MARK: Fonts

    static func baseFont(kind: NoteBlock.Kind) -> PlatformFont {
        switch kind {
        case .heading(1): PlatformFont.preferredFont(forTextStyle: .title1)
        case .heading(2): PlatformFont.preferredFont(forTextStyle: .title2)
        case .heading: PlatformFont.preferredFont(forTextStyle: .title3)
        case .code: PlatformFont.monospacedSystemFont(ofSize: PlatformFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        default: PlatformFont.preferredFont(forTextStyle: .body)
        }
    }

    static func font(kind: NoteBlock.Kind, bold: Bool, italic: Bool) -> PlatformFont {
        if kind == .code { return baseFont(kind: .code) }
        var heading = false
        if case .heading = kind { heading = true }
        return withTraits(baseFont(kind: kind), bold: bold || heading, italic: italic)
    }

    static func withTraits(_ font: PlatformFont, bold: Bool, italic: Bool) -> PlatformFont {
        #if os(macOS)
        var result = font
        let manager = NSFontManager.shared
        result = manager.convert(result, toNotHaveTrait: [.boldFontMask, .italicFontMask])
        if bold { result = manager.convert(result, toHaveTrait: .boldFontMask) }
        if italic { result = manager.convert(result, toHaveTrait: .italicFontMask) }
        return result
        #else
        var traits = font.fontDescriptor.symbolicTraits
        traits.remove([.traitBold, .traitItalic])
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #endif
    }

    static func isBold(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        font.fontDescriptor.symbolicTraits.contains(.bold)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    static func isItalic(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        font.fontDescriptor.symbolicTraits.contains(.italic)
        #else
        font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    // MARK: Checkbox

    static func checkbox(checked: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = checkboxImage(checked: checked)
        // Sits on the baseline of the body text, a touch below so it centers on the x-height.
        // The image has the gap after the box built in: a kern on an attachment is ignored by TextKit 2.
        attachment.bounds = CGRect(x: 0, y: -3 * checkboxSize / 18, width: checkboxSize + checkboxGap, height: checkboxSize)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes([
            .noteChecked: checked,
            .font: baseFont(kind: .paragraph),
        ], range: NSRange(location: 0, length: result.length))
        return result
    }

    static func checkboxImage(checked: Bool) -> PlatformImage? {
        let name = checked ? "checkmark.circle.fill" : "circle"
        #if os(macOS)
        let configuration = NSImage.SymbolConfiguration(pointSize: checkboxSize - 2, weight: .regular)
            .applying(.init(paletteColors: [checked ? tagColor : .secondaryLabelColor]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: checked ? "Checked" : "Not checked")?
            .withSymbolConfiguration(configuration) else { return nil }
        return NSImage(size: NSSize(width: checkboxSize + checkboxGap, height: checkboxSize), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: 0, width: checkboxSize, height: checkboxSize))
            return true
        }
        #else
        let configuration = UIImage.SymbolConfiguration(pointSize: checkboxSize - 2, weight: .regular)
        let symbol = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(checked ? tagColor : .secondaryLabel, renderingMode: .alwaysOriginal)
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: checkboxSize + checkboxGap, height: checkboxSize), format: UIGraphicsImageRendererFormat(for: traits))
            let image = renderer.image { _ in
                traits.performAsCurrent { symbol?.draw(in: CGRect(x: 0, y: 0, width: checkboxSize, height: checkboxSize)) }
            }
            asset.register(image, with: traits)
        }
        return asset.image(with: .current)
        #endif
    }
}
