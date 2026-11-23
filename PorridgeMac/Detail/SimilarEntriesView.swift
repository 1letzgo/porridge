import AppKit

/// "Similar" under an entry: the few entries most like it (`SimilarEntries`), as pills that open them. Hidden while
/// there are none.
final class SimilarEntriesView: NSView {
    var onOpen: ((Note) -> Void)?
    private let flow = FlowView()
    private let heading: NSTextField
    private var shown: [UUID] = []

    /// "Similar" by default; the entries of the same appointment use it with their own heading.
    init(title: String = String(localized: "Similar"), symbol: String = "sparkle.magnifyingglass", label: String = String(localized: "Similar Entries")) {
        heading = NSTextField.label(title, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold), color: .secondaryLabelColor)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: .symbol(symbol, size: 11, weight: .bold))
        icon.contentTintColor = .secondaryLabelColor
        heading.lineBreakMode = .byTruncatingTail
        let head = NSStackView.horizontal([icon, heading], spacing: 4)
        flow.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView.vertical([head, flow], spacing: 6)
        addSubview(stack)
        stack.pinEdges(to: self)
        flow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A heading of its own (the appointment's title and day).
    func setHeading(_ text: String) {
        if heading.stringValue != text { heading.stringValue = text }
    }

    @MainActor
    func show(_ notes: [Note]) {
        let ids = notes.map(\.id)
        isHidden = notes.isEmpty
        guard ids != shown else { return }
        shown = ids
        flow.setViews(notes.map { note in
            let title = note.displayTitle
            let short = title.count > 34 ? String(title.prefix(33)) + "…" : title
            let pill = PillButton(title: short, symbol: note.kindSymbol, tint: .brandSky, target: nil, action: nil)
            let open = ClosureTarget { [weak self] in self?.onOpen?(note) }
            pill.target = open
            pill.action = #selector(ClosureTarget.run)
            objc_setAssociatedObject(pill, &ClosureTarget.key, open, .OBJC_ASSOCIATION_RETAIN)
            pill.toolTip = title
            pill.setAccessibilityLabel(String(localized: "Open \(title)"))
            return pill
        })
    }
}
