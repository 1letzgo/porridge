import AppKit

/// The tasks of a summary offered as to-dos, first thing on the summary tab: each can be picked and its title
/// changed; "Add 3 To-dos" takes the picked ones on (its menu, or Option-click, as one to-do with subtasks), Dismiss
/// lets them all go. What is not picked counts as dismissed. Nothing is made without a click; the rules are the
/// shared ones of `TodoSuggestions`.
final class SuggestedTodosView: NSView, NSTextFieldDelegate {
    private var note: Note?
    private var suggestions: [TaskSuggestion] = []
    private var picked = Set<String>()
    private var titles: [String: String] = [:]
    /// The suggestions the picks were made for: new ones (a new summary) get their own preselection.
    private var known = Set<String>()

    private let rows = NSStackView()
    private let addButton = NSButton()
    private let addMenu = NSPopUpButton(frame: .zero, pullsDown: true)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        let icon = NSImageView(image: .symbol("checklist", size: 13, weight: .bold))
        icon.contentTintColor = .brandTaskText
        let heading = NSTextField.label("Suggested To-dos", font: .systemFont(ofSize: NSFont.systemFontSize, weight: .bold), color: .brandTaskText)
        heading.setAccessibilityRole(.staticText)
        let head = NSStackView.horizontal([icon, heading], spacing: 6)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .push
        addButton.controlSize = .large
        addButton.keyEquivalent = "\r"
        addButton.target = self
        addButton.action = #selector(addTapped(_:))
        addButton.toolTip = "Option-click to add them as one to-do with subtasks"
        // The other way to take them on, as the button's menu.
        addMenu.bezelStyle = .push
        addMenu.controlSize = .large
        addMenu.addItem(withTitle: "")
        addMenu.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More Ways to Add")
        (addMenu.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        addMenu.toolTip = "More Ways to Add"
        addMenu.menu?.add("Add as One To-do with Subtasks", symbol: "checklist") { [weak self] in self?.take(asOne: true) }
        addMenu.setAccessibilityLabel("More Ways to Add")
        let dismiss = ActionButton(title: "Dismiss") { [weak self] in self?.dismissAll() }
        dismiss.controlSize = .large
        let buttons = NSStackView.horizontal([addButton, addMenu, NSView(), dismiss], spacing: 6)

        let stack = NSStackView.vertical([head, rows, buttons], spacing: 12)
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
        NSLayoutConstraint.activate([
            rows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Suggested To-dos")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.brandTask.withAlphaComponent(0.08).resolved(for: self)
        layer?.borderColor = NSColor.brandTask.withAlphaComponent(0.35).resolved(for: self)
    }

    /// Shows the suggestions waiting on the note; a row being edited keeps its text.
    @MainActor
    func show(_ suggestions: [TaskSuggestion], of note: Note) {
        self.note = note
        let changed = suggestions.map(\.key) != self.suggestions.map(\.key)
        self.suggestions = suggestions
        preselect()
        if changed || rows.arrangedSubviews.isEmpty { rebuildRows() }
        updateButton()
    }

    /// Picked at first: the user's own tasks and nobody's, or all when the app does not know the user's name.
    private func preselect() {
        let names = AppSettings.myNames
        for s in suggestions where !known.contains(s.key) {
            known.insert(s.key)
            if names.isEmpty || s.isMine { picked.insert(s.key) }
        }
        picked.formIntersection(Set(suggestions.map(\.key)))
    }

    private func rebuildRows() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for s in suggestions {
            let box = NSButton()
            box.isBordered = false
            box.setButtonType(.toggle)
            box.identifier = .init(s.key)
            box.target = self
            box.action = #selector(togglePick(_:))
            box.setAccessibilityRole(.checkBox)
            box.setAccessibilityLabel(titles[s.key] ?? s.title)
            renderBox(box, isOn: picked.contains(s.key))

            let field = NSTextField(string: titles[s.key] ?? s.title)
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .preferredFont(forTextStyle: .body)
            field.placeholderString = "To-do"
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.identifier = .init(s.key)
            field.delegate = self
            field.textColor = picked.contains(s.key) ? .labelColor : .secondaryLabelColor
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.setAccessibilityLabel("Title of the To-do")

            var meta: [NSView] = []
            if let owner = s.owner { meta.append(metaLabel(owner, symbol: "person")) }
            if let due = s.dueDay { meta.append(metaLabel(Todos.dueLabel(due), symbol: "calendar")) }
            // Owner and due day side by side, at the start of the line.
            let metaRow = NSStackView.horizontal(meta + [NSView()], spacing: 10)
            metaRow.arrangedSubviews.last?.setContentHuggingPriority(.init(1), for: .horizontal)
            let text = NSStackView.vertical(meta.isEmpty ? [field] : [field, metaRow], spacing: 2)
            let row = NSStackView.horizontal([box, text], spacing: 8, alignment: .top)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            field.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
    }

    private func metaLabel(_ text: String, symbol: String) -> NSView {
        let icon = NSImageView(image: .symbol(symbol, size: 10, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField.label(text, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        return NSStackView.horizontal([icon, label], spacing: 3)
    }

    private func renderBox(_ box: NSButton, isOn: Bool) {
        box.image = .symbol(isOn ? "checkmark.circle.fill" : "circle", size: 17, weight: .regular)
        box.contentTintColor = isOn ? .brandTaskText : .secondaryLabelColor
        box.state = isOn ? .on : .off
        box.setAccessibilityValue(isOn ? "Selected" : "Not Selected")
    }

    private func updateButton() {
        addButton.title = picked.count == 1 ? "Add 1 To-do" : "Add \(picked.count) To-dos"
        addButton.isEnabled = !picked.isEmpty
        addMenu.isEnabled = !picked.isEmpty
    }

    @objc private func togglePick(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        if picked.contains(key) { picked.remove(key) } else { picked.insert(key) }
        renderBox(sender, isOn: picked.contains(key))
        // The title of a task left out goes grey.
        if let row = sender.superview as? NSStackView,
           let field = row.arrangedSubviews.last.flatMap({ ($0 as? NSStackView)?.arrangedSubviews.first as? NSTextField }) {
            field.textColor = picked.contains(key) ? .labelColor : .secondaryLabelColor
        }
        updateButton()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let key = field.identifier?.rawValue else { return }
        titles[key] = field.stringValue
    }

    @objc private func addTapped(_ sender: NSButton) {
        take(asOne: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    @MainActor
    private func take(asOne: Bool) {
        guard let note else { return }
        window?.makeFirstResponder(nil)
        let chosen = suggestions.filter { picked.contains($0.key) }.map { s -> TaskSuggestion in
            var s = s
            let title = (titles[s.key] ?? s.title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { s.title = title }
            return s
        }
        let rest = suggestions.filter { !picked.contains($0.key) }
        TodoSuggestions.take(chosen, dismissing: rest, from: note, asOne: asOne, in: Library.shared.context)
    }

    #if DEBUG
    /// For the debug driver: "toggle <n>", "title <n> <text>", "add", "add-one", "dismiss".
    @MainActor
    func debug(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 2).map(String.init)
        let index = parts.count > 1 ? Int(parts[1]) : nil
        let rowViews = rows.arrangedSubviews.compactMap { $0 as? NSStackView }
        switch parts.first {
        case "toggle":
            if let index, index < rowViews.count, let box = rowViews[index].arrangedSubviews.first as? NSButton { togglePick(box) }
        case "title":
            if let index, index < rowViews.count, parts.count > 2,
               let field = (rowViews[index].arrangedSubviews.last as? NSStackView)?.arrangedSubviews.first as? NSTextField {
                field.stringValue = parts[2]
                controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
        case "add": take(asOne: false)
        case "add-one": take(asOne: true)
        case "dismiss": dismissAll()
        default: break
        }
    }
    #endif

    @MainActor
    private func dismissAll() {
        guard let note else { return }
        TodoSuggestions.dismiss(suggestions, from: note, in: Library.shared.context)
    }
}

/// The to-dos made from a meeting, below its summary: ticked right there, opened with a click.
final class MadeTodosView: NSView {
    private let rows = NSStackView()
    var onOpen: ((Note) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: .symbol("checklist", size: 13, weight: .bold))
        icon.contentTintColor = .brandTaskText
        let heading = NSTextField.label("To-dos", font: .systemFont(ofSize: NSFont.systemFontSize, weight: .bold), color: .brandTaskText)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        let stack = NSStackView.vertical([NSStackView.horizontal([icon, heading], spacing: 6), rows], spacing: 8)
        addSubview(stack)
        stack.pinEdges(to: self)
        rows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func show(_ todos: [Note]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for todo in Todos.byDue(todos) {
            let box = TodoCheckboxButton()
            box.isDone = todo.isDone
            box.translatesAutoresizingMaskIntoConstraints = false
            box.widthAnchor.constraint(equalToConstant: 24).isActive = true
            box.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let toggle = ClosureTarget { TodoBridge.setDone(!todo.isDone, todo) }
            box.target = toggle
            box.action = #selector(ClosureTarget.run)
            objc_setAssociatedObject(box, &ClosureTarget.key, toggle, .OBJC_ASSOCIATION_RETAIN)

            let title = NSAttributedString(string: todo.displayTitle, attributes: [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: todo.isDone ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .strikethroughStyle: todo.isDone ? NSUnderlineStyle.single.rawValue : 0,
            ])
            let open = ActionButton(title: "") { [weak self] in self?.onOpen?(todo) }
            open.isBordered = false
            open.attributedTitle = title
            open.alignment = .left
            open.lineBreakMode = .byTruncatingTail
            open.setAccessibilityLabel("Open \(todo.displayTitle)")
            open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            var parts: [NSView] = [box, open, NSView()]
            if let due = todo.todoDue {
                let status = TodoBridge.dueStatus(of: todo)
                let label = NSTextField.label(
                    Todos.dueLabel(due), font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: status == nil || status == .later ? .regular : .semibold),
                    color: status == .overdue ? .brandDangerText : status == .today ? .brandTaskText : .secondaryLabelColor
                )
                parts.append(label)
            }
            let chevron = NSImageView(image: .symbol("chevron.right", size: 10, weight: .bold))
            chevron.contentTintColor = .tertiaryLabelColor
            parts.append(chevron)
            let row = NSStackView.horizontal(parts, spacing: 8)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
}

/// A target for a control's action that runs a closure.
final class ClosureTarget: NSObject {
    nonisolated(unsafe) static var key = 0
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }
}
