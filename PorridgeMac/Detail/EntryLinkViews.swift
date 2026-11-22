import AppKit

/// "Linked From" and "Mentions" under an entry: the entries whose text links here, as pills that open them; then
/// the entries that name this one by its title without a link, each with "Link" (not in view-only bowls). Hidden
/// while there are none.
final class EntryLinksView: NSView {
    var onOpen: ((Note) -> Void)?
    /// After "Link": the lists are worked out again.
    var onChange: (() -> Void)?
    private let linkedHead: NSStackView
    private let linkedFlow = FlowView()
    private let mentionsHead: NSStackView
    private let mentionsFlow = FlowView()
    private var shown: ([UUID], [UUID]) = ([], [])

    init() {
        linkedHead = Self.heading(String(localized: "Linked From"), symbol: "link")
        mentionsHead = Self.heading(String(localized: "Mentions"), symbol: "text.quote")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for flow in [linkedFlow, mentionsFlow] { flow.translatesAutoresizingMaskIntoConstraints = false }
        let stack = NSStackView.vertical([linkedHead, linkedFlow, mentionsHead, mentionsFlow], spacing: 6)
        stack.setCustomSpacing(12, after: linkedFlow)
        addSubview(stack)
        stack.pinEdges(to: self)
        linkedFlow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        mentionsFlow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Links to This Entry"))
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func heading(_ title: String, symbol: String) -> NSStackView {
        let icon = NSImageView(image: .symbol(symbol, size: 11, weight: .bold))
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField.label(title, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold), color: .secondaryLabelColor)
        return NSStackView.horizontal([icon, label], spacing: 4)
    }

    @MainActor
    func show(linkedFrom: [Note], mentions: [Note], target: Note?) {
        isHidden = linkedFrom.isEmpty && mentions.isEmpty
        linkedHead.isHidden = linkedFrom.isEmpty
        linkedFlow.isHidden = linkedFrom.isEmpty
        mentionsHead.isHidden = mentions.isEmpty
        mentionsFlow.isHidden = mentions.isEmpty
        let ids = (linkedFrom.map(\.id), mentions.map(\.id))
        guard ids != shown else { return }
        shown = ids
        linkedFlow.setViews(linkedFrom.map(pill))
        mentionsFlow.setViews(mentions.map { other in
            let open = pill(other)
            guard let target, !BowlSharing.shared.isReadOnly(other) else { return open }
            let link = ActionButton(title: String(localized: "Link")) { [weak self] in
                if EntryLinks.linkMention(in: other, to: target) { self?.onChange?() }
            }
            link.bezelStyle = .inline
            link.controlSize = .small
            link.toolTip = String(localized: "Make the name a link to this entry")
            link.setAccessibilityLabel(String(localized: "Link \(other.displayTitle) to this entry"))
            return NSStackView.horizontal([open, link], spacing: 4)
        })
    }

    private func pill(_ note: Note) -> NSView {
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
    }
}

/// The entries offered after "[[" in the Mac editor: a small list under the cursor. It never takes the keyboard:
/// the arrow keys, Return and Escape reach it through the text view (`handleLinkSearchCommand`); a click links one.
@MainActor
final class EntryLinkSuggestionPanel {
    private var panel: NSPanel?
    private let list = NSStackView()
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 26

    /// Shows `results` under `caret` (screen coordinates), with `highlight` marked.
    func show(_ results: [EntryLinks.Candidate], highlight: Int, under caret: NSRect, in parent: NSWindow, choose: @escaping (EntryLinks.Candidate) -> Void) {
        let panel = self.panel ?? makePanel()
        list.setViews(results.enumerated().map { index, candidate in
            SuggestionRow(candidate: candidate, highlighted: index == highlight) { choose(candidate) }
        }, in: .top)
        let height = CGFloat(results.count) * Self.rowHeight + 8
        var origin = NSPoint(x: caret.minX - 6, y: caret.minY - height - 4)
        if let screen = parent.screen?.visibleFrame {
            // Above the line when there is no room below; inside the screen sideways.
            if origin.y < screen.minY { origin.y = caret.maxY + 4 }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - Self.width)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.masksToBounds = true
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(list)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 4),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -4),
        ])
        panel.contentView = background
        panel.setAccessibilityLabel(String(localized: "Link to Entry"))
        self.panel = panel
        return panel
    }
}

/// One entry in the "[[" list: its kind's symbol and title; highlighted in the accent color.
private final class SuggestionRow: NSView {
    private let action: () -> Void

    init(candidate: EntryLinks.Candidate, highlighted: Bool, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.cgColor : nil
        let icon = NSImageView(image: .symbol(candidate.symbol, size: 12))
        icon.contentTintColor = highlighted ? .white : .secondaryLabelColor
        let title = NSTextField.label(candidate.title, color: highlighted ? .white : .labelColor)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView.horizontal([icon, title], spacing: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: EntryLinkSuggestionPanel.width - 8),
            heightAnchor.constraint(equalToConstant: EntryLinkSuggestionPanel.rowHeight),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Link \(candidate.title)"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        action()
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }
}
