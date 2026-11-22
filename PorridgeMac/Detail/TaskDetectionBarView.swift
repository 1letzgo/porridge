import AppKit

/// Under the editor of a plain note: "2 possible to-dos". The text is looked at a moment after typing stopped
/// (`TaskDetection`); a click offers to make the note a to-do with those lines as subtasks, or to turn the lines into
/// checklist lines. Never on links, saved files or meetings.
@MainActor
final class TaskDetectionBarView: NSView {
    /// Hands typing still on its way to the note, before the note's text is changed from here.
    var beforeChange: () -> Void = {}
    /// After the note's text was changed from here: the editor shows the new text.
    var afterChange: () -> Void = {}

    private weak var note: Note?
    private var tasks: [DetectedTask] = []
    private var pending: Task<Void, Never>?
    private let button = PillButton(title: "", symbol: "checklist", tint: .brandTask, target: nil, action: nil)
    private let close = NSButton()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        button.labelColor = .brandTaskText
        button.target = self
        button.action = #selector(showMenu)
        button.setAccessibilityHelp("Offers to turn these lines into to-dos")
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(dismissTasks)
        close.toolTip = "Not To-dos"
        let row = NSStackView.horizontal([button, close], spacing: 6)
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 6, left: 0, bottom: 2, right: 0))
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The note's text changed (or the note is shown): it is looked at again once typing rests.
    func schedule(for note: Note, immediately: Bool = false) {
        self.note = note
        pending?.cancel()
        guard TaskDetection.applies(to: note) else {
            show([])
            return
        }
        pending = Task { @MainActor [weak self] in
            if !immediately { try? await Task.sleep(for: TaskDetection.debounce) }
            guard !Task.isCancelled, let self, let note = self.note else { return }
            self.show(TaskDetection.pending(for: note))
        }
    }

    func stop() {
        pending?.cancel()
    }

    private func show(_ found: [DetectedTask]) {
        tasks = found
        isHidden = found.isEmpty
        button.title = TaskDetection.label(count: found.count)
        button.setAccessibilityLabel(button.title)
        button.invalidateIntrinsicContentSize()
        button.toolTip = found.map { "• " + $0.text }.joined(separator: "\n")
    }

    @objc private func showMenu() {
        guard let note, !tasks.isEmpty else { return }
        let menu = NSMenu()
        for task in tasks {
            let item = NSMenuItem(title: task.text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let count = tasks.count
        if note.isTodo {
            menu.add(count == 1 ? "Add as Subtask" : "Add as \(count) Subtasks", symbol: "plus.circle") { [weak self] in self?.addAsSubtasks() }
        } else {
            if note.canBeTodo {
                menu.add(count == 1 ? "Make To-do with 1 Subtask" : "Make To-do with \(count) Subtasks", symbol: "checklist") { [weak self] in self?.makeTodo() }
            }
            menu.add("Add as Subtasks", symbol: "checkmark.square") { [weak self] in self?.addAsSubtasks() }
        }
        menu.addItem(.separator())
        menu.add("Not To-dos", symbol: "xmark") { [weak self] in self?.dismissTasks() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func makeTodo() {
        guard let note else { return }
        beforeChange()
        TaskDetection.makeTodo(note, with: TaskDetection.pending(for: note), in: Library.shared.context)
        afterChange()
        show([])
    }

    private func addAsSubtasks() {
        guard let note else { return }
        beforeChange()
        TaskDetection.addAsSubtasks(note, TaskDetection.pending(for: note), in: Library.shared.context)
        afterChange()
        show([])
    }

    @objc private func dismissTasks() {
        guard let note else { return }
        TaskDetection.dismiss(tasks, for: note)
        show([])
    }
}
