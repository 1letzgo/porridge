import AppKit

extension NSAttributedString.Key {
    /// On the box of a task line of a summary: the line's index in the Markdown.
    static let summaryTaskLine = NSAttributedString.Key("PorridgeSummaryTaskLine")
}

/// Markdown of summaries and chat answers as read-only text: headings in the accent color, bullets, task lines
/// with green boxes (a click ticks them) and paragraphs; inline bold, italic, code and links. Selectable, so it
/// can be copied.
final class SummaryTextView: NSTextView {
    /// Called with the line index when a task's box is clicked; nil shows the boxes without a click.
    var onToggleTask: ((Int) -> Void)?
    /// Whether a task line (its raw text) became a to-do: it wears the to-do symbol at its end.
    var isTakenTask: ((String) -> Bool)?

    private(set) var markdown = ""

    convenience init() {
        self.init(usingTextLayoutManager: true)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        translatesAutoresizingMaskIntoConstraints = false
        linkTextAttributes = [.foregroundColor: NSColor.brandSkyText, .cursor: NSCursor.pointingHand]
        delegate = self
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = textLayoutManager else { return super.intrinsicContentSize }
        manager.ensureLayout(for: manager.documentRange)
        var height: CGFloat = 0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
            height = fragment.layoutFragmentFrame.maxY
            return false
        }
        _ = container
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height) + 4)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    func show(_ markdown: String) {
        self.markdown = markdown
        textStorage?.setAttributedString(Self.render(markdown, interactive: onToggleTask != nil, isTaken: isTakenTask))
        invalidateIntrinsicContentSize()
        setAccessibilityValue(markdown)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let onToggleTask, let storage = textStorage, storage.length > 0 {
            for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
                if let line = storage.attribute(.summaryTaskLine, at: candidate, effectiveRange: nil) as? Int {
                    onToggleTask(line)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: Rendering

    static func render(_ markdown: String, interactive: Bool = false, isTaken: ((String) -> Bool)? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NSFont.preferredFont(forTextStyle: .body)
        let lines = markdown.components(separatedBy: "\n")
        var first = true
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let paragraph = NSMutableAttributedString()
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            style.lineSpacing = 1
            // "## Title" is a heading; "#budget #q3" is a line of tags.
            let marks = line.prefix(while: { $0 == "#" })
            if !marks.isEmpty, marks.count <= 6, line.dropFirst(marks.count).first?.isWhitespace == true {
                let text = line.dropFirst(marks.count).trimmingCharacters(in: .whitespaces)
                paragraph.append(inline(text, font: .systemFont(ofSize: body.pointSize + 1, weight: .semibold), color: .brandSkyText))
                style.paragraphSpacingBefore = first ? 0 : 10
            } else if let task = taskLine(line) {
                let box = NSTextAttachment()
                let symbol = NSImage.symbol(task.done ? "checkmark.square.fill" : "square", size: body.pointSize + 1, weight: .medium)
                box.image = symbol.tinted(.brandTaskText)
                box.bounds = NSRect(x: 0, y: -3, width: symbol.size.width, height: symbol.size.height)
                let boxString = NSMutableAttributedString(attachment: box)
                if interactive {
                    boxString.addAttributes([.summaryTaskLine: index, .cursor: NSCursor.pointingHand], range: NSRange(location: 0, length: boxString.length))
                }
                paragraph.append(boxString)
                paragraph.append(NSAttributedString(string: "\t", attributes: [.font: body]))
                let text = inline(task.text, font: body, color: task.done ? .secondaryLabelColor : .labelColor)
                let mutable = NSMutableAttributedString(attributedString: text)
                if task.done {
                    mutable.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: NSColor.secondaryLabelColor], range: NSRange(location: 0, length: mutable.length))
                }
                paragraph.append(mutable)
                if let isTaken, isTaken(task.text) {
                    let mark = NSTextAttachment()
                    let image = NSImage.symbol("checklist", size: body.pointSize - 1, weight: .medium, label: "Taken over as a to-do").tinted(.brandTaskText)
                    mark.image = image
                    mark.bounds = NSRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
                    paragraph.append(NSAttributedString(string: "  ", attributes: [.font: body]))
                    let markString = NSMutableAttributedString(attachment: mark)
                    markString.addAttribute(.toolTip, value: "Taken over as a to-do", range: NSRange(location: 0, length: markString.length))
                    paragraph.append(markString)
                }
                style.headIndent = symbol.size.width + 8
                style.tabStops = [NSTextTab(textAlignment: .left, location: symbol.size.width + 8)]
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                paragraph.append(NSAttributedString(string: "•\t", attributes: [.font: NSFont.systemFont(ofSize: body.pointSize, weight: .semibold), .foregroundColor: NSColor.brandSkyText]))
                paragraph.append(inline(String(line.dropFirst(2)), font: body, color: .labelColor))
                style.headIndent = 16
                style.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
            } else {
                paragraph.append(inline(line, font: body, color: .labelColor))
            }
            if !first { result.append(NSAttributedString(string: "\n")) }
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            result.append(paragraph)
            first = false
        }
        return result
    }

    static func taskLine(_ line: String) -> (text: String, done: Bool)? {
        for (prefix, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false), ("* [x] ", true)] where line.hasPrefix(prefix) {
            return (String(line.dropFirst(prefix.count)), done)
        }
        return nil
    }

    /// Inline Markdown (bold, italic, code, links) of one line.
    static func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }
        let result = NSMutableAttributedString(string: String(parsed.characters), attributes: [.font: font, .foregroundColor: color])
        var location = 0
        for run in parsed.runs {
            let length = String(parsed[run.range].characters).utf16.count
            let range = NSRange(location: location, length: length)
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                    result.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: range)
                }
                if intent.contains(.code) {
                    result.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular), range: range)
                }
                if intent.contains(.strikethrough) {
                    result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            if let link = run.link { result.addAttribute(.link, value: link, range: range) }
            location += length
        }
        // `#tags` in the accent color, as in the editor.
        for tag in NoteText.tagRanges(in: result.string) {
            result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: tag)
        }
        return result
    }
}

extension SummaryTextView: NSTextViewDelegate {}
