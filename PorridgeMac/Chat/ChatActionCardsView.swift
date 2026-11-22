import AppKit

/// The changes an answer proposes, one card each with Confirm and Cancel, and "Confirm All" when there are several.
/// Nothing changes before a click; after it the card says what happened. The buttons call back with the action's id
/// (nil: all pending ones).
final class ChatActionCardsView: NSStackView {
    var onConfirm: ((UUID?) -> Void)?
    var onCancel: ((UUID?) -> Void)?

    init(actions: [ChatAction]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        for action in actions {
            let card = card(action)
            addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        let pending = actions.filter { $0.status == .pending }
        if pending.count > 1 {
            let cancel = NSButton(title: "Cancel All", target: self, action: #selector(cancelTapped(_:)))
            let confirm = NSButton(title: "Confirm All (\(pending.count))", target: self, action: #selector(confirmTapped(_:)))
            confirm.bezelColor = .brandNavy
            confirm.keyEquivalent = "\r"
            let row = NSStackView.horizontal([NSView(), cancel, confirm], spacing: 8)
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func card(_ action: ChatAction) -> NSView {
        let icon = NSImageView(image: .symbol(action.symbol, size: 13, weight: .bold))
        icon.contentTintColor = .brandNavy
        let title = NSTextField.label(action.title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), lines: 0)
        var texts: [NSView] = [title]
        if let subject = action.subject {
            texts.append(NSTextField.label("«\(subject)»", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 2))
        }
        let column = NSStackView.vertical(texts, spacing: 2)
        column.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var row: [NSView] = [icon, column]
        switch action.status {
        case .pending:
            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped(_:)))
            cancel.identifier = .init(action.id.uuidString)
            let confirm = NSButton(title: "Confirm", target: self, action: #selector(confirmTapped(_:)))
            confirm.identifier = .init(action.id.uuidString)
            confirm.bezelColor = .brandNavy
            row += [cancel, confirm]
        default:
            let color: NSColor = action.status == .failed ? .brandDangerText : action.status == .done ? .brandTaskText : .secondaryLabelColor
            let status = NSTextField.label(Self.statusText(action), font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: color, lines: 2)
            status.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            row.append(status)
        }
        let stack = NSStackView.horizontal(row, spacing: 10)
        let box = BubbleView(content: stack, tint: .brandSky)
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel(action.title + (action.subject.map { ", " + $0 } ?? ""))
        return box
    }

    static func statusText(_ action: ChatAction) -> String {
        switch action.status {
        case .pending: "Waiting"
        case .done: "✓ Done"
        case .cancelled: "Cancelled"
        case .undone: "Undone"
        case .failed: "Could not be done" + (action.failure.map { ": " + $0 } ?? "")
        }
    }

    @objc private func confirmTapped(_ sender: NSButton) {
        onConfirm?(sender.identifier.flatMap { UUID(uuidString: $0.rawValue) })
    }

    @objc private func cancelTapped(_ sender: NSButton) {
        onCancel?(sender.identifier.flatMap { UUID(uuidString: $0.rawValue) })
    }
}

/// What was just changed from the chat, with Undo, for a few seconds.
final class ChatUndoToastBar: NSView {
    private let label = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .brandOnNavy, lines: 2)
    private let undo = NSButton()
    var onUndo: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        undo.title = "Undo"
        undo.isBordered = false
        undo.attributedTitle = NSAttributedString(string: "Undo", attributes: [
            .foregroundColor: NSColor.brandSky, .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .bold),
        ])
        undo.target = self
        undo.action = #selector(undoTapped)
        let row = NSStackView.horizontal([label, undo], spacing: 14)
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.brandNavy.resolved(for: self)
    }

    func show(_ message: String) {
        label.stringValue = message
        setAccessibilityLabel(message)
    }

    @objc private func undoTapped() { onUndo?() }
}
