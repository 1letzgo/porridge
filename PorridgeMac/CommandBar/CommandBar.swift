import AppKit

/// One line of Search or Ask: the question for the chat, a command, a bowl or smart filter to go to, an entry, a
/// recent chat or search, or "Show All Results".
struct CommandItem {
    enum Kind: Int {
        case ask, command, bowl, smartFilter, entry, chat, recentSearch, showAll

        /// The word (or the keys) on the right of the row.
        var label: String {
            switch self {
            case .ask: "⌘↩"
            case .command: String(localized: "Command")
            case .bowl: String(localized: "Bowl")
            case .smartFilter: String(localized: "Smart Filter")
            case .entry: String(localized: "Entry")
            case .chat: String(localized: "Chat")
            case .recentSearch: String(localized: "Search")
            case .showAll: "⇧↩"
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
    /// A command that only goes somewhere (Go to Today, Settings, Weekly Review): Return may run it like a bowl.
    var onlyGoes = false
    var run: @MainActor () -> Void
}

/// A part of the results under its heading.
struct CommandSection {
    var title: String?
    var items: [CommandItem]
}

/// What Search or Ask offers for a window, in the order of `SearchAsk`: "Ask Porridge: …" first (⌘↩; it hands the
/// question over to the Chat place), the commands that fit (every place (To-dos one of them), Triage, Weekly Review, Import,
/// Export, the open bowl's actions, moving the selection), the bowls and smart filters (`SearchAsk.goTo`), the entries
/// by date (`SearchAsk.entries`), and "Show All Results" (⇧↩, the search page). The empty field shows the recent chats,
/// the recent searches, the usual commands and the latest entries.
@MainActor
enum CommandBarItems {
    static let commandLimit = 6
    static let goToLimit = 5
    static let entryLimit = 8

    static func sections(for query: String, controller: MainWindowController) -> [CommandSection] {
        let library = Library.shared
        let commands = commands(for: controller)
        guard let question = SearchAsk.question(query) else {
            var sections: [CommandSection] = []
            let chats = SearchAsk.recentChats(library.threads).map { chatItem($0, controller: controller) }
            if !chats.isEmpty { sections.append(CommandSection(title: String(localized: "Recent Chats"), items: chats)) }
            let searches = SearchAsk.RecentSearches.all().prefix(4).map { line in
                CommandItem(kind: .recentSearch, title: line, symbol: "clock.arrow.circlepath", tint: .secondaryLabelColor) { [weak controller] in
                    controller?.fillSearch(line)
                }
            }
            if !searches.isEmpty { sections.append(CommandSection(title: String(localized: "Recent Searches"), items: Array(searches))) }
            sections.append(CommandSection(title: String(localized: "Commands"), items: commands.filter(\.isSuggested)))
            let latest = library.notes.filter { !$0.isDeleted }.prefix(5).map { entryItem($0, query: nil, controller: controller) }
            if !latest.isEmpty { sections.append(CommandSection(title: String(localized: "Latest Entries"), items: Array(latest))) }
            return sections
        }
        var sections = [CommandSection(title: nil, items: [askItem(question, controller: controller)])]
        // Only what fits by name or at the start of its words: letters scattered through a command are no match.
        var scored: [(order: Int, item: CommandItem, score: Int)] = []
        for (index, item) in commands.enumerated() {
            if let score = SearchAsk.score(question, title: item.title, keywords: item.keywords) { scored.append((index, item, score)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        let matching = scored.prefix(commandLimit).map(\.item)
        if !matching.isEmpty { sections.append(CommandSection(title: String(localized: "Commands"), items: Array(matching))) }
        let targets = SearchAsk.goTo(
            question, in: SearchAsk.targets(bowls: library.projects, filters: SmartFilterStore.shared.filters, notes: library.notes, places: false),
            limit: goToLimit
        )
        if !targets.isEmpty {
            sections.append(CommandSection(title: String(localized: "Bowls & Smart Filters"), items: targets.map { goToItem($0, query: question, controller: controller) }))
        }
        let entries = SearchAsk.entries(library.notes, query: question, indexMatches: NoteIndex.shared.noteIDs(matching: question))
        if !entries.isEmpty {
            sections.append(CommandSection(title: String(localized: "Entries"), items: entries.prefix(entryLimit).map { entryItem($0, query: question, controller: controller) }))
        }
        sections.append(CommandSection(title: nil, items: [showAllItem(question, controller: controller)]))
        return sections
    }

    /// The flat rows: the commands, bowls and entries, without headings (the debug driver).
    static func items(for query: String, controller: MainWindowController) -> [CommandItem] {
        sections(for: query, controller: controller).flatMap(\.items)
    }

    private static func askItem(_ question: String, controller: MainWindowController) -> CommandItem {
        CommandItem(
            kind: .ask, title: SearchAsk.askTitle(question), subtitle: SearchAsk.askSubtitle(.everywhere, bowls: Library.shared.projects),
            symbol: "sparkles", tint: .brandNavy
        ) { [weak controller] in
            controller?.askPorridge(question)
        }
    }

    private static func showAllItem(_ query: String, controller: MainWindowController) -> CommandItem {
        CommandItem(kind: .showAll, title: String(localized: "Show All Results for “\(query)”"), symbol: "magnifyingglass", tint: .brandNavy) { [weak controller] in
            controller?.showAllResults(query)
        }
    }

    private static func goToItem(_ target: SearchAsk.Target, query: String, controller: MainWindowController) -> CommandItem {
        let kind: CommandItem.Kind = target.kind == .smartFilter ? .smartFilter : .bowl
        return CommandItem(
            kind: kind, title: target.title, subtitle: target.subtitle, symbol: target.symbol,
            tint: kind == .bowl ? .brandProject : .brandNavy
        ) { [weak controller] in
            guard let controller else { return }
            SearchAsk.RecentSearches.add(query)
            switch target.destination {
            case .bowl(let id): controller.state.page = .project(id)
            case .smartFilter(let id): controller.state.page = .smartFilter(id)
            default: break
            }
        }
    }

    private static func chatItem(_ thread: ChatThread, controller: MainWindowController) -> CommandItem {
        let id = thread.id
        let subtitle = SearchAsk.chatName(thread.projectID, bowls: Library.shared.projects) + " · "
            + thread.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return CommandItem(
            kind: .chat, title: thread.title.isEmpty ? String(localized: "New Chat") : thread.title, subtitle: subtitle,
            symbol: "bubble.left.and.bubble.right.fill", tint: .brandNavy
        ) { [weak controller] in
            guard let controller else { return }
            controller.state.page = .chat
            controller.state.chatID = id
        }
    }

    private static func commands(for controller: MainWindowController) -> [CommandItem] {
        func go(_ title: String, _ symbol: String, _ tint: NSColor, _ keywords: String, suggested: Bool = false, _ page: SidebarPage) -> CommandItem {
            CommandItem(kind: .command, title: title, symbol: symbol, tint: tint, keywords: keywords, isSuggested: suggested, onlyGoes: true) { [weak controller] in
                controller?.state.page = page
            }
        }
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
                symbol: "mic", tint: .brandSky, keywords: "dictate speak voice"
            ) {
                DictationController.shared.toggleFromMenu()
            },
            CommandItem(kind: .command, title: String(localized: "Add Link…"), symbol: "link", tint: .brandLink, keywords: "url web page") { [weak controller] in
                controller?.addLink(nil)
            },
            CommandItem(kind: .command, title: String(localized: "New Bowl…"), symbol: "folder.badge.plus", tint: .brandProject, keywords: "create") { [weak controller] in
                controller?.newBucket(nil)
            },
            CommandItem(kind: .command, title: String(localized: "New Chat"), symbol: "bubble.left.and.bubble.right", tint: .brandNavy, keywords: "ask question chat") { [weak controller] in
                controller?.newChat(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Import Photo or File…"), symbol: "paperclip", tint: .brandNavy, keywords: "import add pdf scan image document") { [weak controller] in
                controller?.importFile(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Import Audio…"), symbol: "waveform", tint: .brandNavy, keywords: "import recording transcribe") { [weak controller] in
                controller?.importAudio(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Export Everything…"), symbol: "square.and.arrow.up", tint: .brandNavy, keywords: "backup markdown") { [weak controller] in
                controller?.exportEverything(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Weekly Review"), symbol: "calendar.badge.checkmark", tint: .brandNavy, keywords: "week summary", isSuggested: true, onlyGoes: true) { [weak controller] in
                controller?.showWeeklyReview(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Triage Inbox"), symbol: "keyboard", tint: .brandSky, keywords: "inbox file sort", onlyGoes: true) { [weak controller] in
                controller?.triageInbox(nil)
            },
            CommandItem(kind: .command, title: String(localized: "Settings"), symbol: "gearshape", tint: .systemGray, keywords: "open preferences options models", isSuggested: true, onlyGoes: true) {
                NSApp.activate()
                SettingsWindowController.shared.show(tab: nil)
            },
            go(String(localized: "Go to Today"), "calendar", .brandNavy, "show day appointments", .today),
            go(String(localized: "Go to Inbox"), "tray.fill", .brandSky, "show new", .inbox),
            go(String(localized: "Go to To-dos"), "checklist", .brandTask, "show open tasks todos", .todos),
            go(String(localized: "Go to Bowls"), Places.bowlsSymbol, .brandProject, "show all bowls", .bowls),
            go(String(localized: "Go to Chat"), "bubble.left.and.bubble.right.fill", .brandNavy, "show chats all chats ask", .chat),
            go(String(localized: "Go to Archive"), "archivebox.fill", .brandNavy, "show archived", .archive),
            go(String(localized: "Go to Recently Deleted"), "trash.fill", .systemRed, "show trash bin", .trash),
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
        // The open bowl's actions: the rows of its ⋯ menu.
        if let id = controller.state.page.projectID, let project = Library.shared.project(id) {
            let menu = NSMenu()
            BucketActions.addItems(for: project, to: menu, state: controller.state, window: controller.window, opens: false)
            items.append(CommandItem(kind: .command, title: String(localized: "New Note in \(project.name)"), symbol: "square.and.pencil", tint: .brandSky, keywords: "create add bowl") { [weak controller] in
                controller?.newNote(nil)
            })
            for case let item as ActionMenuItem in menu.items where item.isEnabled {
                let title = item.title.hasSuffix("…") || item.title.contains("Bowl") ? item.title : String(localized: "\(item.title) Bowl")
                items.append(CommandItem(kind: .command, title: title, subtitle: project.name, symbol: "folder", tint: .brandProject, keywords: "bowl \(project.name)") {
                    item.perform()
                })
            }
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

    private static func entryItem(_ note: Note, query: String?, controller: MainWindowController) -> CommandItem {
        let bowl = note.projectIDs.first.flatMap { Library.shared.project(key: $0)?.name } ?? String(localized: "Inbox")
        let date = note.updatedAt.formatted(date: .abbreviated, time: .omitted)
        let id = note.id
        return CommandItem(kind: .entry, title: note.displayTitle, subtitle: "\(note.kindName) · \(bowl) · \(date)", symbol: note.kindSymbol, tint: .brandNavy) { [weak controller] in
            guard let controller, let note = Library.shared.note(id) else { return }
            if let query { SearchAsk.RecentSearches.add(query) }
            controller.state.reveal(note)
        }
    }
}

/// Search or Ask (⌘K): the results under the toolbar's field ("anchored": the field stays the window's, its keys are
/// handed over by `MainWindowController`), or a floating panel with its own field (the global shortcut, a window
/// whose toolbar is hidden). Arrows move through the list, ↩ runs the selected row (at first the best one after
/// "Ask"), ⌘↩ asks, ⇧↩ shows all results, Escape closes it, clicking elsewhere too.
@MainActor
final class CommandBarController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private(set) static var current: CommandBarController?

    private enum Row {
        case header(String)
        case item(CommandItem)
    }

    private let panel: CommandBarPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint?
    private weak var controller: MainWindowController?
    /// The toolbar's field the results hang from; nil for the floating panel.
    private weak var anchor: NSSearchField?
    private var rows: [Row] = []
    private var query = ""

    private static let width: CGFloat = 600
    private static let anchoredWidth: CGFloat = 480
    private static let rowHeight: CGFloat = 40
    private static let headerHeight: CGFloat = 26
    private static let maxHeight: CGFloat = 460

    var isAnchored: Bool { anchor != nil }

    /// The floating panel over the window, with its own field.
    static func show(for controller: MainWindowController) {
        current?.close()
        let bar = CommandBarController(controller: controller, anchor: nil)
        current = bar
        bar.present()
    }

    /// The results under the toolbar's field, for what it holds now.
    static func showAnchored(for controller: MainWindowController, field: NSSearchField) {
        if let current, current.anchor === field, current.controller === controller {
            current.update(query: field.stringValue)
            return
        }
        current?.close()
        let bar = CommandBarController(controller: controller, anchor: field)
        current = bar
        bar.present()
    }

    static func closeCurrent() {
        current?.close()
    }

    private init(controller: MainWindowController, anchor: NSSearchField?) {
        self.controller = controller
        self.anchor = anchor
        panel = CommandBarPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300), styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.takesKeyboard = anchor == nil
        super.init()
        query = anchor?.stringValue ?? ""
        build()
    }

    private func build() {
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = true
        panel.setAccessibilityLabel(String(localized: "Search or Ask"))

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.layer?.masksToBounds = true
        panel.contentView = background

        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        table.setAccessibilityLabel(String(localized: "Results"))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(scroll)
        let height = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * 6)
        heightConstraint = height

        if isAnchored {
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 6),
                scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
                scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
                scroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -6),
                height,
            ])
            return
        }

        field.placeholderString = String(localized: "Search or Ask")
        field.font = .systemFont(ofSize: 20)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel(String(localized: "Search or Ask"))

        let icon = NSImageView(image: .symbol("magnifyingglass", size: 18, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(icon)
        background.addSubview(field)
        background.addSubview(line)
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
        if !isAnchored { window.makeKeyAndOrderFront(nil) }
        reload()
        position()
        window.addChildWindow(panel, ordered: .above)
        if isAnchored {
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
        }
    }

    /// Floating: centred near the top of the window. Anchored: right under the field, its right edge with the
    /// field's, inside the window.
    private func position() {
        guard let window = controller?.window, let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        let frame = window.frame
        if let anchor, anchor.window != nil {
            let rect = anchor.window!.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let width = min(Self.anchoredWidth, frame.width - 24)
            let x = max(frame.minX + 12, min(rect.maxX - width, frame.maxX - 12 - width))
            panel.setFrame(NSRect(x: x, y: rect.minY - 6 - height, width: width, height: height), display: true)
        } else {
            let width = min(Self.width, frame.width - 40)
            panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 110 - height, width: width, height: height), display: true)
        }
    }

    func close() {
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    /// The anchored field's text changed.
    func update(query new: String) {
        query = new
        reload()
        position()
    }

    private func reload() {
        guard let controller else { return }
        let text = isAnchored ? query : field.stringValue
        rows = CommandBarItems.sections(for: text, controller: controller).flatMap { section -> [Row] in
            (section.title.map { [Row.header($0)] } ?? []) + section.items.map { .item($0) }
        }
        table.reloadData()
        selectBest()
        let content = rows.reduce(CGFloat(0)) { $0 + height(of: $1) }
        let height = min(max(content, Self.rowHeight), Self.maxHeight)
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
    }

    /// The best row (`SearchAsk.best`): the closest fit by name, a bowl or an entry before a command that does
    /// something, which is never chosen over an entry or bowl that fits as well; "Show All Results" when nothing
    /// fits well enough. Asking is ⌘↩, never Return. With an empty field: the first row.
    private func selectBest() {
        let selectable = rows.indices.filter { if case .item = rows[$0] { true } else { false } }
        guard let first = selectable.first else { return }
        let text = SearchAsk.question(isAnchored ? query : field.stringValue)
        var best = first
        if let text {
            let candidates: [(row: Int, fit: SearchAsk.Fit, pick: SearchAsk.Pick)] = selectable.compactMap { index in
                guard case .item(let item) = rows[index] else { return nil }
                let pick: SearchAsk.Pick
                switch item.kind {
                case .bowl, .smartFilter: pick = .bowl
                case .entry: pick = .entry
                case .command: pick = item.onlyGoes ? .place : .action
                case .ask, .showAll, .chat, .recentSearch: return nil
                }
                // A command is named by its title without "Go to" ("Inbox" fits "Go to Inbox" exactly).
                let name = item.kind == .command ? Self.name(of: item.title) : item.title
                return (index, SearchAsk.fit(text, name: name), pick)
            }
            if let chosen = SearchAsk.best(candidates.map { ($0.fit, $0.pick) }) {
                best = candidates[chosen].row
            } else if let all = selectable.first(where: { if case .item(let item) = rows[$0] { item.kind == .showAll } else { false } }) {
                best = all
            }
        } else {
            best = selectable.first { index in
                if case .item(let item) = rows[index] { return item.kind != .ask && item.kind != .showAll }
                return false
            } ?? first
        }
        table.selectRowIndexes([best], byExtendingSelection: false)
        table.scrollRowToVisible(0)
    }

    private static func name(of title: String) -> String {
        let prefix = String(localized: "Go to ")
        return title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }

    private func height(of row: Row) -> CGFloat {
        if case .header = row { return Self.headerHeight }
        return Self.rowHeight
    }

    private func item(at row: Int) -> CommandItem? {
        guard rows.indices.contains(row), case .item(let item) = rows[row] else { return nil }
        return item
    }

    private func run(_ item: CommandItem) {
        let window = controller?.window
        let anchor = anchor
        close()
        if let anchor {
            // Done with the field: its text goes (the search page keeps what it shows).
            if item.kind != .showAll, item.kind != .recentSearch { anchor.stringValue = "" }
            window?.makeFirstResponder(nil)
        }
        window?.makeKeyAndOrderFront(nil)
        item.run()
    }

    func runSelected() {
        guard let item = item(at: table.selectedRow) else { return }
        run(item)
    }

    /// ⌘↩: the question goes to the chat.
    func ask() {
        guard let item = rows.compactMap({ if case .item(let item) = $0, item.kind == .ask { item } else { nil } }).first else { return }
        run(item)
    }

    /// ⇧↩: the search page with every result.
    func showAll() {
        guard let item = rows.compactMap({ if case .item(let item) = $0, item.kind == .showAll { item } else { nil } }).first else { return }
        run(item)
    }

    /// The titles of the rows, headings in brackets (the debug driver).
    var dump: [String] {
        rows.enumerated().map { index, row in
            switch row {
            case .header(let title): "[\(title)]"
            case .item(let item): (index == table.selectedRow ? "> " : "  ") + item.title + (item.subtitle.map { " — \($0)" } ?? "") + " · " + item.kind.label
            }
        }
    }

    @objc private func clicked() {
        guard item(at: table.clickedRow) != nil else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        runSelected()
    }

    // MARK: Keys

    /// The keys of a field (its own or the toolbar's): true when handled.
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            move(by: 1)
        case #selector(NSResponder.moveUp(_:)):
            move(by: -1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.command) {
                ask()
            } else if flags.contains(.shift) {
                showAll()
            } else {
                runSelected()
            }
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        reload()
        position()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handle(selector)
    }

    private func move(by offset: Int) {
        guard !rows.isEmpty else { return }
        var row = table.selectedRow
        repeat {
            row += offset
        } while rows.indices.contains(row) && item(at: row) == nil
        guard rows.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isAnchored { close() }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        height(of: rows[row])
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        item(at: row) != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField.label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor)
            let view = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            ])
            return view
        case .item(let item):
            let cell = (tableView.makeView(withIdentifier: CommandBarCell.identifier, owner: nil) as? CommandBarCell) ?? CommandBarCell()
            cell.show(item)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .header = rows[row] { return PlainGroupRowView() }
        return ResultRowView()
    }
}

/// A result row whose selection is a soft accent wash under the normal text: readable in light and dark, whether the
/// panel is key or not (the table never takes the keyboard), and the same in the debug driver's pictures.
private final class ResultRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    /// The cells keep their own colours on the wash.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A heading row without the group row's floating bar.
private final class PlainGroupRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {}
}

/// A borderless panel; the floating one takes the keyboard, the anchored one leaves it with the toolbar's field.
private final class CommandBarPanel: NSPanel {
    var takesKeyboard = true
    override var canBecomeKey: Bool { takesKeyboard }
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
        title.font = .systemFont(ofSize: 14, weight: item.kind == .ask ? .semibold : .regular)
        subtitle.stringValue = item.subtitle ?? ""
        subtitle.isHidden = item.subtitle == nil
        kind.stringValue = item.kind.label
        setAccessibilityLabel([item.title, item.subtitle, item.kind.label].compactMap { $0 }.joined(separator: ", "))
    }
}
