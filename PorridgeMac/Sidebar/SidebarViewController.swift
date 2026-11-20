import AppKit
import SwiftData

/// A row of the sidebar.
private final class SidebarNode: NSObject {
    enum Kind: Equatable {
        case page(SidebarPage)
        case group(String)
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
        }
    }
}

/// The sidebar as a source list: Up Next (the Inbox and the to-dos folder), the buckets, then More (the chat, the
/// archive and Recently Deleted).
/// Notes dropped on a bucket go into it; files dropped on it are brought in there.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    private let state: WindowState
    private let library = Library.shared
    private let outline = NSOutlineView()
    private var roots: [SidebarNode] = []
    private var libraryToken: UUID?
    private var observers: [Observing] = []
    private var isSyncingSelection = false
    /// The bucket whose name is being edited in place.
    private var renaming: NoteFolder?

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
        outline.registerForDraggedTypes([.porridgeNote, .fileURL, .URL, .string])
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
    }

    // MARK: Content

    private func rebuild() {
        let notes = library.notes
        let buckets = library.activeProjects
        // Pinned buckets first, then by name.
        let sorted = buckets.filter(\.isPinned) + buckets.filter { !$0.isPinned }
        // "Up Next", as the section of the home list on iOS and Android: the Inbox and, under it, the to-dos
        // folder while there are to-dos to show.
        var upNext: [SidebarNode] = [SidebarNode(.page(.inbox))]
        if !Todos.folder(notes).isEmpty || state.page == .todos { upNext.append(SidebarNode(.page(.todos))) }
        var top: [SidebarNode] = [SidebarNode(.group("Up Next"), children: upNext)]
        top.append(SidebarNode(.group("Buckets"), children: sorted.map { SidebarNode(.page(.project($0.id))) }))
        // The chat is a place to go, not something waiting: it leads the other places under "More".
        var more: [SidebarNode] = [SidebarNode(.page(.chat))]
        let archived = HomeList.archivedProjects(library.projects).count + HomeList.archivedNotes(notes).count
        if archived > 0 || state.page == .archive { more.append(SidebarNode(.page(.archive))) }
        if notes.contains(where: \.isDeleted) || state.page == .trash { more.append(SidebarNode(.page(.trash))) }
        if !more.isEmpty { top.append(SidebarNode(.group("More"), children: more)) }
        // An open bucket that is archived shows under the archive, but the sidebar still marks it.
        roots = top
        guard renaming == nil else { return }
        isSyncingSelection = true
        outline.reloadData()
        for node in roots where !node.children.isEmpty || node.kind == .group("Buckets") { outline.expandItem(node) }
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
    /// The rows as drawn, for the debug driver: "name" or "[group]", with a "+" when a group is expanded.
    var debugRows: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? SidebarNode else { return nil }
            switch node.kind {
            case .group(let name): return "[\(name)\(outline.isItemExpanded(node) ? "+" : "-")]"
            case .page(let page):
                if case .project(let id) = page { return library.project(id)?.name ?? "?" }
                return "\(page)"
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
        if case .group = (item as? SidebarNode)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .group = (item as? SidebarNode)?.kind { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.page != nil
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
        case .inbox:
            let count = notes.lazy.filter(\.isInInbox).count
            cell.configure(title: "Inbox", symbol: "tray.fill", tint: .brandSky, badge: count)
        case .todos:
            let folder = Todos.folder(notes)
            cell.configure(title: "To-dos", symbol: "checklist", tint: .brandTask, badge: folder.open, alert: folder.overdue)
        case .chat:
            cell.configure(title: "Chat", symbol: "bubble.left.and.bubble.right.fill", tint: .brandNavy, badge: 0)
        case .project(let id):
            let project = library.project(id)
            // What is in the bucket and not archived or deleted, as the bucket's page lists it.
            let key = project.map(Projects.key)
            let count = key.map { key in notes.lazy.filter { !$0.isDeleted && !$0.isArchived && $0.projectIDs.contains(key) }.count } ?? 0
            cell.configure(title: project?.name ?? "Bucket", symbol: "folder.fill", tint: .brandProject, badge: count, pinned: project?.isPinned == true)
        case .archive:
            cell.configure(title: "Archive", symbol: "archivebox.fill", tint: .brandNavy, badge: 0)
        case .trash:
            cell.configure(title: "Recently Deleted", symbol: "trash.fill", tint: .systemRed, badge: 0)
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
        guard let page = (item as? SidebarNode)?.page, index == NSOutlineViewDropOnItemIndex else { return [] }
        let pasteboard = info.draggingPasteboard
        if pasteboard.availableType(from: [.porridgeNote]) != nil {
            switch page {
            case .project, .archive, .trash, .inbox: return .move
            default: return []
            }
        }
        // Files and links from outside: into the inbox or a bucket.
        switch page {
        case .inbox, .project: return .copy
        default: return []
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let page = (item as? SidebarNode)?.page else { return false }
        let pasteboard = info.draggingPasteboard
        let context = library.context
        if let ids = NotePasteboard.noteIDs(from: pasteboard), !ids.isEmpty {
            let notes = ids.compactMap { library.note($0) }
            for note in notes {
                switch page {
                case .project(let id):
                    Inbox.file(note, into: id.uuidString, in: context)
                case .inbox:
                    note.projectIDs = []
                    note.updatedAt = Date()
                case .archive:
                    Archive.set(true, note, in: context)
                case .trash:
                    NoteStore.trash(note, in: context)
                default:
                    break
                }
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
            menu.addItem(withTitle: "New Bucket…", action: #selector(MainWindowController.newBucket(_:)), keyEquivalent: "")
            return
        }
        switch page {
        case .project(let id):
            guard let project = library.project(id) else { return }
            let pin = menu.addItem(withTitle: project.isPinned ? "Unpin" : "Pin", action: #selector(togglePin(_:)), keyEquivalent: "")
            pin.representedObject = project
            pin.target = self
            let rename = menu.addItem(withTitle: "Rename", action: #selector(rename(_:)), keyEquivalent: "")
            rename.representedObject = project
            rename.target = self
            let archive = menu.addItem(withTitle: project.isArchived ? "Unarchive" : "Archive", action: #selector(toggleArchive(_:)), keyEquivalent: "")
            archive.representedObject = project
            archive.target = self
            let chat = menu.addItem(withTitle: "Chat with Bucket", action: #selector(chatWithBucket(_:)), keyEquivalent: "")
            chat.representedObject = project
            chat.target = self
            menu.addItem(.separator())
            let delete = menu.addItem(withTitle: "Delete Bucket…", action: #selector(deleteBucket(_:)), keyEquivalent: "")
            delete.representedObject = project
            delete.target = self
        case .trash:
            menu.addItem(withTitle: "Delete All…", action: #selector(MainWindowController.emptyTrash(_:)), keyEquivalent: "")
        default:
            menu.addItem(withTitle: "New Bucket…", action: #selector(MainWindowController.newBucket(_:)), keyEquivalent: "")
        }
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? NoteFolder else { return }
        project.isPinned.toggle()
        project.updatedAt = Date()
        library.save()
    }

    @objc private func toggleArchive(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? NoteFolder else { return }
        Archive.set(!project.isArchived, project, in: library.context)
    }

    @objc private func chatWithBucket(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? NoteFolder else { return }
        state.page = .project(project.id)
        state.openChat(threads: library.threads)
    }

    @objc private func deleteBucket(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? NoteFolder, let window = view.window else { return }
        BucketActions.confirmDelete(project, state: state, in: window)
    }

    @objc private func rename(_ sender: NSMenuItem) {
        guard let project = sender.representedObject as? NoteFolder else { return }
        beginRenaming(project)
    }

    @objc private func doubleClicked() {
        guard let page = (outline.item(atRow: outline.clickedRow) as? SidebarNode)?.page, case .project(let id) = page,
              let project = library.project(id) else { return }
        beginRenaming(project)
    }

    /// The bucket's name becomes editable in place, as in the Finder's sidebar.
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
        guard let field = obj.object as? NSTextField, let project = renaming else { return }
        field.isEditable = false
        renaming = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != project.name {
            Projects.rename(project, to: name, in: library.context)
        } else {
            field.stringValue = project.name
        }
        library.setNeedsReload()
    }

    /// Escape while renaming keeps the old name.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // A stack leaves hidden parts out, so a hidden pin or count takes no room from the name.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        alertBadge.textColor = .brandDangerText
        alertBadge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        alertBadge.isHidden = true
        let row = NSStackView(views: [icon, title, pin, spacer, alertBadge, badge])
        row.orientation = .horizontal
        row.spacing = 4
        row.setCustomSpacing(6, after: icon)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `alert`: a second count in red (the to-dos that are late).
    func configure(title: String, symbol: String, tint: NSColor, badge count: Int, pinned: Bool = false, alert: Int = 0) {
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
            title, pinned ? String(localized: "Pinned") : nil, count > 0 ? "\(count)" : nil, alert > 0 ? String(localized: "\(alert) overdue") : nil,
        ].compactMap { $0 }.joined(separator: ", "))
    }
}
