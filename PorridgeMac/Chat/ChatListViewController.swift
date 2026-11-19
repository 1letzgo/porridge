import AppKit
import SwiftData

/// The chats in the middle column, the latest on top: a click opens one, the context menu deletes it.
/// Chats are kept; a new chat is kept from its first question on.
final class ChatListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let state: WindowState
    private let library = Library.shared
    private let table = NSTableView()
    private let header = ListHeaderView()
    private var threads: [ChatThread] = []
    private var token: UUID?
    private var observing: Observing?
    private var isSyncing = false

    init(state: WindowState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            library.stopObserving(token)
            observing?.cancel()
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.dataSource = self
        table.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.setAccessibilityLabel("Chats")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let newChat = PillButton(title: "New Chat", symbol: "square.and.pencil", tint: .brandSky, target: self, action: #selector(newChat(_:)))
        newChat.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(scroll)
        root.addSubview(newChat)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            newChat.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            newChat.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.topAnchor.constraint(equalTo: newChat.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        token = library.observe { [weak self] in self?.reload() }
        observing = Observing { [weak self] in
            guard let self else { return }
            _ = self.state.chatID
            self.syncSelection()
        }
        reload()
    }

    private func reload() {
        threads = library.threads
        isSyncing = true
        table.reloadData()
        isSyncing = false
        header.show(page: .chat, library: library, state: state, kindCounts: [:])
        syncSelection()
    }

    private func syncSelection() {
        isSyncing = true
        defer { isSyncing = false }
        if let index = threads.firstIndex(where: { $0.id == state.chatID }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { threads.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChatThreadCell.identifier, owner: nil) as? ChatThreadCell ?? ChatThreadCell()
        cell.show(threads[row], projects: library.projects)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSyncing, table.selectedRow >= 0, table.selectedRow < threads.count else { return }
        state.chatID = threads[table.selectedRow].id
    }

    @objc func newChat(_ sender: Any?) {
        state.chatID = nil
        state.chatScope = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < threads.count else { return }
        let thread = threads[row]
        menu.add("Delete Chat", symbol: "trash", isDestructive: true) { [weak self] in self?.delete(thread) }
    }

    private func delete(_ thread: ChatThread) {
        let id = thread.id
        let context = library.context
        let entries = (try? context.fetch(FetchDescriptor<ChatEntry>(predicate: #Predicate { $0.threadID == id }))) ?? []
        entries.forEach(context.delete)
        context.delete(thread)
        try? context.save()
        if state.chatID == id { state.chatID = nil }
    }
}

private final class ChatThreadCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("chat")
    private let icon = KindIconView()
    private let title = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium))
    private let detail = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbol = "bubble.left.and.bubble.right.fill"
        icon.tint = .brandNavy
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView.vertical([title, detail], spacing: 3)
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

    func show(_ thread: ChatThread, projects: [NoteFolder]) {
        title.stringValue = thread.title.isEmpty ? String(localized: "New Chat") : thread.title
        detail.stringValue = ChatScope.name(thread.projectID, projects: projects) + " · "
            + thread.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        setAccessibilityLabel("\(title.stringValue), \(detail.stringValue)")
    }
}

/// What a chat is about: all buckets or one.
enum ChatScope {
    static func name(_ project: String?, projects: [NoteFolder]) -> String {
        guard let project else { return String(localized: "All Buckets") }
        return projects.first { Projects.key($0) == project }?.name ?? String(localized: "Deleted Bucket")
    }
}
