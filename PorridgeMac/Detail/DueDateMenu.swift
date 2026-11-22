import AppKit

/// The due day of to-dos: Today, Tomorrow, Next Week, Pick Date…, Clear Due Date. The same menu on the chip of a
/// to-do's page, in the context menu of a row and under Note › Due Date. The days and their rules are the shared
/// ones of `Todos`; there are no reminders.
@MainActor
enum DueDateMenu {
    /// The menu for some to-dos. `anchor` is where Pick Date… opens its calendar (a popover); without it a sheet
    /// on `window` holds the calendar.
    static func make(for notes: [Note], window: NSWindow?, anchor: NSView? = nil) -> NSMenu {
        let menu = NSMenu(title: "Due Date")
        let todos = notes.filter(\.isTodo)
        for choice in Todos.DueChoice.allCases {
            let item = menu.add(choice.title, symbol: choice.systemImage) { TodoBridge.setDue(Todos.dueKey(for: choice), todos) }
            // Ticked when every to-do is due on that day.
            let key = Todos.dueKey(for: choice)
            item.state = !todos.isEmpty && todos.allSatisfy { $0.todoDue == key } ? .on : .off
        }
        menu.add("Pick Date…", symbol: "calendar") { DueDatePicker.present(for: todos, anchor: anchor, window: window) }
        menu.addItem(repeatItem(for: todos, window: window))
        if todos.contains(where: { $0.todoDue != nil }) {
            menu.addItem(.separator())
            menu.add("Clear Due Date", symbol: "calendar.badge.minus", isDestructive: true) { TodoBridge.setDue(nil, todos) }
        }
        return menu
    }

    /// Repeat ▸ Never, Daily, Weekly, Monthly, Yearly, Every N Days…: a repeating to-do moves to its next due day
    /// when it is done (`Todos.rollOver`); there are no reminders.
    static func repeatItem(for todos: [Note], window: NSWindow?) -> NSMenuItem {
        let context = Library.shared.context
        let rules = todos.map(\.todoRepeat)
        let submenu = NSMenu(title: "Repeat")
        let never = submenu.add("Never") { todos.forEach { Todos.setRepeat(nil, $0, in: context) } }
        never.state = !todos.isEmpty && rules.allSatisfy { $0 == nil } ? .on : .off
        for rule in TodoRepeat.presets {
            let item = submenu.add(rule.title) { todos.forEach { Todos.setRepeat(rule, $0, in: context) } }
            item.state = !todos.isEmpty && rules.allSatisfy { rule.sameRule(as: $0) } ? .on : .off
        }
        submenu.addItem(.separator())
        let custom = rules.first.flatMap { $0 }.flatMap { current in TodoRepeat.presets.contains { $0.sameRule(as: current) } ? nil : current }
        let customItem = submenu.add(custom.map { "\($0.title)…" } ?? "Every N Days…") {
            let days = custom.map { $0.interval * ($0.unit == .week ? 7 : 1) } ?? 2
            Alerts.ask(
                "Repeat Every N Days", message: "The to-do comes back this many days after its due day once it is done.",
                placeholder: "Days", value: String(days), action: "Repeat",
                validate: { Int($0.trimmingCharacters(in: .whitespaces)).map { (1...999).contains($0) } ?? false }, in: window
            ) { text in
                guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
                todos.forEach { Todos.setRepeat(.everyDays(n), $0, in: context) }
            }
        }
        customItem.state = custom != nil ? .on : .off
        let item = NSMenuItem(title: "Repeat", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: nil)
        item.submenu = submenu
        item.isEnabled = !todos.isEmpty
        return item
    }
}

/// The system's calendar to pick a due day: in a popover beside the chip, or a sheet when there is nothing to
/// point at (menu bar, context menu).
@MainActor
enum DueDatePicker {
    private static var popover: NSPopover?

    static func present(for notes: [Note], anchor: NSView?, window: NSWindow?) {
        guard !notes.isEmpty else { return }
        let controller = DueDatePickerController(notes: notes)
        if let anchor, anchor.window != nil {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            controller.close = { popover.close() }
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            self.popover = popover
        } else if let content = window?.contentViewController {
            controller.close = { [weak controller] in controller?.dismiss(nil) }
            content.presentAsSheet(controller)
        }
    }
}

final class DueDatePickerController: NSViewController {
    private let notes: [Note]
    private let picker = NSDatePicker()
    var close: () -> Void = {}

    init(notes: [Note]) {
        self.notes = notes
        super.init(nibName: nil, bundle: nil)
        title = "Due Date"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.datePickerMode = .single
        picker.isBezeled = false
        picker.drawsBackground = false
        picker.dateValue = notes.first?.todoDue.flatMap { Todos.dueDate($0) } ?? Date()
        picker.setAccessibilityLabel("Due Date")
        let title = NSTextField.label("Due Date", font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .bold))
        let cancel = ActionButton(title: "Cancel") { [weak self] in self?.close() }
        cancel.keyEquivalent = "\u{1b}"
        let done = ActionButton(title: "Done") { [weak self] in self?.commit() }
        done.keyEquivalent = "\r"
        let buttons = NSStackView.horizontal([cancel, NSView(), done], spacing: 8)
        let stack = NSStackView.vertical([title, picker, buttons], spacing: 12, alignment: .leading)
        let root = NSView()
        root.addSubview(stack)
        stack.pinEdges(to: root, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(picker)
    }

    private func commit() {
        TodoBridge.setDue(Todos.dueKey(picker.dateValue), notes)
        close()
    }
}

/// The chip of a to-do's page, first in the row of bowls and tags: "+ Due Date", or the day in green (red when
/// late). A click opens the menu of choices.
final class DueDateChip: PillButton {
    private var note: Note?
    weak var hostWindow: NSWindow?

    convenience init() {
        self.init(title: "Due Date", symbol: "plus", tint: .systemGray, target: nil, action: nil)
        target = self
        action = #selector(showMenu)
    }

    func show(_ note: Note) {
        self.note = note
        if let due = note.todoDue {
            let overdue = note.isOverdue
            title = Todos.dueLabel(due) + (note.todoRepeat != nil ? " ↻" : "")
            image = .symbol(overdue ? "calendar.badge.exclamationmark" : "calendar", size: 11, weight: .semibold)
            tint = overdue ? .systemRed : note.isDone ? .systemGray : .brandTask
            labelColor = overdue ? .brandDangerText : note.isDone ? nil : .brandTaskText
            setAccessibilityLabel(TodoBridge.dueAccessibility(of: note))
        } else {
            title = "Due Date"
            image = .symbol("plus", size: 11, weight: .semibold)
            tint = .systemGray
            labelColor = nil
            setAccessibilityLabel("Add Due Date")
        }
        isEnabled = !note.isDeleted
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    @objc private func showMenu() {
        guard let note else { return }
        let menu = DueDateMenu.make(for: [note], window: hostWindow ?? window, anchor: self)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }
}
