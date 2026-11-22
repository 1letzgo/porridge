import AppKit
import SwiftData

/// The middle column: the notes of the page chosen in the sidebar, in sections, newest first. Notes can be
/// dragged onto bowls in the sidebar; files, pictures and links dropped here come into the page.
final class NoteListViewController: NSViewController, NSTableViewDelegate, NSMenuDelegate {
    private let state: WindowState
    private let library = Library.shared
    private let table = NoteTableView()
    private let scroll = NSScrollView()
    private let header = ListHeaderView()
    private let empty = EmptyMessageView()
    /// On top of the Inbox: entries that belong together, suggested as a new bowl.
    private let bundleBanner = InboxBundleBanner()
    private var dataSource: NoteListDataSource!
    private var sectionsByID: [String: ListSection] = [:]
    private var libraryToken: UUID?
    private var observers: [Observing] = []
    private var shownPage: SidebarPage?
    private var isSyncingSelection = false
    /// Snapshots still being applied.
    private var isApplying = 0

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
        root.addSubview(bundleBanner)
        root.addSubview(scroll)
        root.addSubview(empty)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bundleBanner.topAnchor.constraint(equalTo: header.bottomAnchor),
            bundleBanner.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bundleBanner.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bundleBanner.bottomAnchor),
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
        header.onReview = { [weak self] in
            (self?.view.window?.windowController as? MainWindowController)?.showWeeklyReview(nil)
        }
        header.onHint = { [weak self] hint in
            DailyHintFeed.open(hint, in: self?.view.window?.windowController as? MainWindowController)
        }
        header.onTriage = { [weak self] in self?.toggleTriage() }
        header.onToggleLater = { [weak self] in self?.state.showsLater.toggle() }
        table.onKey = { [weak self] event in self?.handleTriageKey(event) ?? false }
        header.onEmptyTrash = { [weak self] in
            guard let self, let window = self.view.window else { return }
            NoteOperations.confirmEmptyTrash(in: window, state: self.state)
        }

        libraryToken = library.observe { [weak self] in self?.reload() }
        observers.append(Observing { [weak self] in
            guard let self else { return }
            // Read what the list depends on, so a change of it rebuilds the list.
            _ = (self.state.page, self.state.kindFilter, self.state.searchText, self.state.searchTags, self.state.showsLater, self.state.isTriaging)
            // A smart filter changed (here or on another device), and the index while it loads.
            if self.state.page.smartFilterID != nil { _ = (SmartFilterStore.shared.filters, NoteIndex.shared.version) }
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
        // While rows move the table keeps its selection by row number and reports that after the animation:
        // it is not the user's choice, so the open note stays the one of the state.
        isApplying += 1
        dataSource.apply(snapshot, animatingDifferences: !pageChanged && view.window != nil) { [weak self] in
            guard let self else { return }
            self.isApplying -= 1
            self.syncSelection()
        }
        header.show(page: state.page, library: library, state: state, kindCounts: built.kindCounts)
        bundleBanner.host = self
        bundleBanner.refresh(isInbox: state.page == .inbox && state.searchText.isEmpty)
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
                cell.show(note, buckets: library.activeProjects, showsSuggestions: state.page == .inbox, namesBuckets: state.page == .todos || state.page.smartFilterID != nil)
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
        guard !isSyncingSelection, isApplying == 0 else { return }
        var ids: [UUID] = []
        for row in table.selectedRowIndexes {
            switch dataSource.itemIdentifier(forRow: row) {
            case .note(let id)?: ids.append(id)
            case .project(let id)?:
                // An archived bowl opens like any bowl.
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

    // MARK: Triage

    /// Triage on or off; on, the list takes the keys and the first entry is chosen when none is.
    func toggleTriage() {
        guard state.page == .inbox else { return }
        state.isTriaging.toggle()
        guard state.isTriaging else { return }
        focusList()
        if state.selection.isEmpty, let first = triageIDs.first { state.selection = [first] }
    }

    /// The entries of the Inbox in the order of the list (those back from later included, the "Later" section not).
    private var triageIDs: [UUID] {
        let snapshot = dataSource.snapshot()
        guard let section = snapshot.sectionIdentifiers.first(where: { $0.id == "inbox" }) else { return [] }
        return snapshot.itemIdentifiers(inSection: section).compactMap { item in
            if case .note(let id) = item { return id }
            return nil
        }
    }

    /// J/K, L, F, D and Esc while the Inbox is in triage. Returns whether the key was taken.
    private func handleTriageKey(_ event: NSEvent) -> Bool {
        guard state.isTriaging, state.page == .inbox else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags.isEmpty else { return false }
        if event.keyCode == 53 {
            state.isTriaging = false
            return true
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j": step(1)
        case "k": step(-1)
        case "l": triageLater()
        case "f": triageFile()
        case "d": triageDone()
        default: return false
        }
        return true
    }

    private var triageNote: Note? {
        guard let id = state.selection.first, state.selection.count == 1, triageIDs.contains(id) else { return nil }
        return library.note(id)
    }

    private func step(_ delta: Int) {
        let ids = triageIDs
        guard !ids.isEmpty else { return NSSound.beep() }
        let index = state.selection.first.flatMap { ids.firstIndex(of: $0) }
        let next = index.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
        state.selection = [ids[next]]
        if let row = dataSource.row(forItemIdentifier: .note(ids[next])), row >= 0 { table.scrollRowToVisible(row) }
    }

    /// The entry that is chosen once `id` has left the list: the one after it, or before it at the end.
    private func neighbor(of id: UUID) -> UUID? {
        let ids = triageIDs
        guard let index = ids.firstIndex(of: id) else { return nil }
        if index + 1 < ids.count { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }

    /// Where a menu for the chosen entry opens: under its title.
    private func popUp(_ menu: NSMenu, for note: Note) {
        guard let row = dataSource.row(forItemIdentifier: .note(note.id)), row >= 0 else { return }
        let rect = table.rect(ofRow: row)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 44, y: rect.minY + 30), in: table)
    }

    /// L: the "Later" choices; the next entry is chosen when it went.
    private func triageLater() {
        guard let note = triageNote, !BowlSharing.shared.isReadOnly(note) else { return NSSound.beep() }
        let next = neighbor(of: note.id)
        let menu = NoteOperations.laterMenu(for: [note], window: view.window) { [weak self] in
            self?.state.selection = next.map { [$0] } ?? []
        }
        popUp(menu, for: note)
    }

    /// F: the bowls, as in the context menu; the next entry is chosen when it was filed.
    private func triageFile() {
        guard let note = triageNote, !BowlSharing.shared.isReadOnly(note) else { return NSSound.beep() }
        let next = neighbor(of: note.id)
        popUp(NoteOperations.bucketMenu(for: [note], window: view.window), for: note)
        DispatchQueue.main.async { [weak self] in
            guard let self, !note.isInInbox, self.state.selection == [note.id] else { return }
            self.state.selection = next.map { [$0] } ?? []
        }
    }

    /// D: a to-do done (it stays in the Inbox, ticked), then on to the next. Other entries have nothing to be done.
    private func triageDone() {
        guard let note = triageNote, note.isTodo, !note.isDone, !BowlSharing.shared.isReadOnly(note) else { return NSSound.beep() }
        Undoable.run(String(localized: "Done: “\(note.displayTitle)”"), systemImage: "checkmark.square", notes: [note], in: library.context) {
            TodoBridge.setDone(true, note)
        }
        step(1)
    }

    @objc private func openInNewWindow(_ sender: Any?) {
        guard table.clickedRow >= 0, case .note(let id)? = dataSource.itemIdentifier(forRow: table.clickedRow) else { return }
        NoteWindowController.open(id)
    }
}

/// The rows of the list, which also drag out as notes and take files, links and text dropped on the list.
final class NoteListDataSource: NSTableViewDiffableDataSource<ListSection, ListItem> {
    @objc func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard case .note(let id)? = itemIdentifier(forRow: row) else { return nil }
        return MainActor.assumeIsolated {
            guard let note = Library.shared.note(id) else { return nil }
            return NotePasteboard.item(for: note)
        }
    }
    // Drops from other apps land on the column around it (`ImportDropView`).
}

/// The table of the list: ⌘V brings in what is on the clipboard, Delete moves the selection to Recently Deleted.
final class NoteTableView: NSTableView {
    var onIntake: ((NSPasteboard) -> Bool)?
    /// Keys taken before the table's own (the Inbox's triage).
    var onKey: ((NSEvent) -> Bool)?

    /// ⌘V on the list brings in what is on the clipboard: files, a picture, a link or text.
    @objc func paste(_ sender: Any?) {
        _ = onIntake?(.general)
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
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
    private let count = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .semibold), color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let stack = NSStackView.vertical([NSStackView.horizontal([title, count], spacing: 6), footnote], spacing: 2)
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
        case .task: .brandTaskText
        }
        title.isHidden = section.title.isEmpty
        count.stringValue = section.count.map { "\($0)" } ?? ""
        count.isHidden = section.count == nil
        footnote.stringValue = section.footnote ?? ""
        footnote.isHidden = section.footnote == nil
        setAccessibilityLabel(section.count.map { "\(section.title), \($0)" } ?? section.title)
    }
}

/// Group rows draw no selection and keep the page's background.
private final class GroupRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
}

/// An archived bowl in the archive's list.
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
        let count = notes.lazy.filter { !$0.isDeleted && $0.projectIDs.contains(key) }.count
        summary.stringValue = count == 0 ? String(localized: "Empty") : String(localized: "\(count) entries")
        icon.isPinned = project.isPinned
        setAccessibilityLabel("Bowl \(project.name), \(summary.stringValue)")
    }
}
