import AppKit
import SwiftData
import UniformTypeIdentifiers

/// A main window: sidebar, list and detail, with the toolbar. Several can be open, also as tabs; each has its
/// own page, selection and search, and comes back where it was after a restart.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSMenuItemValidation, NSToolbarItemValidation {
    let state: WindowState
    let split: MainSplitViewController
    private let library = Library.shared
    private var observers: [Observing] = []
    private var libraryToken: UUID?
    private weak var searchField: NSSearchField?
    private var shareItem: NSSharingServicePickerToolbarItem?

    static var all: [MainWindowController] = []

    /// The window in front, or a new one.
    static var front: MainWindowController {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController { return main }
        if let any = all.first(where: { $0.window?.isVisible == true }) { return any }
        return open()
    }

    @discardableResult
    static func open(state: WindowState? = nil, asTabOf host: NSWindow? = nil) -> MainWindowController {
        let state = state ?? WindowState()
        let controller = MainWindowController(state: state)
        all.append(controller)
        if let host, let window = controller.window {
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        } else {
            controller.showWindow(nil)
        }
        return controller
    }

    init(state: WindowState) {
        self.state = state
        split = MainSplitViewController(state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentViewController = split
        window.minSize = NSSize(width: 900, height: 560)
        window.title = "Porridge"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "PorridgeMain"
        window.identifier = .init("main")
        window.isRestorable = true
        window.restorationClass = MainWindowRestoration.self
        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName(MainWindowController.all.isEmpty ? "PorridgeMain" : "")
        if window.frame.width < 900 { window.setContentSize(NSSize(width: 1180, height: 760)); window.center() }

        let toolbar = NSToolbar(identifier: "PorridgeMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar

        observers.append(Observing { [weak self] in
            guard let self else { return }
            _ = (self.state.page, self.state.selection, self.state.searchText)
            self.stateChanged()
        })
        libraryToken = library.observe { [weak self] in self?.libraryChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: State

    private func stateChanged() {
        window?.title = windowTitle
        if let field = searchField, state.page != .search, !field.stringValue.isEmpty, field.currentEditor() == nil {
            field.stringValue = ""
        }
        updateShareItem()
        window?.invalidateRestorableState()
        window?.toolbar?.validateVisibleItems()
    }

    private func libraryChanged() {
        // A draft that got saved is an ordinary note now.
        if let draft = state.draft, draft.modelContext != nil, library.notes.contains(where: { $0.id == draft.id }) {
            state.draft = nil
            state.draftStartsRecording = false
        }
        // The open bowl was deleted on another device.
        if case .project(let id) = state.page, library.project(id) == nil { state.page = .inbox }
        if case .smartFilter(let id) = state.page, SmartFilterStore.shared.filter(id) == nil { state.page = .inbox }
        // A note deleted for good (here or on another device) is no longer open.
        let kept = state.selection.filter { id in state.draft?.id == id || library.note(id) != nil }
        if kept != state.selection { state.selection = kept }
        window?.title = windowTitle
        window?.toolbar?.validateVisibleItems()
    }

    private var windowTitle: String {
        switch state.page {
        case .inbox: "Inbox"
        case .todos: "To-dos"
        case .chat: "Chat"
        case .project(let id): library.project(id)?.name ?? "Porridge"
        case .smartFilter(let id): SmartFilterStore.shared.filter(id)?.name ?? "Porridge"
        case .archive: "Archive"
        case .trash: "Recently Deleted"
        case .search: "Search"
        }
    }

    /// The note open in this window.
    var openNote: Note? {
        guard let id = state.openNoteID else { return nil }
        if let draft = state.draft, draft.id == id { return draft }
        return library.note(id)
    }

    /// The notes commands act on: the selection of the list.
    var selectedNotes: [Note] {
        state.selection.compactMap { id in
            if let draft = state.draft, draft.id == id { return draft }
            return library.note(id)
        }
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        split.detail.noteDetail?.flushEditing()
        MainWindowController.all.removeAll { $0 === self }
        observers.cancelAll()
        library.stopObserving(libraryToken)
    }

    func windowDidResignKey(_ notification: Notification) {
        split.detail.noteDetail?.flushEditing()
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        if let data = try? JSONEncoder().encode(RestoredState(self.state)) {
            state.encode(data, forKey: "porridgeState")
        }
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        if let data = state.decodeObject(of: NSData.self, forKey: "porridgeState") as Data?,
           let restored = try? JSONDecoder().decode(RestoredState.self, from: data) {
            restored.apply(to: self.state, library: library)
        }
    }

    /// "+" in the tab bar and Window › New Tab.
    @objc override func newWindowForTab(_ sender: Any?) {
        let next = WindowState()
        next.page = state.page == .search || state.page == .chat ? .inbox : state.page
        MainWindowController.open(state: next, asTabOf: window)
    }

    @objc func newWindow(_ sender: Any?) {
        let next = WindowState()
        next.page = state.page == .search || state.page == .chat ? .inbox : state.page
        let controller = MainWindowController.open(state: next)
        if let frame = window?.frame { controller.window?.setFrame(frame.offsetBy(dx: 24, dy: -24), display: true) }
    }

    // MARK: Toolbar

    private enum Item {
        static let new = NSToolbarItem.Identifier("new")
        static let importMenu = NSToolbarItem.Identifier("import")
        static let listSeparator = NSToolbarItem.Identifier("listSeparator")
        static let share = NSToolbarItem.Identifier("share")
        static let noteMenu = NSToolbarItem.Identifier("noteMenu")
        static let chat = NSToolbarItem.Identifier("chat")
        static let search = NSToolbarItem.Identifier("search")
        static let settings = NSToolbarItem.Identifier("settings")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Item.new, Item.importMenu, Item.listSeparator,
         .flexibleSpace, Item.share, Item.noteMenu, Item.chat, Item.search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Item.settings, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Item.new:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")
            item.label = "New"
            item.toolTip = "New"
            item.showsIndicator = true
            item.menu = newMenu()
            return item
        case Item.importMenu:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Import")
            item.label = "Import"
            item.toolTip = "Import"
            item.showsIndicator = true
            let menu = NSMenu()
            menu.addItem(withTitle: "Import Audio…", action: #selector(importAudio(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Import Plaud…", action: #selector(importPlaud(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Photo or File…", action: #selector(importFile(_:)), keyEquivalent: "")
            item.menu = menu
            return item
        case Item.listSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split.splitView, dividerIndex: 1)
        case Item.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.label = "Share"
            item.toolTip = "Share"
            item.delegate = self
            shareItem = item
            updateShareItem()
            return item
        case Item.noteMenu:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
            item.label = "More"
            item.toolTip = "More"
            item.showsIndicator = false
            item.menu = AppMenu.noteMenu(title: "More")
            return item
        case Item.chat:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Chat")
            item.label = "Chat"
            item.toolTip = "Chat with Your Bowls"
            item.isBordered = true
            item.action = #selector(openChat(_:))
            item.target = self
            return item
        case Item.settings:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.label = "Settings"
            item.isBordered = true
            item.action = #selector(AppDelegate.showSettings(_:))
            return item
        case Item.search:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "Search"
            item.searchField.placeholderString = "Search"
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.preferredWidthForSearchField = 220
            searchField = item.searchField
            return item
        default:
            return nil
        }
    }

    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, String, Selector, NSColor)] = [
            ("New Note", "square.and.pencil", #selector(newNote(_:)), .brandSky),
            ("New To-do", "checklist", #selector(newTodo(_:)), .brandTask),
            ("Record Meeting", "mic.fill", #selector(recordMeeting(_:)), .brandNavy),
            ("Add Link…", "link", #selector(addLink(_:)), .brandLink),
            ("New Bowl…", "folder.badge.plus", #selector(newBucket(_:)), .brandProject),
        ]
        for (title, symbol, action, tint) in entries {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.image = NSImage.symbol(symbol, size: 13, weight: .medium).tinted(tint.readable)
        }
        return menu
    }

    private func updateShareItem() {
        shareItem?.isEnabled = openNote != nil
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.new, Item.importMenu: state.page.allowsCreating
        case Item.share, Item.noteMenu: openNote != nil
        default: true
        }
    }

    // MARK: Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        let text = sender.stringValue
        if !text.isEmpty, state.page != .search {
            state.page = .search
        }
        state.searchText = text
    }

    func searchFieldDidStartSearching(_ sender: NSSearchField) {
        if state.page != .search { state.page = .search }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Return in the field moves to the results.
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue, state.page == .search {
            split.content.notes.focusList()
        }
    }

    /// ⌘F: the search field.
    @objc func focusSearch(_ sender: Any?) {
        if state.page != .search { state.page = .search }
        if let field = searchField {
            window?.makeFirstResponder(field)
        }
    }

    // MARK: Pages

    @objc func showInbox(_ sender: Any?) { state.page = .inbox }
    @objc func showTodos(_ sender: Any?) { state.page = .todos }
    @objc func showChat(_ sender: Any?) { state.page = .chat }
    @objc func showArchive(_ sender: Any?) { state.page = .archive }
    @objc func showTrash(_ sender: Any?) { state.page = .trash }

    @objc func openChat(_ sender: Any?) {
        if state.page == .chat { return }
        state.openChat(threads: library.threads)
    }

    @objc func newChat(_ sender: Any?) {
        state.page = .chat
        state.chatID = nil
        state.chatScope = nil
    }

    // MARK: Creating

    @objc func newNote(_ sender: Any?) { addNote(todo: false) }
    @objc func newTodo(_ sender: Any?) { addNote(todo: true) }

    /// A new note opens at once; it is stored once it has content. In a bowl it goes into it; in the to-dos
    /// folder it is a to-do, in no bowl.
    private func addNote(todo asked: Bool) {
        let todo = asked || state.page == .todos
        if !state.page.allowsCreating || state.page == .chat || state.page == .search { state.page = .inbox }
        let note = Note()
        note.source = .note
        if todo { TodoBridge.makeTodo(note) }
        if let project = state.projectForNew { note.projectIDs = [project] }
        state.draft = note
        state.draftStartsRecording = !todo && AppSettings.recordsNewNotes
        state.selection = [note.id]
        split.detail.noteDetail?.focusTitle()
    }

    @objc func addLink(_ sender: Any?) {
        Alerts.ask("Add Link", message: "The page is saved as a note and summarized.", placeholder: "https://", action: "Add",
                   validate: { LinkImport.webAddress(from: $0) != nil }, in: window) { [weak self] text in
            guard let self, let address = LinkImport.webAddress(from: text) else { return }
            if self.state.page == .search || self.state.page == .chat { self.state.page = .inbox }
            Intake.addLink(address, project: self.state.projectForNew, state: self.state)
        }
    }

    @objc func newBucket(_ sender: Any?) {
        BucketActions.create(in: window) { [weak self] project in self?.state.page = .project(project.id) }
    }

    @objc func recordMeeting(_ sender: Any?) {
        Capture.recordMeeting(in: self)
    }

    @objc func importAudio(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recording to transcribe."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try Intake.importAudio(url, project: self.state.projectForNew, state: self.state)
            } catch {
                Alerts.inform("Import Failed", message: error.localizedDescription, in: self.window)
            }
        }
    }

    // MARK: Continuity Camera

    /// "Import from iPhone or iPad" (File menu, context menus): a photo, a sketch or scanned pages from the phone come
    /// in like a dropped file, into the open bowl or the inbox.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, DeviceImport.types.contains(returnType), state.page.allowsCreating { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc func readSelection(from pasteboard: NSPasteboard) -> Bool {
        guard let url = DeviceImport.file(from: pasteboard) else { return false }
        return Intake.addFiles([url], project: state.projectForNew, state: state)
    }

    @objc func importFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf, .data]
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            Intake.addFiles(panel.urls, project: self.state.projectForNew, state: self.state)
        }
    }

    @objc func importPlaud(_ sender: Any?) {
        Capture.importPlaud(in: self)
    }

    @objc func emptyTrash(_ sender: Any?) {
        guard let window else { return }
        NoteOperations.confirmEmptyTrash(in: window, state: state)
    }

    /// ⌘V outside a text field: what is on the clipboard comes in as a note.
    @objc func pasteAsNote(_ sender: Any?) {
        Intake.accept(.general, project: state.projectForNew, state: state)
    }

    // MARK: Note commands (menu bar and toolbar)

    @objc func togglePin(_ sender: Any?) {
        let notes = selectedNotes.filter { $0.modelContext != nil }
        guard !notes.isEmpty else { return }
        NoteOperations.setPinned(!notes.allSatisfy(\.isPinned), notes)
    }

    @objc func deleteNote(_ sender: Any?) {
        let notes = selectedNotes
        guard !notes.isEmpty else { return }
        if notes.allSatisfy(\.isDeleted) {
            NoteOperations.deleteNow(notes, state: state, in: window)
        } else {
            NoteOperations.trash(notes, state: state)
        }
    }

    @objc func recoverNote(_ sender: Any?) {
        NoteOperations.recover(selectedNotes.filter(\.isDeleted), state: state)
    }

    @objc func copyNote(_ sender: Any?) {
        NoteOperations.copy(selectedNotes)
    }

    @objc func openNoteInNewWindow(_ sender: Any?) {
        guard let note = openNote, note.modelContext != nil else { return }
        NoteWindowController.open(note.id)
    }

    @objc func copyTranscript(_ sender: Any?) {
        guard let note = openNote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.transcriptText(), forType: .string)
    }

    /// Note › Due Date: today, tomorrow, next week, a picked day, or none, for the selected to-dos.
    @objc func setDueDate(_ sender: Any?) {
        let todos = selectedNotes.filter { $0.isTodo && $0.modelContext != nil && !$0.isDeleted }
        guard !todos.isEmpty, let item = sender as? NSMenuItem else { return }
        switch item.tag {
        case 0: TodoBridge.setDue(Todos.dueKey(for: .today), todos)
        case 1: TodoBridge.setDue(Todos.dueKey(for: .tomorrow), todos)
        case 2: TodoBridge.setDue(Todos.dueKey(for: .nextWeek), todos)
        case 3: DueDatePicker.present(for: todos, anchor: nil, window: window)
        default: TodoBridge.setDue(nil, todos)
        }
    }

    @objc func transcribeAgain(_ sender: Any?) {
        guard let note = openNote else { return }
        library.processing.enqueue(.transcript(note.id))
    }

    /// The commands that need the note's page (summaries, enhancing, recording, merging, exporting) go there.
    @objc func noteCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = NoteCommand(rawValue: item.tag) else { return }
        split.detail.noteDetail?.perform(command)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let notes = selectedNotes
        let note = openNote
        switch item.action {
        case #selector(newNote(_:)), #selector(newTodo(_:)):
            return true
        case #selector(recordMeeting(_:)), #selector(addLink(_:)), #selector(importAudio(_:)), #selector(importFile(_:)):
            return state.page.allowsCreating
        case #selector(importPlaud(_:)):
            return state.page.allowsCreating && library.plaudSignedIn
        case #selector(emptyTrash(_:)):
            return library.notes.contains(where: \.isDeleted)
        case #selector(togglePin(_:)):
            let saved = notes.filter { $0.modelContext != nil && !$0.isDeleted }
            item.title = !saved.isEmpty && saved.allSatisfy(\.isPinned) ? "Unpin" : "Pin"
            return !saved.isEmpty
        case #selector(deleteNote(_:)):
            item.title = !notes.isEmpty && notes.allSatisfy(\.isDeleted) ? "Delete Now…" : "Delete"
            return !notes.isEmpty
        case #selector(recoverNote(_:)):
            return notes.contains(where: \.isDeleted)
        case #selector(copyNote(_:)):
            return !notes.isEmpty
        case #selector(openNoteInNewWindow(_:)):
            return note?.modelContext != nil
        case #selector(copyTranscript(_:)):
            return note?.segments.isEmpty == false
        case #selector(transcribeAgain(_:)):
            guard let note else { return false }
            return note.hasAudio && library.processing.stages[note.id] == nil && !note.isDeleted
        case #selector(noteCommand(_:)):
            guard let command = NoteCommand(rawValue: item.tag), let detail = split.detail.noteDetail else { return false }
            return detail.validate(command, item: item)
        case #selector(setDueDate(_:)):
            let todos = notes.filter { $0.isTodo && $0.modelContext != nil && !$0.isDeleted }
            if item.tag == 4 { return todos.contains { $0.todoDue != nil } }
            return !todos.isEmpty
        case #selector(showArchive(_:)):
            return true
        case #selector(pasteAsNote(_:)):
            return state.page.allowsCreating
        default:
            return true
        }
    }
}

extension MainWindowController: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        guard let note = openNote else { return [] }
        return [note.exportText]
    }
}

/// What a window keeps across a restart.
private struct RestoredState: Codable {
    var page: SidebarPage
    var selection: [UUID]
    var chatID: UUID?

    @MainActor
    init(_ state: WindowState) {
        page = state.page == .search ? .inbox : state.page
        selection = state.selection.filter { $0 != state.draft?.id }
        chatID = state.chatID
    }

    @MainActor
    func apply(to state: WindowState, library: Library) {
        if case .project(let id) = page, library.project(id) == nil {
            state.page = .inbox
        } else if case .smartFilter(let id) = page, SmartFilterStore.shared.filter(id) == nil {
            state.page = .inbox
        } else {
            state.page = page
        }
        state.selection = selection.filter { library.note($0) != nil }
        state.chatID = chatID
    }
}

/// Brings the main windows back after a restart.
final class MainWindowRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
        completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
    ) {
        MainActor.assumeIsolated {
            switch identifier.rawValue {
            case "main":
                let controller = MainWindowController(state: WindowState())
                MainWindowController.all.append(controller)
                completionHandler(controller.window, nil)
            default:
                completionHandler(nil, nil)
            }
        }
    }
}
