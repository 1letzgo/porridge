import AppKit

/// The root of the list column and of the detail: files, pictures, links and text dragged in from other apps land
/// here (`Intake`) and go into the open bucket or the inbox. While something is dragged over it, it says what would
/// be added where, or why it can't be. Buckets in the sidebar are drop targets of their own.
final class ImportDropView: NSView {
    private let state: WindowState
    private let highlight = DropHighlightView()
    /// The drag the highlight was worked out for, so it is read once and not on every mouse move.
    private var sequence: Int?
    private var operation: NSDragOperation = []

    init(state: WindowState) {
        self.state = state
        super.init(frame: .zero)
        registerForDraggedTypes(Intake.pasteboardTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sequence == sender.draggingSequenceNumber ? operation : evaluate(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideHighlight()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideHighlight()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        operation != []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideHighlight()
        // Outside a bucket (inbox, to-dos, chat, archive, trash, search) it goes to the inbox, and the window follows.
        return Intake.accept(sender.draggingPasteboard, project: state.projectForNew, state: state)
    }

    private func evaluate(_ sender: NSDraggingInfo) -> NSDragOperation {
        sequence = sender.draggingSequenceNumber
        guard let plan = Intake.plan(sender.draggingPasteboard) else {
            operation = []
            hideHighlight()
            return []
        }
        let target = Intake.destinationName(project: state.projectForNew)
        if plan.canImport {
            operation = .copy
            showHighlight(title: "Add \(plan.summary) to \(target)", detail: plan.skippedNote, accepted: true)
        } else {
            operation = []
            showHighlight(title: "Can't Import", detail: plan.skippedNote, accepted: false)
        }
        return operation
    }

    private func showHighlight(title: String, detail: String?, accepted: Bool) {
        if highlight.superview == nil {
            highlight.translatesAutoresizingMaskIntoConstraints = false
            addSubview(highlight, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                highlight.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
                highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
                highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
                highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else if subviews.last !== highlight {
            // Views added since (another note opened) would cover it.
            addSubview(highlight, positioned: .above, relativeTo: nil)
        }
        highlight.show(title: title, detail: detail, accepted: accepted)
        highlight.isHidden = false
    }

    private func hideHighlight() {
        highlight.isHidden = true
    }
}

/// A rounded frame in the accent color over the column, with a label in the middle saying what the drop does.
private final class DropHighlightView: NSView {
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let label = DropLabelBackground()
    private var accepted = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3
        symbol.symbolConfiguration = .init(pointSize: 28, weight: .regular)

        let stack = NSStackView(views: [symbol, title, detail])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.addSubview(stack)
        stack.pinEdges(to: label)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The drag passes through to the column below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(title text: String, detail note: String?, accepted: Bool) {
        self.accepted = accepted
        title.stringValue = text
        detail.stringValue = note ?? ""
        detail.isHidden = note == nil
        let name = accepted ? "square.and.arrow.down" : "nosign"
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbol.contentTintColor = accepted ? .controlAccentColor : .brandDangerText
        title.textColor = accepted ? .labelColor : .brandDangerText
        setAccessibilityLabel([text, note].compactMap { $0 }.joined(separator: ". "))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = accepted ? .controlAccentColor : .brandDangerText
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 12, yRadius: 12)
        color.withAlphaComponent(0.08).setFill()
        path.fill()
        path.lineWidth = 2.5
        color.setStroke()
        path.stroke()
    }
}

/// The label's card: solid, so the rows below don't show through the words.
private final class DropLabelBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return shadow
        }()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
