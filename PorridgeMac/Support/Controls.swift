import AppKit

/// The rounded square in front of a row (the place of the checkbox in Things): its color says what the entry is.
/// The design's token (stage 7): 26 pt, corner 7, a 15 % wash of the kind's color without a border, the symbol in the
/// readable value. A pinned entry wears a small navy pin badge on its top right corner.
final class KindIconView: NSView {
    var symbol = "text.alignleft" { didSet { update() } }
    var tint: NSColor = .brandSky { didSet { update() } }
    var isPinned = false { didSet { pin.isHidden = !isPinned } }
    private let image = NSImageView()
    private let pin = NSView()
    private let pinImage = NSImageView()
    private let side: CGFloat

    init(side: CGFloat = 26) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = (side * 0.27).rounded()
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        image.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        pin.wantsLayer = true
        pin.layer?.cornerRadius = 8
        pin.layer?.borderWidth = 1.5
        pin.translatesAutoresizingMaskIntoConstraints = false
        pinImage.image = .symbol("pin.fill", size: 8, weight: .bold)
        pinImage.translatesAutoresizingMaskIntoConstraints = false
        pin.addSubview(pinImage)
        pin.isHidden = true
        addSubview(pin)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 16),
            pin.heightAnchor.constraint(equalToConstant: 16),
            pin.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            pin.centerYAnchor.constraint(equalTo: topAnchor, constant: 1),
            pinImage.centerXAnchor.constraint(equalTo: pin.centerXAnchor),
            pinImage.centerYAnchor.constraint(equalTo: pin.centerYAnchor),
        ])
        setAccessibilityElement(false)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }

    private func update() {
        image.image = .symbol(symbol, size: (side * 0.48).rounded(), weight: .semibold)
        image.contentTintColor = tint.readable
        needsDisplay = true
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tint.withAlphaComponent(0.15).resolved(for: self)
        pin.layer?.backgroundColor = NSColor.brandNavy.resolved(for: self)
        pin.layer?.borderColor = NSColor.textBackgroundColor.resolved(for: self)
        pinImage.contentTintColor = .brandOnNavy
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayer()
    }
}

/// A capsule button: a wash of its color with a navy label (the "main buttons" of `DESIGN.md`), or a full fill.
class PillButton: NSButton {
    var tint: NSColor = .brandSky { didSet { needsDisplay = true } }
    var isFilled = false { didSet { needsDisplay = true } }
    /// The label's color on a wash; navy when nil.
    var labelColor: NSColor? { didSet { needsDisplay = true } }
    /// A line around it instead of a wash (the document chip, set apart from bowls and tags).
    var isOutlined = false { didSet { needsDisplay = true } }

    convenience init(title: String, symbol: String? = nil, tint: NSColor = .brandSky, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        if let symbol { image = .symbol(symbol, size: 11, weight: .semibold) }
        imagePosition = symbol == nil ? .noImage : .imageLeading
        self.tint = tint
        self.target = target
        self.action = action
        isBordered = false
        font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .semibold)
        translatesAutoresizingMaskIntoConstraints = false
        setButtonType(.momentaryPushIn)
        focusRingType = .default
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 20
        size.height = max(size.height + 8, 24)
        return size
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        if isOutlined {
            if isHighlighted {
                tint.withAlphaComponent(0.18 * alpha).setFill()
                path.fill()
            }
            tint.withAlphaComponent(0.7 * alpha).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            (isFilled ? tint : tint.withAlphaComponent(isHighlighted ? 0.32 : 0.18)).withAlphaComponent(isFilled ? alpha : (isHighlighted ? 0.32 : 0.18) * alpha).setFill()
            path.fill()
        }
        let color = (isFilled ? tint.onFill : labelColor ?? NSColor.brandNavy).withAlphaComponent(alpha)
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 12), .foregroundColor: color]
        let text = NSAttributedString(string: title, attributes: attributes)
        let textSize = text.size()
        var symbolSize = NSSize.zero
        var tinted: NSImage?
        if let image, imagePosition != .noImage {
            tinted = image.tinted(color)
            symbolSize = image.size
        }
        let gap: CGFloat = tinted == nil || title.isEmpty ? 0 : 5
        let total = symbolSize.width + gap + textSize.width
        var x = (bounds.width - total) / 2
        if let tinted {
            tinted.draw(in: NSRect(x: x, y: (bounds.height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height))
            x += symbolSize.width + gap
        }
        text.draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2))
    }
}

extension NSImage {
    /// The image as a template in one color.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A small state in a row: "Summarized", "Failed", what the queue is doing.
final class StateBadge: NSView {
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        icon.isHidden = true
        let stack = NSStackView(views: [spinner, icon, label])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String?, color: NSColor = .secondaryLabelColor, spinning: Bool = false, symbol: String? = nil) {
        isHidden = text == nil
        label.stringValue = text ?? ""
        label.textColor = color
        icon.isHidden = symbol == nil
        if let symbol {
            icon.image = .symbol(symbol, size: NSFont.smallSystemFontSize - 1, weight: .semibold)
            icon.contentTintColor = color
        }
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}

/// The Mac's one empty view, for an empty list, detail, sheet or the chat's start: symbol, title, a line of
/// explanation, in the middle of the room it is pinned to (across and up and down). Title and message wrap.
final class EmptyMessageView: NSView {
    private let image = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image.contentTintColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center
        title.preferredMaxLayoutWidth = 280
        title.isSelectable = false
        message.isSelectable = false
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.preferredMaxLayoutWidth = 260
        [image, title, message].forEach(stack.addArrangedSubview)
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        // In the middle; a room too low for it keeps its top in view.
        let middle = stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        middle.priority = .defaultHigh
        middle.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The room reaches up over bars (a list's segment and filters) so the message stands at the same place on every
    /// page; it never goes up under them.
    func keepBelow(_ anchor: NSLayoutYAxisAnchor) {
        stack.topAnchor.constraint(greaterThanOrEqualTo: anchor, constant: 8).isActive = true
    }

    /// Title and message wrap at the width the room gives (at most 280): with a fixed wrap width the labels asked for
    /// the height of fewer lines than they got in a narrow list column, and the message was cut after its first line.
    override func layout() {
        let width = max(min(280, bounds.width - 40), 60)
        var changed = false
        for label in [title, message] where label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        super.layout()
        if changed { needsLayout = true }
    }

    /// Only a message: clicks go through to what is below it (the empty Inbox's top card).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(title: String, message: String, symbol: String) {
        image.image = .symbol(symbol, size: 34, weight: .light)
        self.title.stringValue = title
        self.message.stringValue = message
        self.message.isHidden = message.isEmpty
        setAccessibilityElement(true)
        setAccessibilityLabel(message.isEmpty ? title : "\(title). \(message)")
    }
}

extension NSTextField {
    static func label(_ text: String = "", font: NSFont = .systemFont(ofSize: NSFont.systemFontSize), color: NSColor = .labelColor, lines: Int = 1) -> NSTextField {
        // More than one line: broken between words, the last line cut with "…" (`WrappingLabel`). A truncating line
        // break mode turns the cell's wrapping off, so such a label stayed on one line ("Quarterly Planning…").
        if lines != 1 { return WrappingLabel(text, font: font, color: color, lines: lines) }
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = lines
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isSelectable = false
        return field
    }
}

extension NSTableCellView {
    /// A cell of a table with automatic row heights and labels of several lines: once the cell knows its width, the
    /// labels measure their lines for it and the table measures the row again. The table works out a row's height
    /// before the cell is laid out at the column's width, when a wrapping label still counts one line.
    func fitWrappingLabels(_ labels: [NSTextField]) {
        var changed = false
        for label in labels where !label.isHidden {
            let width = label.frame.width
            guard width > 0, abs(label.preferredMaxLayoutWidth - width) > 0.5 else { continue }
            label.preferredMaxLayoutWidth = width
            label.invalidateIntrinsicContentSize()
            changed = true
        }
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var view = self.superview
            while let current = view, !(current is NSTableView) { view = current.superview }
            guard let table = view as? NSTableView else { return }
            let row = table.row(for: self)
            if row >= 0 { table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row)) }
        }
    }
}

extension NSStackView {
    static func horizontal(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        stack.alignment = alignment
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func vertical(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = spacing
        stack.alignment = alignment
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

extension NSView {
    /// Pins the view to the edges of its superview, with insets.
    func pinEdges(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom),
        ])
    }

    /// Pins the view to the edges of its superview, its bottom only just below the priority a window keeps its size
    /// with (500): the view fills the room it is given, but however high its content asks to be (a wrapping label
    /// measured in a column still opening, a few pt wide, counts one character per line), it never makes the window
    /// taller; it is cut at the bottom instead.
    func pinEdgesKeepingWindowSize(to other: NSView, insets: NSEdgeInsets = NSEdgeInsets()) {
        translatesAutoresizingMaskIntoConstraints = false
        let bottom = bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom)
        bottom.priority = .init(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottom,
        ])
    }
}
