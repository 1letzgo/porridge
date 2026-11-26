import AppKit

/// The live transcript as chat bubbles (`TranscriptBubbles`): the user on the right, the others on the left, the
/// name where the speaker changes, text that may still change dimmed. Follows the newest text unless the user has
/// scrolled up; scrolling back to the end follows again. Shows `message` while there is nothing to show.
///
/// Its height never comes from its bubbles: the list scrolls inside whatever room it is given, and the window around
/// it keeps its size however many bubbles come (the document view is sized by hand, not by constraints to the clip
/// view, and the view has no intrinsic size and gives way to its neighbours).
final class LiveBubblesView: NSView {
    private let scroll = NSScrollView()
    private let document = FlippedDocumentView()
    private let stack = NSStackView()
    private let message = NSTextField.label(color: .secondaryLabelColor, lines: 0)
    private var rows: [LiveBubbleRow] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Frame based: its height is set from the bubbles in `layout`, and nothing ties it to the views outside.
        document.translatesAutoresizingMaskIntoConstraints = true
        document.autoresizingMask = [.width]
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        message.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.margin),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Self.margin),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.margin),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            message.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            message.topAnchor.constraint(equalTo: topAnchor, constant: 14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Live Transcript")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let margin: CGFloat = 12

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        sizeDocument()
    }

    /// The document as wide as the visible list and as high as its bubbles (at least the visible height).
    private func sizeDocument() {
        let clip = scroll.contentView
        let width = clip.bounds.width
        guard width > 0 else { return }
        let rowWidth = max(0, width - 2 * Self.margin)
        for row in rows { row.fit(to: rowWidth) }
        if abs(document.frame.width - width) > 0.5 {
            document.setFrameSize(NSSize(width: width, height: max(document.frame.height, 1)))
        }
        document.layoutSubtreeIfNeeded()
        let height = max(clip.bounds.height, ceil(stack.frame.maxY + Self.margin))
        if abs(document.frame.height - height) > 0.5 {
            document.setFrameSize(NSSize(width: width, height: height))
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.resolved(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    /// The user has not scrolled away from the newest text.
    private var isAtEnd: Bool {
        let clip = scroll.contentView
        return rows.isEmpty || clip.bounds.maxY >= document.frame.height - 24
    }

    /// A status line instead of bubbles (starting, downloading, unavailable); nil: the bubbles.
    func show(message text: String?, bubbles: [TranscriptBubble]) {
        message.stringValue = text ?? ""
        message.isHidden = text == nil
        scroll.isHidden = text != nil
        guard text == nil else { return }
        let follow = isAtEnd
        // Rows are kept by bubble: usually only the last one grows or a new one comes.
        var index = 0
        for bubble in bubbles {
            if index < rows.count, rows[index].bubbleID == bubble.id {
                rows[index].show(bubble)
            } else {
                while rows.count > index {
                    rows.removeLast().removeFromSuperview()
                }
                let row = LiveBubbleRow()
                row.show(bubble)
                rows.append(row)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            index += 1
        }
        while rows.count > bubbles.count {
            rows.removeLast().removeFromSuperview()
        }
        sizeDocument()
        if follow { scrollToEnd() }
    }

    private func scrollToEnd() {
        sizeDocument()
        let clip = scroll.contentView
        let y = max(0, document.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// One bubble across the width of the list, on its side, at most `TranscriptBubbles.maximumWidth` of it.
private final class LiveBubbleRow: NSView {
    private(set) var bubbleID: UUID?
    private let column = NSStackView()
    private let name = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor)
    private let box = NSView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private var leadingEdge: NSLayoutConstraint!
    private var trailingEdge: NSLayoutConstraint!
    private var tint: NSColor = .systemGray
    private static let padding: CGFloat = 10

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.cornerCurve = .continuous
        box.translatesAutoresizingMaskIntoConstraints = false
        text.font = .preferredFont(forTextStyle: .body)
        text.isSelectable = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        box.addSubview(text)
        column.orientation = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(name)
        column.addArrangedSubview(box)
        addSubview(column)
        leadingEdge = column.leadingAnchor.constraint(equalTo: leadingAnchor)
        trailingEdge = column.trailingAnchor.constraint(equalTo: trailingAnchor)
        let compact = box.widthAnchor.constraint(equalToConstant: 0)
        compact.priority = NSLayoutConstraint.Priority(200)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Self.padding + 2),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Self.padding - 2),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: Self.padding - 2),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -Self.padding + 2),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            box.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: TranscriptBubbles.maximumWidth),
            compact,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        box.layer?.backgroundColor = tint.withAlphaComponent(0.16).resolved(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }

    /// A wrapping label needs the width it may take to know its height: from the list's width (`fit`), else its own.
    override func layout() {
        fit(to: bounds.width)
        super.layout()
    }

    /// The text wraps at most at `TranscriptBubbles.maximumWidth` of a row `width` wide, less the bubble's insides.
    func fit(to width: CGFloat) {
        guard width > 0 else { return }
        let available = max(40, floor(width * TranscriptBubbles.maximumWidth) - 2 * (Self.padding + 2))
        if abs(text.preferredMaxLayoutWidth - available) > 0.5 {
            text.preferredMaxLayoutWidth = available
            text.invalidateIntrinsicContentSize()
        }
    }

    func show(_ bubble: TranscriptBubble) {
        bubbleID = bubble.id
        let trailing = bubble.side == .trailing
        leadingEdge.isActive = !trailing
        trailingEdge.isActive = trailing
        column.alignment = trailing ? .trailing : .leading
        tint = bubble.speaker.map { NSColor.speaker($0.colorIndex) } ?? .systemGray
        name.stringValue = bubble.speaker?.name ?? ""
        name.isHidden = !bubble.showsName
        let font = NSFont.preferredFont(forTextStyle: .body)
        let content = NSMutableAttributedString()
        for (index, part) in bubble.parts.enumerated() {
            content.append(NSAttributedString(string: (index == 0 ? "" : " ") + part.text, attributes: [
                .font: font, .foregroundColor: part.isFinal ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]))
        }
        if text.attributedStringValue != content { text.attributedStringValue = content }
        updateLayer()
        setAccessibilityLabel([bubble.speaker?.name, bubble.text].compactMap { $0 }.joined(separator: ": "))
    }
}
