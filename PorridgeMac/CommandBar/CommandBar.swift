import AppKit

/// One line of the command bar: a command, a bowl to go to, or an entry to open.
struct CommandItem {
    enum Kind: Int {
        case command, bowl, entry

        var label: String {
            switch self {
            case .command: String(localized: "Command")
            case .bowl: String(localized: "Bowl")
            case .entry: String(localized: "Entry")
            }
        }
    }

    var kind: Kind
    var title: String
    var subtitle: String?
    var symbol: String
    var tint: NSColor
    /// More words the item is found by ("new create" for New Note).
    var keywords: String = ""
    /// Shown with an empty field.
    var isSuggested = false
    var run: @MainActor () -> Void
}

/// What the command bar offers for a window: its commands (new note, record a meeting, dictation, settings, moving
/// the selected entries into a bowl), the bowls, and the entries (by title, fuzzy, and by their words through the
/// search index, `NoteIndex`).
@MainActor
enum CommandBarItems {
    static let limit = 40

    static func items(for query: String, controller: MainWindowController) -> [CommandItem] {
        let library = Library.shared
        let commands = commands(for: controller) + bowlItems(for: controller)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let living = library.notes.filter { !$0.isDeleted }
        guard !query.isEmpty else {
            // The usual commands, then the latest entries.
            return commands.filter(\.isSuggested) + living.prefix(6).map { entryItem($0, controller: controller) }
        }
        var scored: [(item: CommandItem, score: Int, order: Int)] = []
        for (index, item) in commands.enumerated() {
            if let score = FuzzyMatch.score(query, in: [item.title, item.title + " " + item.keywords]) {
                scored.append((item, score + (item.kind == .command ? 30 : 20), index))
            }
        }
        // Entries by their title first; then those whose words hold the query (the search's index).
        var seen = Set<UUID>()
        for (index, note) in living.enumerated() {
            guard let score = FuzzyMatch.score(query, in: note.displayTitle) else { continue }
            seen.insert(note.id)
            scored.append((entryItem(note, controller: controller), score, 1000 + index))
        }
        if let ids = NoteIndex.shared.noteIDs(matching: query) {
            for (index, note) in living.enumerated() where ids.contains(note.id) && !seen.contains(note.id) {
                scored.append((entryItem(note, controller: controller), 0, 2000 + index))
                if scored.count > 400 { break }
            }
        }
        var ranked = scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit)
            .map(\.item)
        // Always a way into the full search.
        ranked.append(CommandItem(kind: .command, title: String(localized: "Search for “\(query)”"), symbol: "magnifyingglass", tint: .brandNavy) { [weak controller] in
            guard let controller else { return }
            controller.state.page = .search
            controller.state.searchText = query
            controller.focusSearch(nil)
        })
        return ranked
    }

    private static func commands(for controller: MainWindowController) -> [CommandItem] {
        var items: [CommandItem] = [
            CommandItem(kind: .command, title: String(localized: "New Note"), symbol: "square.and.pencil", tint: .brandSky, keywords: "create add write", isSuggested: true) { [weak controller] in
                controller?.newNote(nil)
            },
            CommandItem(kind: .command, title: String(localized: "New To-do"), symbol: "checklist", tint: .brandTask, keywords: "create add task") { [weak controller] in
                controller?.newTodo(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Record Meeting"), symbol: "mic.fill", tint: .brandNavy, keywords: "start recording calendar appointment", isSuggested: true) { [weak controller] in
                controller?.recordMeeting(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Record Meeting Now"), subtitle: String(localized: "Without choosing an appointment"), symbol: "record.circle", tint: .brandNavy, keywords: "start recording") {
                GlobalShortcuts.recordMeetingNow()
            },
            CommandItem(
                kind: .command, title: DictationController.shared.isRecording ? String(localized: "Stop Dictation") : String(localized: "Start Dictation"),
                symbol: "mic", tint: .brandSky, keywords: "dictate speak voice", isSuggested: true
            ) {
                DictationController.shared.toggleFromMenu()
            },
            CommandItem(kind: .command, title: String(localized: "Add Link…"), symbol: "link", tint: .brandLink, keywords: "url web page") { [weak controller] in
                controller?.addLink(nil)
            },
            CommandItem(kind: .command, title: String(localized: "New Bowl…"), symbol: "folder.badge.plus", tint: .brandProject, keywords: "create") { [weak controller] in
                controller?.newBucket(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Weekly Review"), symbol: "calendar.badge.checkmark", tint: .brandNavy, keywords: "week summary", isSuggested: true) { [weak controller] in
                controller?.showWeeklyReview(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Open Settings"), symbol: "gearshape", tint: .systemGray, keywords: "preferences options", isSuggested: true) {
                NSApp.activate()
                SettingsWindowController.shared.show(tab: nil)
            },
            CommandItem(kind: .command, title: String(localized: "Go to Inbox"), symbol: "tray.fill", tint: .brandSky, keywords: "show") { [weak controller] in
                controller?.state.page = .inbox
            },
            CommandItem(kind: .command, title: String(localized: "Go to To-dos"), symbol: "checklist", tint: .brandTask, keywords: "show tasks") { [weak controller] in
                controller?.state.page = .todos
            },
            CommandItem(kind: .command, title: String(localized: "Chat"), symbol: "bubble.left.and.bubble.right", tint: .brandNavy, keywords: "ask question") { [weak controller] in
                controller?.openChat(nil)
            },
        ]
        // A note or to-do from each note template.
        for template in NoteTemplateStore.shared.templates {
            items.append(CommandItem(
                kind: .command, title: String(localized: "New from Template: \(template.name)"), subtitle: template.kind.title,
                symbol: "doc.on.doc", tint: template.isTodo ? .brandTask : .brandSky, keywords: "create add template"
            ) { [weak controller] in
                controller?.newFromTemplate(template)
            })
        }
        // The selected entries into a bowl or back to the Inbox.
        // Entries in a bowl shared with me to view only stay where they are.
        let selected = controller.selectedNotes.filter { $0.modelContext != nil && !$0.isDeleted && !BowlSharing.shared.isReadOnly($0) }
        if !selected.isEmpty {
            let what = selected.count == 1 ? "“\(selected[0].displayTitle)”" : String(localized: "\(selected.count) entries")
            let context = Library.shared.context
            if !selected.allSatisfy(\.isInInbox) {
                items.append(CommandItem(kind: .command, title: String(localized: "Move to Inbox"), subtitle: what, symbol: "tray", tint: .brandSky, keywords: "bowl file") {
                    Undoable.move(selected, toBowl: nil, named: nil, in: context)
                })
            }
            for project in Library.shared.activeProjects where !BowlSharing.shared.isReadOnly(project.id) {
                let key = Projects.key(project)
                guard !selected.allSatisfy({ $0.projectIDs == [key] }) else { continue }
                items.append(CommandItem(kind: .command, title: String(localized: "Move to \(project.name)"), subtitle: what, symbol: "folder", tint: .brandProject, keywords: "bowl file") {
                    Undoable.move(selected, toBowl: key, named: project.name, in: context)
                })
            }
        }
        return items
    }

    private static func bowlItems(for controller: MainWindowController) -> [CommandItem] {
        Library.shared.projects.map { project in
            CommandItem(
                kind: .bowl, title: project.name, subtitle: project.isArchived ? String(localized: "Archived") : nil,
                symbol: project.isArchived ? "archivebox" : "folder.fill", tint: .brandProject, keywords: "go to bowl"
            ) { [weak controller] in
                controller?.state.page = .project(project.id)
            }
        }
    }

    private static func entryItem(_ note: Note, controller: MainWindowController) -> CommandItem {
        let bowl = note.projectIDs.first.flatMap { Library.shared.project(key: $0)?.name } ?? String(localized: "Inbox")
        let date = note.createdAt.formatted(date: .abbreviated, time: .omitted)
        let id = note.id
        return CommandItem(kind: .entry, title: note.displayTitle, subtitle: "\(note.kindName) · \(bowl) · \(date)", symbol: note.kindSymbol, tint: .brandNavy) { [weak controller] in
            guard let controller, let note = Library.shared.note(id) else { return }
            controller.state.reveal(note)
        }
    }
}

/// The command bar (⌘K): one field to find a command, a bowl or an entry and run it with Return. Arrows move through
/// the list, Escape closes it, clicking elsewhere too.
@MainActor
final class CommandBarController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static var current: CommandBarController?

    private let panel: CommandBarPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint?
    private weak var controller: MainWindowController?
    private var items: [CommandItem] = []

    private static let width: CGFloat = 600
    private static let rowHeight: CGFloat = 40
    private static let maxRows = 9

    static func show(for controller: MainWindowController) {
        if let current {
            current.close()
        }
        let bar = CommandBarController(controller: controller)
        current = bar
        bar.present()
    }

    private init(controller: MainWindowController) {
        self.controller = controller
        panel = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.setAccessibilityLabel(String(localized: "Command Bar"))

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        panel.contentView = background

        field.placeholderString = String(localized: "Search entries, bowls and commands")
        field.font = .systemFont(ofSize: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel(String(localized: "Command Bar"))

        let icon = NSImageView(image: .symbol("magnifyingglass", size: 18, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(icon)
        background.addSubview(field)
        background.addSubview(line)
        background.addSubview(scroll)
        let height = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * 6)
        heightConstraint = height
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            field.topAnchor.constraint(equalTo: background.topAnchor, constant: 14),
            line.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            line.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
            height,
        ])
    }

    private func present() {
        guard let window = controller?.window else { return }
        window.makeKeyAndOrderFront(nil)
        update()
        let frame = window.frame
        let size = panel.contentView?.fittingSize ?? NSSize(width: Self.width, height: 300)
        let width = min(Self.width, frame.width - 40)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 110 - size.height, width: width, height: size.height), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func close() {
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    private func update() {
        guard let controller else { return }
        items = CommandBarItems.items(for: field.stringValue, controller: controller)
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        let rows = CGFloat(min(max(items.count, 1), Self.maxRows))
        let height = rows * Self.rowHeight
        guard heightConstraint?.constant != height else { return }
        heightConstraint?.constant = height
        // Keep the top edge where it is.
        if panel.isVisible, let content = panel.contentView {
            content.layoutSubtreeIfNeeded()
            let fitting = content.fittingSize.height
            var frame = panel.frame
            frame.origin.y += frame.height - fitting
            frame.size.height = fitting
            panel.setFrame(frame, display: true)
        }
    }

    private func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        let window = controller?.window
        close()
        window?.makeKeyAndOrderFront(nil)
        item.run()
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        runSelected()
    }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) {
        update()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    private func move(by offset: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + offset))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: CommandBarCell.identifier, owner: nil) as? CommandBarCell) ?? CommandBarCell()
        cell.show(items[row])
        return cell
    }
}

/// A borderless panel that can still take the keyboard.
private final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CommandBarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("CommandBarCell")

    private let icon = NSImageView()
    private let title = NSTextField.label(font: .systemFont(ofSize: 14))
    private let subtitle = NSTextField.label(font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
    private let kind = NSTextField.label(font: .systemFont(ofSize: 11), color: .tertiaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        let texts = NSStackView.vertical([title, subtitle], spacing: 1)
        let row = NSStackView.horizontal([icon, texts, NSView(), kind], spacing: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 20),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: CommandItem) {
        icon.image = .symbol(item.symbol, size: 14, weight: .medium)
        icon.contentTintColor = item.tint.readable
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        kind.stringValue = item.kind.label
        setAccessibilityLabel([item.title, item.subtitle, item.kind.label].compactMap { $0 }.joined(separator: ", "))
    }
}
