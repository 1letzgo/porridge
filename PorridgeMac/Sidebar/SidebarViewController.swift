import AppKit
import SwiftData

/// A row of the sidebar.
private final class SidebarNode: NSObject {
    enum Kind: Equatable {
        case page(SidebarPage)
        case group(String)
        /// A row that does something instead of showing a page ("New Smart Filter…").
        case action(String)
    }

    let kind: Kind
    var children: [SidebarNode] = []

    init(_ kind: Kind, children: [SidebarNode] = []) {
        self.kind = kind
        self.children = children
    }

    var page: SidebarPage? {
        if case .page(let page) = kind { page } else { nil }
    }

    override func isEqual(_ object: Any?) -> Bool {
        (object as? SidebarNode)?.kind == kind
    }

    override var hash: Int {
        switch kind {
        case .page(let page): page.hashValue
        case .group(let name): name.hashValue
        case .action(let name): ("action-" + name).hashValue
        }
    }
}

/// The sidebar as a source list: the places Today, Inbox, To-dos, Bowls and Chat (⌘1–5; Bowls unfolds into every bowl
/// in the order of Sort Bowls By, no limit), the smart filters with "New Smart Filter…", then Archive and Recently
/// Deleted (⌘6, ⌘7), always there. Notes dropped on a bowl go into it; files dropped on it are brought in there.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    private let state: WindowState
    private let library = Library.shared
    private let outline = NSOutlineView()
    private var roots: [SidebarNode] = []
    private var libraryToken: UUID?
    private var observers: [Observing] = []
    private var isSyncingSelection = false
    /// The bowl whose name is being edited in place.
    private var renaming: NoteFolder?
    /// The smart filter whose name is being edited in place.
    private var renamingFilter: SmartFilter?
    /// The content changed while a name was edited.
    private var rebuildAfterRename = false
    /// Rows folded by hand (Bowls, Smart Filters): they stay folded when the sidebar is built again.
    private var collapsed = Set<Int>()

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
        column.isEditable = true
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.autosaveExpandedItems = false
        outline.allowsEmptySelection = true
        outline.registerForDraggedTypes([.porridgeNote] + Intake.pasteboardTypes)
        outline.setDraggingSourceOperationMask(.every, forLocal: false)
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.setAccessibilityLabel("Sidebar")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuild()
        libraryToken = library.observe { [weak self] in self?.rebuild() }
        observers.append(Observing { [weak self] in
            guard let self else { return }
            _ = self.state.page
            self.syncSelection()
        })
        // The mark of shared bowls follows the shares (only they are watched here, not what the rebuild reads).
        var firstRun = true
        observers.append(Observing { [weak self] in
            _ = BowlSharing.shared.bowls
            guard !firstRun else { firstRun = false; return }
            Task { @MainActor in
                // What arrives for the bowl that is open is seen there (its entries keep their own mark).
                BowlSharing.shared.markVisited(self?.state.page.projectID)
                self?.rebuild()
            }
        })
        // The smart filters follow their file (changed here or on another device).
        var firstFilters = true
        observers.append(Observing { [weak self] in
            _ = SmartFilterStore.shared.filters
            guard !firstFilters else { firstFilters = false; return }
            Task { @MainActor in self?.rebuild() }
        })
    }

    // MARK: Content

    private func rebuild() {
        // While a name is edited the rows stay as they are (the outline still shows the old nodes): built once
        // the editing ends.
        guard renaming == nil, renamingFilter == nil else {
            rebuildAfterRename = true
            return
        }
        rebuildAfterRename = false
        let notes = library.notes
        // Every bowl, pinned first, in the order the iPhone's Bowls place uses (Settings › General › Sort Bowls By).
        let bowls = HomeList.bowls(library.projects, notes: notes)
        var top: [SidebarNode] = [
            SidebarNode(.page(.today)),
            SidebarNode(.page(.inbox)),
            // Every open to-do (owner revision 13: a row of its own again, no segment in the Bowls head).
            SidebarNode(.page(.todos)),
            SidebarNode(.page(.bowls), children: bowls.map { SidebarNode(.page(.project($0.id))) }),
            // The chat is the fifth place (⌘5): its chats in the list column, the open one in the detail.
            SidebarNode(.page(.chat)),
        ]
        let filters = SmartFilterStore.shared.filters
        top.append(SidebarNode(.group("Smart Filters"), children: filters.map { SidebarNode(.page(.smartFilter($0.id))) } + [SidebarNode(.action("newSmartFilter"))]))
        // Always there, also when empty.
        top.append(SidebarNode(.page(.archive)))
        top.append(SidebarNode(.page(.trash)))
        roots = top
        isSyncingSelection = true
        outline.reloadData()
        for node in roots where !node.children.isEmpty && !collapsed.contains(node.hash) { outline.expandItem(node) }
        isSyncingSelection = false
        syncSelection()
    }

    private func node(for page: SidebarPage) -> SidebarNode? {
        for node in roots {
            if node.page == page { return node }
            if let child = node.children.first(where: { $0.page == page }) { return child }
        }
        return nil
    }

    private func syncSelection() {
        isSyncingSelection = true
        defer { isSyncingSelection = false }
        if let node = node(for: state.page) {
            let row = outline.row(forItem: node)
            if row >= 0, outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
        } else {
            outline.deselectAll(nil)
        }
    }

    #if DEBUG
    /// Where the rows are drawn: the outline's frame, and each row's rect and cell title (debug driver).
    var debugGeometry: String {
        let rows = (0..<min(outline.numberOfRows, 4)).map { row -> String in
            let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
            return "\(outline.rect(ofRow: row)) '\(cell?.textField?.stringValue ?? "-")' hidden=\(cell?.isHidden ?? true) alpha=\(cell?.alphaValue ?? 0)"
        }
        return "outline=\(outline.frame) visible=\(outline.visibleRect) window=\(outline.window != nil) " + rows.joined(separator: "; ")
    }

    /// The rows as drawn, for the debug driver: "name" or "[group]", with a "+" when a group is expanded.
    var debugRows: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SidebarNode else { return nil }
            switch node.kind {
            case .group(let name): return "[\(name)\(outline.isItemExpanded(node) ? "+" : "-")]"
            case .action(let name): return "(\(name))"
            case .page(let page):
                if case .project(let id) = page { return library.project(id)?.name ?? "?" }
                if case .smartFilter(let id) = page { return SmartFilterStore.shared.filter(id)?.name ?? "?" }
                let count = (cellBadge(for: page)).map { " \($0)" } ?? ""
                return "\(page)" + (node.children.isEmpty ? "" : outline.isItemExpanded(node) ? "+" : "-") + count
            }
        }
    }
    #endif

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .group = node.kind { return true }
        return !node.children.isEmpty
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? SidebarNode { collapsed.insert(node.hash) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? SidebarNode { collapsed.remove(node.hash) }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .group = (item as? SidebarNode)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? SidebarNode else { return false }
        if case .action = node.kind {
            // "New Smart Filter…": the editor, the page stays.
            if !isSyncingSelection { newSmartFilter() }
            return false
        }
        return node.page != nil
    }

    /// "New Smart Filter…": the editor with nothing asked yet; the new filter opens.
    @objc func newSmartFilter() {
        let state = state
        SmartFilterSheet.create(SmartFilterCriteria(), in: view.window) { state.page = .smartFilter($0.id) }
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        switch node.kind {
        case .group(let name):
            let cell = outlineView.makeView(withIdentifier: .init("group"), owner: self) as? NSTableCellView ?? makeGroupCell()
            cell.textField?.stringValue = name
            return cell
        case .page(let page):
            let cell = outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: self) as? SidebarCell ?? SidebarCell()
            configure(cell, for: page)
            return cell
        case .action:
            let cell = outlineView.makeView(withIdentifier: SidebarCell.identifier, owner: self) as? SidebarCell ?? SidebarCell()
            cell.configure(title: String(localized: "New Smart Filter…"), symbol: "plus", tint: .secondaryLabelColor, badge: 0)
            cell.textField?.isEditable = false
            cell.textField?.textColor = .secondaryLabelColor
            return cell
        }
    }

    /// The count of a page's row: what is due today, what waits in the Inbox, the archived bowls, the deleted entries.
    private func cellBadge(for page: SidebarPage) -> Int? {
        let notes = library.notes
        switch page {
        case .today: return Places.todayCount(notes)
        case .inbox: return Places.inboxCount(notes)
        case .todos: return Todos.folder(notes).open
        case .archive: return HomeList.archivedProjects(library.projects).count
        case .trash: return notes.lazy.filter(\.isDeleted).count
        default: return nil
        }
    }

    private func makeGroupCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = .init("group")
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configure(_ cell: SidebarCell, for page: SidebarPage) {
        let notes = library.notes
        switch page {
        case .today:
            // The to-dos due today or before, as on the iPhone's tab (`Places`).
            cell.configure(title: "Today", symbol: "calendar", tint: .brandNavy, badge: cellBadge(for: page) ?? 0)
        case .inbox:
            cell.configure(title: "Inbox", symbol: "tray.fill", tint: .brandSky, badge: cellBadge(for: .inbox) ?? 0)
        case .todos:
            // The to-do's symbol in its green, the open ones counted.
            cell.configure(title: "To-dos", symbol: "checklist", tint: .brandTask, badge: cellBadge(for: .todos) ?? 0)
        case .bowls:
            // A bowl of the app's own (SF Symbols has none); single bowls keep the folder.
            cell.configure(title: "Bowls", symbol: Places.bowlsSymbol, tint: .brandProject, badge: 0)
        case .chat:
            cell.configure(title: "Chat", symbol: "bubble.left.and.bubble.right.fill", tint: .brandNavy, badge: 0)
        case .project(let id):
            let project = library.project(id)
            // What is in the bowl and not deleted, as the bowl's page lists it.
            let key = project.map(Projects.key)
            let count = key.map { key in notes.lazy.filter { !$0.isDeleted && $0.projectIDs.contains(key) }.count } ?? 0
            cell.configure(
                title: project?.name ?? "Bowl", symbol: "folder.fill", tint: .brandProject, badge: count, pinned: project?.isPinned == true,
                shared: BowlSharing.shared.info(for: id)
            )
        case .smartFilter(let id):
            let filter = SmartFilterStore.shared.filter(id)
            let count = filter.map { SmartFilters.results($0.criteria, in: notes).count } ?? 0
            cell.configure(title: filter?.name ?? String(localized: "Smart Filter"), symbol: "line.3.horizontal.decrease", tint: .brandNavy, badge: count)
        case .archive:
            cell.configure(title: "Archive", symbol: "archivebox.fill", tint: .brandNavy, badge: cellBadge(for: page) ?? 0)
        case .trash:
            cell.configure(title: "Recently Deleted", symbol: "trash.fill", tint: .systemRed, badge: cellBadge(for: page) ?? 0)
        case .search:
            cell.configure(title: "Search", symbol: "magnifyingglass", tint: .brandNavy, badge: 0)
        }
        cell.textField?.delegate = self
        cell.textField?.isEditable = false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncingSelection else { return }
        guard let node = outline.item(atRow: outline.selectedRow) as? SidebarNode, let page = node.page else { return }
        if state.page != page {
            state.page = page
        }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        if pasteboard.availableType(from: [.porridgeNote]) != nil {
            guard let page = (item as? SidebarNode)?.page, index == NSOutlineViewDropOnItemIndex else { return [] }
            // Entries of a bowl shared with me to view only stay where they are.
            let ids = NotePasteboard.noteIDs(from: pasteboard) ?? []
            if ids.contains(where: { library.note($0).map { BowlSharing.shared.isReadOnly($0) } ?? false }) { return [] }
            switch page {
            // A bowl shared with me to view only takes nothing.
            case .project(let id): return BowlSharing.shared.isReadOnly(id) ? [] : .move
            // Notes are never archived: the archive takes no notes.
            case .trash, .inbox: return .move
            default: return []
            }
        }
        // Files, pictures, links and text from outside: into the bowl under them, anywhere else into the inbox
        // (its row lights up). Folders alone are taken too, so the notice after the drop can say why they stay out.
        guard let plan = Intake.plan(pasteboard), plan.canImport || !plan.skipped.isEmpty else { return [] }
        if case .project(let id)? = (item as? SidebarNode)?.page, index == NSOutlineViewDropOnItemIndex, !BowlSharing.shared.isReadOnly(id) { return .copy }
        guard let inbox = node(for: .inbox) else { return [] }
        outlineView.setDropItem(inbox, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let page = (item as? SidebarNode)?.page else { return false }
        let pasteboard = info.draggingPasteboard
        let context = library.context
        if let ids = NotePasteboard.noteIDs(from: pasteboard), !ids.isEmpty {
            let notes = ids.compactMap { library.note($0) }
            // Each with its undo toast (and ⌘Z).
            switch page {
            case .project(let id):
                Undoable.move(notes, toBowl: id.uuidString, named: library.project(id)?.name, in: context)
            case .inbox:
                Undoable.move(notes, toBowl: nil, named: nil, in: context)
            case .trash:
                Undoable.trash(notes, in: context)
            default:
                break
            }
            library.save()
            return true
        }
        let project = page.projectID?.uuidString
        return Intake.accept(pasteboard, project: project, state: state)
    }

    // MARK: Context menu and renaming

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let page = (outline.item(atRow: row) as? SidebarNode)?.page else {
            menu.addItem(withTitle: "New Bowl…", action: #selector(MainWindowController.newBucket(_:)), keyEquivalent: "")
            return
        }
        switch page {
        case .project(let id):
            guard let project = library.project(id) else { return }
            // The bowl's menu (the same as its ⋯ in the list head); Rename… edits the name in place.
            BucketActions.addItems(for: project, to: menu, state: state, window: view.window) { [weak self] in
                self?.beginRenaming(project)
            }
        case .smartFilter(let id):
            guard let filter = SmartFilterStore.shared.filter(id) else { return }
            let window = view.window
            let state = state
            menu.add("Edit…", symbol: "slider.horizontal.3") { SmartFilterSheet.edit(filter, in: window) }
            menu.add("Rename", symbol: "pencil") { [weak self] in self?.beginRenaming(filter) }
            menu.addItem(.separator())
            menu.add("Delete Smart Filter…", symbol: "trash", isDestructive: true) { SmartFilterSheet.confirmDelete(filter, state: state, in: window) }
        case .trash:
            menu.addItem(withTitle: "Delete All…", action: #selector(MainWindowController.emptyTrash(_:)), keyEquivalent: "")
        case .bowls:
            menu.addItem(withTitle: "New Bowl…", action: #selector(MainWindowController.newBucket(_:)), keyEquivalent: "")
            menu.add("New Smart Filter…", symbol: "line.3.horizontal.decrease") { [weak self] in self?.newSmartFilter() }
        default:
            menu.addItem(withTitle: "New Bowl…", action: #selector(MainWindowController.newBucket(_:)), keyEquivalent: "")
        }
    }

    @objc private func doubleClicked() {
        guard let page = (outline.item(atRow: outline.clickedRow) as? SidebarNode)?.page else { return }
        if case .smartFilter(let id) = page, let filter = SmartFilterStore.shared.filter(id) {
            SmartFilterSheet.edit(filter, in: view.window)
            return
        }
        guard case .project(let id) = page, let project = library.project(id) else { return }
        beginRenaming(project)
    }

    /// The smart filter's name becomes editable in place, as a bowl's.
    func beginRenaming(_ filter: SmartFilter) {
        guard let node = node(for: .smartFilter(filter.id)) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
              let field = cell.textField else { return }
        renamingFilter = filter
        field.isEditable = true
        field.stringValue = filter.name
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// The bowl's name becomes editable in place, as in the Finder's sidebar.
    func beginRenaming(_ project: NoteFolder) {
        guard let node = node(for: .project(project.id)) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
              let field = cell.textField else { return }
        renaming = project
        field.isEditable = true
        field.stringValue = project.name
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, let filter = renamingFilter {
            field.isEditable = false
            renamingFilter = nil
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name != filter.name {
                SmartFilterStore.shared.rename(filter.id, to: name)
            } else {
                field.stringValue = filter.name
            }
            rebuild()
            return
        }
        guard let field = obj.object as? NSTextField, let project = renaming else { return }
        field.isEditable = false
        renaming = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != project.name {
            Projects.rename(project, to: name, in: library.context)
        } else {
            field.stringValue = project.name
        }
        if rebuildAfterRename { rebuild() }
        library.setNeedsReload()
    }

    /// Escape while renaming keeps the old name.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let filter = renamingFilter {
            (control as? NSTextField)?.stringValue = filter.name
            view.window?.makeFirstResponder(outline)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let project = renaming {
            (control as? NSTextField)?.stringValue = project.name
            view.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }
}

/// One row of the sidebar: a symbol in the color of its kind, the name, and a count where it helps.
private final class SidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("page")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let pin = NSImageView()
    private let shared = NSImageView()
    /// "New since your last visit" of a shared bowl.
    private let newDot = NSView()
    private let alertBadge = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        pin.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        title.cell?.isScrollable = false
        title.focusRingType = .none
        badge.textColor = .secondaryLabelColor
        badge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        pin.image = .symbol("pin.fill", size: 9, weight: .semibold, label: "Pinned")
        pin.contentTintColor = .tertiaryLabelColor
        // A long name is cut, not the pin.
        pin.setContentCompressionResistancePriority(.required, for: .horizontal)
        shared.translatesAutoresizingMaskIntoConstraints = false
        shared.image = .symbol("person.2.fill", size: 9, weight: .semibold, label: "Shared")
        shared.contentTintColor = .tertiaryLabelColor
        shared.setContentCompressionResistancePriority(.required, for: .horizontal)
        newDot.translatesAutoresizingMaskIntoConstraints = false
        newDot.wantsLayer = true
        newDot.layer?.backgroundColor = NSColor.brandProject.cgColor
        newDot.layer?.cornerRadius = 3.5
        newDot.toolTip = String(localized: "New since your last visit")
        newDot.isHidden = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A stack leaves hidden parts out, so a hidden pin or count takes no room from the name.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        alertBadge.textColor = .brandDangerText
        alertBadge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        alertBadge.isHidden = true
        let row = NSStackView(views: [icon, title, shared, newDot, pin, spacer, alertBadge, badge])
        row.orientation = .horizontal
        row.spacing = 4
        row.setCustomSpacing(6, after: icon)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            newDot.widthAnchor.constraint(equalToConstant: 7),
            newDot.heightAnchor.constraint(equalToConstant: 7),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `alert`: a second count in red (the to-dos that are late).
    /// `shared`: the bowl is shared (mine) or shared with me; a small mark after the name (an eye when I may only
    /// view it), and a dot when someone else added or changed something since its page was last open here.
    func configure(
        title: String, symbol: String, tint: NSColor, badge count: Int, pinned: Bool = false, alert: Int = 0, shared info: SharedBowlInfo? = nil
    ) {
        shared.isHidden = info == nil
        shared.image = .symbol(info?.isReadOnly == true ? "eye.fill" : "person.2.fill", size: 9, weight: .semibold, label: "Shared")
        let isNew = info.map(SharedBowlActivity.hasNewSinceLastVisit) ?? false
        newDot.isHidden = !isNew
        let sharedText: String? = switch info?.role {
        case .owner: String(localized: "Shared")
        case .participant: info?.isReadOnly == true ? String(localized: "Shared with you to view only") : String(localized: "Shared with you")
        case nil: nil
        }
        alertBadge.stringValue = alert > 0 ? "\(alert)" : ""
        alertBadge.isHidden = alert == 0
        alertBadge.setAccessibilityLabel(alert > 0 ? "\(alert) overdue" : nil)
        icon.image = .symbol(symbol, size: 14, weight: .medium)
        icon.contentTintColor = tint.readable
        self.title.stringValue = title
        badge.stringValue = count > 0 ? "\(count)" : ""
        badge.isHidden = count == 0
        pin.isHidden = !pinned
        toolTip = title
        setAccessibilityLabel([
            title, sharedText, isNew ? String(localized: "New since your last visit") : nil, pinned ? String(localized: "Pinned") : nil, count > 0 ? "\(count)" : nil, alert > 0 ? String(localized: "\(alert) overdue") : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }
}
