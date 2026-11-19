import AppKit

// Building blocks of the Settings window: a two-column form (labels right-aligned, controls left, as in the
// macOS settings), closure-driven controls and the row of an on-device model with its download state.

/// The width of the label column and of the control column; the same in every tab so they line up.
enum SettingsMetrics {
    static let labelWidth: CGFloat = 150
    static let controlWidth: CGFloat = 360
    static let inset: CGFloat = 30
}

/// A two-column `NSGridView`: a right-aligned label ("Language:") and a control to its right.
@MainActor
final class SettingsForm {
    let grid: NSGridView

    init() {
        grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = SettingsMetrics.labelWidth
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).width = SettingsMetrics.controlWidth
    }

    /// A row: `label` (a colon is added) and its control. `top`: the control is taller than a line (a list).
    @discardableResult
    func row(_ label: String?, _ view: NSView, top: Bool = false) -> NSGridRow {
        let title = label.map { NSTextField(labelWithString: $0.isEmpty ? "" : "\($0):") } ?? NSTextField(labelWithString: "")
        title.alignment = .right
        let row = grid.addRow(with: [title, view])
        if top {
            row.rowAlignment = .none
            row.yPlacement = .top
            // The label sits on the first line of the list.
            title.translatesAutoresizingMaskIntoConstraints = false
        }
        return row
    }

    /// A footnote under a control: small secondary text that wraps.
    @discardableResult
    func note(_ text: String = "", color: NSColor = .secondaryLabelColor) -> (row: NSGridRow, label: NSTextField) {
        let label = SettingsForm.footnote(text, color: color)
        let row = grid.addRow(with: [NSGridCell.emptyContentView, label])
        row.topPadding = -4
        return (row, label)
    }

    /// A hairline across both columns between groups.
    @discardableResult
    func separator() -> NSGridRow {
        let box = NSBox()
        box.boxType = .separator
        let row = grid.addRow(with: [box])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.rowAlignment = .none
        row.yPlacement = .center
        row.topPadding = 6
        row.bottomPadding = 6
        box.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    static func footnote(_ text: String, color: NSColor = .secondaryLabelColor, width: CGFloat = SettingsMetrics.controlWidth) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = color
        label.preferredMaxLayoutWidth = width
        label.isSelectable = false
        return label
    }
}

/// The root view of a Settings tab: the form, centered, with margins. Its fitting size is what the window takes.
@MainActor
class SettingsPane: NSViewController {
    let form = SettingsForm()
    var observers: [Observing] = []
    private var defaultsObserver: NSObjectProtocol?
    private var renderScheduled = false

    override func loadView() {
        // Sized by the tab view (autoresizing); its fitting size comes from the form.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        root.autoresizingMask = [.width, .height]
        let grid = form.grid
        root.addSubview(grid)
        let inset = SettingsMetrics.inset
        let bottom = grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset)
        bottom.priority = .defaultLow
        let width = root.widthAnchor.constraint(equalToConstant: SettingsMetrics.labelWidth + SettingsMetrics.controlWidth + 8 + inset * 2)
        width.priority = .defaultLow
        // Not required: while the window animates to another tab's height, the form may not fit for a moment.
        let leading = grid.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: inset)
        leading.priority = .init(999)
        let fits = grid.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -inset)
        fits.priority = .init(999)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: inset - 6),
            grid.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            leading, fits, bottom, width,
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        build()
        observers.append(Observing { [weak self] in self?.render() })
        // Settings changed elsewhere (the menu bar, another window) show here too.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsRender() }
        }
    }

    /// Adds the rows to `form`; called once.
    func build() {}

    /// Brings the controls up to date. Runs inside `Observing`: what it reads of the observable services is followed.
    func render() {}

    /// Renders again a moment later (several changes at once render once).
    func setNeedsRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.render()
        }
    }

    /// Rows were shown or hidden: the window follows the new height.
    func contentChanged() {
        DispatchQueue.main.async { [weak self] in
            (self?.parent as? SettingsTabController)?.fitWindow(animated: true)
        }
    }

    /// Presents a sheet over the Settings window, or a window of its own when there is none.
    func presentSheet(_ controller: NSViewController) {
        if view.window != nil {
            presentAsSheet(controller)
        } else {
            NSWindow(contentViewController: controller).makeKeyAndOrderFront(nil)
        }
    }

    deinit {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }
}

// MARK: - Controls with closures

/// A pop-up menu of titles; `onSelect` gets the index chosen.
final class SettingsPopUp: NSPopUpButton {
    var onSelect: ((Int) -> Void)?

    convenience init(onSelect: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        self.onSelect = onSelect
        target = self
        action = #selector(changed)
    }

    /// Replaces the items when they differ, and selects `selected`.
    func set(_ titles: [String], selected: Int?) {
        if itemTitles != titles {
            removeAllItems()
            for title in titles {
                // `addItem(withTitle:)` merges equal titles; menu items keep them apart.
                menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        if let selected, selected < numberOfItems { selectItem(at: selected) } else { select(nil) }
    }

    @objc private func changed() { onSelect?(indexOfSelectedItem) }
}

/// A checkbox whose action is a closure.
final class SettingsCheckbox: NSButton {
    private var handler: ((Bool) -> Void)?

    convenience init(_ title: String, handler: @escaping (Bool) -> Void) {
        self.init(checkboxWithTitle: title, target: nil, action: nil)
        self.handler = handler
        target = self
        action = #selector(changed)
    }

    var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }

    @objc private func changed() { handler?(state == .on) }
}

/// A text field that reports every change.
final class SettingsTextField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?

    convenience init(placeholder: String, width: CGFloat = 260, secure: Bool = false, onChange: @escaping (String) -> Void) {
        self.init(frame: .zero)
        placeholderString = placeholder
        self.onChange = onChange
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
    }

    /// Sets the text unless the user is typing in it.
    func show(_ text: String) {
        if currentEditor() == nil, stringValue != text { stringValue = text }
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(stringValue) }
}

/// A secure text field that reports every change.
final class SettingsSecureField: NSSecureTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?

    convenience init(placeholder: String, width: CGFloat = 260, onChange: @escaping (String) -> Void) {
        self.init(frame: .zero)
        placeholderString = placeholder
        self.onChange = onChange
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(stringValue) }
}

extension NSButton {
    /// A small borderless symbol button (trash, pencil) with an accessibility label.
    static func symbolButton(_ symbol: String, label: String, tint: NSColor? = nil, handler: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title: "", symbol: symbol, handler: handler)
        button.image = .symbol(symbol, size: 13, label: label)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.contentTintColor = tint
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }

    /// A push button with a closure.
    static func push(_ title: String, handler: @escaping () -> Void) -> ActionButton {
        ActionButton(title: title, handler: handler)
    }
}

// MARK: - Model row

/// An on-device model: its name, a line about it, and its state on the right: Download, a progress bar with a
/// stop button, a checkmark with a trash button, or Retry.
@MainActor
final class ModelStateRow: NSView {
    private let titleLabel = NSTextField.label()
    private let subtitleLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
    private let errorLabel = SettingsForm.footnote("", color: .brandDangerText, width: 240)
    private let trailing = NSStackView.horizontal([], spacing: 6)
    private let modelTitle: String
    private let action: () -> Void
    private let onDelete: (() -> Void)?
    private let onCancel: (() -> Void)?
    private var state: ModelManager.State?

    init(
        title: String, subtitle: String, width: CGFloat = SettingsMetrics.controlWidth,
        onDelete: (() -> Void)? = nil, onCancel: (() -> Void)? = nil, action: @escaping () -> Void
    ) {
        modelTitle = title
        self.action = action
        self.onDelete = onDelete
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
        errorLabel.maximumNumberOfLines = 3
        errorLabel.isHidden = true
        let text = NSStackView.vertical([titleLabel, subtitleLabel, errorLabel], spacing: 2)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView.horizontal([text, trailing], spacing: 10)
        row.distribution = .fill
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(row)
        row.pinEdges(to: self)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var firstBaselineOffsetFromTop: CGFloat {
        titleLabel.firstBaselineOffsetFromTop
    }

    func update(_ state: ModelManager.State) {
        guard state != self.state else { return }
        let kindChanged = self.state.map { !Self.sameKind($0, state) } ?? true
        self.state = state
        if case .failed(let message) = state {
            errorLabel.stringValue = message
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
        if !kindChanged, case .downloading(let progress) = state,
           let bar = trailing.arrangedSubviews.first as? NSProgressIndicator {
            bar.doubleValue = progress
            return
        }
        trailing.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch state {
        case .notInstalled:
            trailing.addArrangedSubview(NSButton.push("Download") { [weak self] in self?.action() })
        case .installed, .ready, .loading:
            // On the device; whether it is in memory yet is nothing to show here. Not deleted while it loads.
            let check = NSImageView(image: .symbol("checkmark.circle.fill", size: 15, label: "Installed"))
            check.contentTintColor = .brandSkyText
            trailing.addArrangedSubview(check)
            if let onDelete, state != .loading {
                trailing.addArrangedSubview(NSButton.symbolButton("trash", label: "Delete", tint: .brandDangerText, handler: onDelete))
            }
        case .downloading(let progress):
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = progress
            bar.controlSize = .small
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 80).isActive = true
            bar.setAccessibilityLabel("Downloading \(modelTitle)")
            trailing.addArrangedSubview(bar)
            if onCancel != nil {
                trailing.addArrangedSubview(NSButton.symbolButton("xmark.circle.fill", label: "Cancel Download", tint: .secondaryLabelColor) { [weak self] in
                    self?.confirmCancel()
                })
            }
        case .failed:
            trailing.addArrangedSubview(NSButton.push("Retry") { [weak self] in self?.action() })
        }
    }

    private static func sameKind(_ a: ModelManager.State, _ b: ModelManager.State) -> Bool {
        switch (a, b) {
        case (.downloading, .downloading): true
        default: a == b
        }
    }

    private func confirmCancel() {
        let alert = NSAlert()
        alert.messageText = "Cancel Download of \(modelTitle)?"
        alert.informativeText = "What has been downloaded so far will be deleted."
        let stop = alert.addButton(withTitle: "Cancel Download")
        stop.hasDestructiveAction = true
        stop.keyEquivalent = ""
        let keep = alert.addButton(withTitle: "Keep Downloading")
        keep.keyEquivalent = "\r"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // It may have finished while the question was open: then there is nothing to stop.
            if case .downloading = self.state { self.onCancel?() }
        }
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

/// Reports a model state that turned into a failure, once (the "Download Failed" alert of the settings).
@MainActor
final class FailureWatch {
    private var seen: [String: Bool] = [:]

    /// The message of a state that failed since the last call, if any.
    func newFailure(_ states: [String: ModelManager.State]) -> String? {
        var message: String?
        for (key, state) in states {
            let failed: Bool
            if case .failed(let text) = state {
                failed = true
                if seen[key] == false, message == nil { message = text }
            } else {
                failed = false
            }
            seen[key] = failed
        }
        return message
    }
}

// MARK: - Sheets

/// A flipped document view, so the content of a scroll view starts at the top.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
enum SettingsSheet {
    /// A scroll view whose document is a vertical stack as wide as the view.
    static func scrollingStack(spacing: CGFloat = 12, insets: NSEdgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 20, right: 20)) -> (NSScrollView, NSStackView) {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView.vertical([], spacing: spacing)
        document.addSubview(stack)
        stack.pinEdges(to: document, insets: insets)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return (scroll, stack)
    }

    /// The bold title on top of a sheet.
    static func title(_ text: String) -> NSTextField {
        let label = NSTextField.label(text, font: .systemFont(ofSize: 17, weight: .bold))
        label.setAccessibilityRole(.staticText)
        return label
    }

    /// A section head as in the settings cards: small bold title in the accent color over a hairline.
    static func sectionHead(_ text: String, width: CGFloat) -> NSView {
        let label = NSTextField.label(text, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .bold), color: .controlAccentColor)
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView.vertical([label, line], spacing: 6)
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    static func hairline(width: CGFloat) -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: width).isActive = true
        return line
    }

    /// A default button (Return) on the right.
    static func defaultButton(_ title: String, handler: @escaping () -> Void) -> ActionButton {
        let button = NSButton.push(title, handler: handler)
        button.keyEquivalent = "\r"
        return button
    }

    /// A cancel button (Escape).
    static func cancelButton(_ title: String = "Cancel", handler: @escaping () -> Void) -> ActionButton {
        let button = NSButton.push(title, handler: handler)
        button.keyEquivalent = "\u{1b}"
        return button
    }

    /// The bottom bar of a sheet: buttons on the left, a gap, buttons on the right.
    static func footer(left: [NSView] = [], right: [NSView]) -> NSStackView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView.horizontal(left + [spacer] + right, spacing: 10)
        bar.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 16, right: 20)
        return bar
    }
}
