import AppKit

/// The one meta line under an entry's title (`EntryMeta`), as on the iPhone: the facts in grey, the "✦ File into …"
/// suggestion of an Inbox entry, then only the values that are set, each a coloured word with a small symbol. A
/// click on a value opens Details (the inspector) at its section. It wraps to two lines at most; values that do not
/// fit become "+N". The Mac has no "Details" word at the end: the inspector button (⌥⌘I) stands for it.
final class MetaLineView: NSView, NSTextViewDelegate {
    /// Opens Details, at a section or at the top.
    var onOpen: ((EntryDetails.Section.Kind?) -> Void)?
    /// "✦ File into …" was clicked.
    var onFile: ((NoteFolder) -> Void)?

    private let textView = MetaTextView()
    private var facts = ""
    private var values: [EntryMeta.Value] = []
    private var suggestion: NoteFolder?
    private var renderedWidth: CGFloat = -1
    private var height: CGFloat = 16

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let bold = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let scheme = "porridge-meta"

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.delegate = self
        // The values keep their own colours; a link only changes the pointer.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.setAccessibilityLabel(String(localized: "Details of the Entry"))
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    func show(facts: String, values: [EntryMeta.Value], suggestion: NoteFolder?) {
        guard facts != self.facts || values != self.values || suggestion?.id != self.suggestion?.id || suggestion?.name != self.suggestion?.name else { return }
        self.facts = facts
        self.values = values
        self.suggestion = suggestion
        renderedWidth = -1
        needsLayout = true
        render()
    }

    override func layout() {
        super.layout()
        if bounds.width != renderedWidth { render() }
        textView.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderedWidth = -1
        render()
    }

    /// As many values as fit, so the line takes two lines at most.
    private func render() {
        let width = bounds.width
        guard width > 20 else { return }
        renderedWidth = width
        var shown = values.count
        var text = string(showing: shown)
        var measured = Self.measure(text, width: width)
        while measured.lines > 2, shown > 0 {
            shown -= 1
            text = string(showing: shown)
            measured = Self.measure(text, width: width)
        }
        textView.textStorage?.setAttributedString(text)
        let newHeight = ceil(measured.height)
        if newHeight != height {
            height = newHeight
            invalidateIntrinsicContentSize()
        }
        let hidden = values.count - shown
        setAccessibilityElement(false)
        textView.setAccessibilityValue(([facts] + values.map(\.text) + (hidden > 0 ? [String(localized: "\(hidden) more")] : [])).joined(separator: ", "))
    }

    private func string(showing count: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let gap = NSAttributedString(string: "   ", attributes: [.font: Self.font])
        result.append(NSAttributedString(string: facts.replacingOccurrences(of: " · ", with: "\u{00A0}·\u{2002}"), attributes: [
            .font: Self.font, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        if let suggestion {
            result.append(gap)
            let pill = NSTextAttachment()
            let image = Self.pill(String(localized: "File into \(suggestion.name)"))
            pill.image = image
            pill.bounds = NSRect(x: 0, y: -4, width: image.size.width, height: image.size.height)
            let run = NSMutableAttributedString(attachment: pill)
            run.addAttributes([.link: Self.link("file"), .toolTip: String(localized: "Suggested bowl")], range: NSRange(location: 0, length: run.length))
            result.append(run)
        }
        for value in values.prefix(count) {
            result.append(gap)
            result.append(Self.value(value))
        }
        let hidden = values.count - count
        if hidden > 0 {
            result.append(gap)
            result.append(NSAttributedString(string: "+\(hidden)", attributes: [
                .font: Self.bold, .foregroundColor: NSColor.secondaryLabelColor, .link: Self.link("more"),
                .toolTip: String(localized: "Show All in Details"),
            ]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Symbol and word of one value, kept together on one line.
    private static func value(_ value: EntryMeta.Value) -> NSAttributedString {
        let color = Self.color(value.tone)
        let run = NSMutableAttributedString()
        let symbol = value.symbol == EntryMeta.bowlImage ? "folder.fill" : value.symbol
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [color]))) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -1.5, width: image.size.width, height: image.size.height)
            run.append(NSAttributedString(attachment: attachment))
            run.append(NSAttributedString(string: "\u{00A0}"))
        }
        run.append(NSAttributedString(string: value.text.replacingOccurrences(of: " ", with: "\u{00A0}")))
        run.addAttributes([
            .font: Self.bold, .foregroundColor: color, .link: Self.link("section/" + value.section.rawValue),
            .toolTip: String(localized: "Show in Details"),
        ], range: NSRange(location: 0, length: run.length))
        return run
    }

    static func color(_ tone: EntryMeta.Value.Tone) -> NSColor {
        switch tone {
        case .bowl: .brandProjectText
        case .task: .brandTaskText
        case .danger: .brandDangerText
        case .navy: .brandNavy
        case .secondary: .secondaryLabelColor
        }
    }

    /// "✦ File into …" as a violet outlined capsule, drawn in the colours of the moment it is drawn in.
    private static func pill(_ title: String) -> NSImage {
        let text = NSAttributedString(string: title, attributes: [.font: Self.bold])
        let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        let textSize = text.size()
        let symbolWidth = symbol?.size.width ?? 0
        let size = NSSize(width: ceil(textSize.width + symbolWidth + 4 + 16), height: 18)
        return NSImage(size: size, flipped: false) { rect in
            let color = NSColor.brandProjectText
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
            color.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1
            path.stroke()
            var x: CGFloat = 8
            if let symbol {
                symbol.withSymbolConfiguration(.init(paletteColors: [color]))?
                    .draw(in: NSRect(x: x, y: (rect.height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
                x += symbol.size.width + 4
            }
            NSAttributedString(string: title, attributes: [.font: Self.bold, .foregroundColor: color])
                .draw(at: NSPoint(x: x, y: (rect.height - textSize.height) / 2))
            return true
        }
    }

    private static func link(_ path: String) -> URL {
        URL(string: "\(scheme)://\(path)")!
    }

    /// The lines and the height of the text at this width.
    private static func measure(_ text: NSAttributedString, width: CGFloat) -> (lines: Int, height: CGFloat) {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in lines += 1 }
        return (max(lines, 1), max(manager.usedRect(for: container).height, 15))
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == Self.scheme else { return false }
        switch url.host {
        case "file":
            if let suggestion { onFile?(suggestion) }
        case "more":
            onOpen?(nil)
        case "section":
            onOpen?(EntryDetails.Section.Kind(rawValue: url.lastPathComponent))
        default:
            break
        }
        return true
    }

    // Clicking a value must not leave a selection behind.
    func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
        new.length == 0 ? NSRange(location: 0, length: 0) : new
    }

    #if DEBUG
    /// The line's text, for the debug driver.
    var debugText: String { textView.string }
    #endif
}

/// The text of the meta line: no focus ring, and it hands the first click to its links.
private final class MetaTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
