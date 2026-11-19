import AppKit
import SwiftData

/// The middle column: the notes of the page chosen in the sidebar, in sections, newest first. Notes can be
/// dragged onto buckets in the sidebar; files, pictures and links dropped here come into the page.
final class NoteListViewController: NSViewController, NSTableViewDelegate, NSMenuDelegate {
    private let state: WindowState
    private let library = Library.shared
    private let table = NoteTableView()
    private let scroll = NSScrollView()
    private let header = ListHeaderView()
    private let empty = EmptyMessageView()
    private var dataSource: NoteListDataSource!
    private var sectionsByID: [String: ListSection] = [:]
    private var libraryToken: UUID?
    private var observers: [Observing] = []
    private var shownPage: SidebarPage?
    private var isSyncingSelection = false

    init(state: WindowState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            library.stopObserving(libraryToken)
            observers.cancelAll()
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.floatsGroupRows = true
        table.delegate = self
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.registerForDraggedTypes(Intake.pasteboardTypes)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.target = self
        table.doubleAction = #selector(openInNewWindow(_:))
        table.onIntake = { [weak self] pasteboard in
            guard let self else { return false }
            return Intake.accept(pasteboard, project: self.state.projectForNew, state: self.state)
        }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityLabel("Notes")

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(empty)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            empty.topAnchor.constraint(equalTo: header.bottomAnchor),
            empty.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            empty.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        dataSource = NoteListDataSource(tableView: table) { [weak self] table, _, row, item in
            self?.cell(for: item, in: table) ?? NSView()
        }
        dataSource.onIntake = { [weak self] pasteboard in
            guard let self else { return false }
            return Intake.accept(pasteboard, project: self.state.projectForNew, state: self.state)
        }
        dataSource.sectionHeaderViewProvider = { [weak self] table, row, section in
            let cell = table.makeView(withIdentifier: SectionHeaderCell.identifier, owner: nil) as? SectionHeaderCell ?? SectionHeaderCell()
            let shown = self?.sectionsByID[section.id] ?? section
            cell.show(shown)
            return cell
        }
        dataSource.rowViewProvider = { table, row, item in
            (item.base is ListSection) ? GroupRowView() : NSTableRowView()
        }
        header.onFilter = { [weak self] kind in self?.state.kindFilter = kind }
        header.onTag = { [weak self] tag in
            guard let self else { return }
            if !self.state.searchTags.contains(where: { $0.lowercased() == tag.lowercased() }) { self.state.searchTags.append(tag) }
        }
        header.onRemoveTag = { [weak self] tag in self?.state.searchTags.removeAll { $0.lowercased() == tag.lowercased() } }
        header.onEmptyTrash = { [weak self] in
            guard let self, let window = self.view.window else { return }
            NoteOperations.confirmEmptyTrash(in: window, state: self.state)
        }

        libraryToken = library.observe { [weak self] in self?.reload() }
        observers.append(Observing { [weak self] in
            guard let self else { return }
            // Read what the list depends on, so a change of it rebuilds the list.
            _ = (self.state.page, self.state.kindFilter, self.state.searchText, self.state.searchTags)
            self.reload()
        })
        observers.append(Observing { [weak self] in
            guard let self else { return }
            _ = self.state.selection
            self.syncSelection()
        })
    }

    // MARK: Content

    private func reload() {
        let built = NoteListContent.build(for: state, library: library)
        let pageChanged = shownPage != state.page
        shownPage = state.page
        var snapshot = NSDiffableDataSourceSnapshot<ListSection, ListItem>()
        sectionsByID = [:]
        for (section, items) in built.sections {
            // A section of the same id keeps its place; its title may have changed.
            snapshot.appendSections([section])
            snapshot.appendItems(items, toSection: section)
            sectionsByID[section.id] = section
        }
        isSyncingSelection = true
        dataSource.apply(snapshot, animatingDifferences: !pageChanged && view.window != nil)
        isSyncingSelection = false
        header.show(page: state.page, library: library, state: state, kindCounts: built.kindCounts)
        let isEmpty = built.sections.isEmpty
        empty.isHidden = !isEmpty || state.page == .chat
        scroll.isHidden = isEmpty
        if isEmpty { empty.show(title: built.emptyTitle, message: built.emptyMessage, symbol: built.emptySymbol) }
        syncSelection()
        if pageChanged { table.scrollRowToVisible(0) }
    }

    private func cell(for item: ListItem, in table: NSTableView) -> NSView {
        switch item {
        case .note(let id):
            let cell = table.makeView(withIdentifier: NoteCellView.identifier, owner: nil) as? NoteCellView ?? NoteCellView()
            if let note = library.note(id) {
                cell.show(note, buckets: library.activeProjects, showsSuggestions: state.page == .inbox)
                cell.onToggleDone = { note in TodoBridge.setDone(!TodoBridge.isDone(note), note) }
            }
            return cell
        case .project(let id):
            let cell = table.makeView(withIdentifier: BucketCellView.identifier, owner: nil) as? BucketCellView ?? BucketCellView()
            if let project = library.project(id) { cell.show(project, notes: library.notes) }
            return cell
        }
    }

    private func syncSelection() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        var rows = IndexSet()
        for id in state.selection {
            if let row = dataSource.row(forItemIdentifier: .note(id)), row >= 0 { rows.insert(row) }
        }
        if table.selectedRowIndexes != rows {
            table.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first { table.scrollRowToVisible(first) }
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        var ids: [UUID] = []
        for row in table.selectedRowIndexes {
            switch dataSource.itemIdentifier(forRow: row) {
            case .note(let id)?: ids.append(id)
            case .project(let id)?:
                // An archived bucket opens like any bucket.
                state.page = .project(id)
                return
            case nil: break
            }
        }
        // A new note that was not written in yet stays open until another one is chosen.
        if ids != state.selection { state.selection = ids }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        dataSource.itemIdentifier(forRow: row) != nil
    }

    /// The notes the context menu or a command is about: the clicked row (with the selection when it is in it).
    var targetedNotes: [Note] {
        let clicked = table.clickedRow
        var rows = table.selectedRowIndexes
        if clicked >= 0, !rows.contains(clicked) { rows = [clicked] }
        return rows.compactMap { row in
            if case .note(let id)? = dataSource.itemIdentifier(forRow: row) { return library.note(id) }
            return nil
        }
    }

    func focusList() {
        view.window?.makeFirstResponder(table)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        if clicked >= 0, case .project(let id)? = dataSource.itemIdentifier(forRow: clicked), let project = library.project(id) {
            BucketActions.addItems(for: project, to: menu, state: state, window: view.window)
            return
        }
        let notes = targetedNotes
        guard !notes.isEmpty else { return }
        NoteOperations.addItems(for: notes, to: menu, state: state, window: view.window)
    }

    @objc private func openInNewWindow(_ sender: Any?) {
        guard table.clickedRow >= 0, case .note(let id)? = dataSource.itemIdentifier(forRow: table.clickedRow) else { return }
        NoteWindowController.open(id)
    }
}

/// The rows of the list, which also drag out as notes and take files, links and text dropped on the list.
final class NoteListDataSource: NSTableViewDiffableDataSource<ListSection, ListItem> {
    var onIntake: ((NSPasteboard) -> Bool)?

    @objc func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .note(let id)? = itemIdentifier(forRow: row) else { return nil }
        return MainActor.assumeIsolated {
            guard let note = Library.shared.note(id) else { return nil }
            return NotePasteboard.item(for: note)
        }
    }

    @objc func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Notes are moved onto buckets in the sidebar; here only what comes from outside is taken.
        guard info.draggingPasteboard.availableType(from: [.porridgeNote]) == nil else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    @objc func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        onIntake?(info.draggingPasteboard) ?? false
    }
}

/// The table of the list: ⌘V brings in what is on the clipboard, Delete moves the selection to Recently Deleted.
final class NoteTableView: NSTableView {
    var onIntake: ((NSPasteboard) -> Bool)?

    /// ⌘V on the list brings in what is on the clipboard: files, a picture, a link or text.
    @objc func paste(_ sender: Any?) {
        _ = onIntake?(.general)
    }

    override func keyDown(with event: NSEvent) {
        // Delete moves the selected notes to Recently Deleted.
        if event.keyCode == 51 || event.keyCode == 117, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.command).isEmpty {
            NSApp.sendAction(#selector(MainWindowController.deleteNote(_:)), to: nil, from: self)
            return
        }
        super.keyDown(with: event)
    }
}

/// The header of a section: small and bold in the color of its kind.
private final class SectionHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("section")
    private let title = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .bold))
    private let footnote = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let stack = NSStackView.vertical([title, footnote], spacing: 2)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ section: ListSection) {
        title.stringValue = section.title
        title.textColor = switch section.tint {
        case .sky: .brandSkyText
        case .navy: .brandNavy
        case .project: .brandProject
        case .link: .brandLinkText
        case .red: .brandDangerText
        }
        title.isHidden = section.title.isEmpty
        footnote.stringValue = section.footnote ?? ""
        footnote.isHidden = section.footnote == nil
        setAccessibilityLabel(section.title)
    }
}

/// Group rows draw no selection and keep the page's background.
private final class GroupRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
}

/// An archived bucket in the archive's list.
final class BucketCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("bucket")
    private let icon = KindIconView()
    private let name = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium))
    private let summary = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbol = "folder.fill"
        icon.tint = .brandProject
        let text = NSStackView.vertical([name, summary], spacing: 3)
        let row = NSStackView.horizontal([icon, text], spacing: 12, alignment: .top)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ project: NoteFolder, notes: [Note]) {
        name.stringValue = project.name
        let key = Projects.key(project)
        let count = notes.lazy.filter { !$0.isDeleted && !$0.isArchived && $0.projectIDs.contains(key) }.count
        summary.stringValue = count == 0 ? String(localized: "Empty") : String(localized: "\(count) entries")
        icon.isPinned = project.isPinned
        setAccessibilityLabel("Bucket \(project.name), \(summary.stringValue)")
    }
}
