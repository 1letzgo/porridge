import AppKit

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
