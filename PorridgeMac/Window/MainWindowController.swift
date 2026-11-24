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
    private weak var searchItem: NSSearchToolbarItem?
    private var shareItem: NSToolbarItem?
    private let shareButton = NSButton()
    /// The red counter of a running recording (hidden otherwise).
    private var recordingItem: NSToolbarItem?
    private let recordingButton = NSButton()
    private var recordingTimer: Timer?

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
        // A configuration saved before the Record Meeting column had its own toolbar section lacks the separator;
        // one saved before the inspector lacks its button and the recording's counter.
        if !toolbar.items.contains(where: { $0.itemIdentifier == .inspectorTrackingSeparator }) {
            toolbar.insertItem(withItemIdentifier: .inspectorTrackingSeparator, at: toolbar.items.count)
        }
        if !toolbar.items.contains(where: { $0.itemIdentifier == .toggleInspector }) {
            toolbar.insertItem(withItemIdentifier: .toggleInspector, at: toolbar.items.count)
        }
        if !toolbar.items.contains(where: { $0.itemIdentifier == Item.recording }) {
            let index = toolbar.items.firstIndex { $0.itemIdentifier == Item.share } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: Item.recording, at: index)
        }
        // One saved before the ✦ AI menu lacks it: it goes before Share.
        if !toolbar.items.contains(where: { $0.itemIdentifier == Item.ai }) {
            let index = toolbar.items.firstIndex { $0.itemIdentifier == Item.share } ?? toolbar.items.count
            toolbar.insertItem(withItemIdentifier: Item.ai, at: index)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(recordingChanged), name: MeetingRecorder.didChange, object: nil)
        recordingChanged()

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
        updateShareItem()
        window?.toolbar?.validateVisibleItems()
    }

    private var windowTitle: String {
        switch state.page {
        case .today: "Today"
        case .inbox: "Inbox"
        case .bowls: "Bowls"
        case .todos: "Open To-dos"
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

    func windowDidResize(_ notification: Notification) {
        split.enforceSharedWidth()
    }

    func windowWillClose(_ notification: Notification) {
        recordingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: MeetingRecorder.didChange, object: nil)
        split.detail.noteDetail?.flushEditing()
        // A recording in this window's right column goes on in a window of its own.
        MeetingRecorder.mainWindowWillClose(self)
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
        static let listSeparator = NSToolbarItem.Identifier("listSeparator")
        static let share = NSToolbarItem.Identifier("share")
        static let noteMenu = NSToolbarItem.Identifier("noteMenu")
        static let ai = NSToolbarItem.Identifier("ai")
        static let search = NSToolbarItem.Identifier("search")
        static let settings = NSToolbarItem.Identifier("settings")
        static let recording = NSToolbarItem.Identifier("recording")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Import is a group of the "+" menu; the chat is reached from AI › New Chat, Ask About This Bowl and ⌘K.
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Item.new, Item.listSeparator,
         Item.recording, .flexibleSpace, Item.ai, Item.share, Item.noteMenu, Item.search,
         // The inspector (Details | Record) keeps the part of the toolbar above it to itself: while it is open the
         // items before this separator, the search included, stay over the columns to its left.
         .inspectorTrackingSeparator, .flexibleSpace, .toggleInspector]
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
        case Item.listSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split.splitView, dividerIndex: 1)
        case Item.ai:
            // ✦ AI: what a model does to the open entry (`EntryMenus.ai`), filled when it opens.
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AI")
            item.label = "AI"
            item.toolTip = "AI"
            item.showsIndicator = true
            item.menu = EntryToolbarMenu.make(.ai)
            return item
        case Item.share:
            // Share hands over what the entry is (`EntryMenus.share`): the text, the link, the picture or the file;
            // a meeting opens its export sheet.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Share"
            item.toolTip = "Share"
            shareButton.bezelStyle = .toolbar
            shareButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")
            shareButton.target = self
            shareButton.action = #selector(shareEntry(_:))
            shareButton.setAccessibilityLabel("Share")
            item.view = shareButton
            shareItem = item
            updateShareItem()
            return item
        case Item.noteMenu:
            // ⋯ More: only the short More of the entry's kind (`EntryMenus.more`); the whole list is the Entry menu.
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More")
            item.label = "More"
            item.toolTip = "More"
            item.showsIndicator = false
            item.menu = EntryToolbarMenu.make(.more)
            return item
        case Item.recording:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Recording")
            item.toolTip = String(localized: "Show the Recording")
            recordingButton.bezelStyle = .toolbar
            recordingButton.image = .symbol("record.circle.fill", size: 13, weight: .semibold)
            recordingButton.imagePosition = .imageLeading
            recordingButton.contentTintColor = .systemRed
            recordingButton.target = self
            recordingButton.action = #selector(showRecordInspector(_:))
            recordingButton.setAccessibilityLabel(String(localized: "Recording"))
            item.view = recordingButton
            item.isHidden = !MeetingRecorder.isRecording
            recordingItem = item
            updateRecordingCounter()
            return item
        case Item.settings:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.label = "Settings"
            item.isBordered = true
            item.action = #selector(AppDelegate.showSettings(_:))
            return item
        case Item.search:
            // Search or Ask (⌘K): its results hang below it (`CommandBarController`).
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "Search or Ask"
            item.searchField.placeholderString = "Search or Ask"
            item.searchField.setAccessibilityLabel("Search or Ask")
            item.searchField.toolTip = "Search or Ask (⌘K)"
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.preferredWidthForSearchField = 240
            searchField = item.searchField
            searchItem = item
            return item
        default:
            return nil
        }
    }

    /// "+": the four kinds, then Import (folded in from the toolbar's Import menu), templates and New Bowl…, in the
    /// words and groups of the iPhone's Add sheet.
    private func newMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ action: Selector, _ tint: NSColor, key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.image = NSImage.symbol(symbol, size: 13, weight: .medium).tinted(tint.readable)
        }
        add("New Note", "square.and.pencil", #selector(newNote(_:)), .brandSky, key: "n")
        add("New To-do", "checklist", #selector(newTodo(_:)), .brandTask, key: "n", modifiers: [.command, .shift])
        add("Record Meeting", "mic.fill", #selector(recordMeeting(_:)), .brandNavy, key: "r")
        add("Add Link…", "link", #selector(addLink(_:)), .brandLink, key: "l")
        menu.addItem(.separator())
        add("Photo or File…", "paperclip", #selector(importFile(_:)), .brandNavy, key: "i", modifiers: [.command, .shift])
        add("Audio…", "waveform", #selector(importAudio(_:)), .brandNavy)
        add("From Plaud…", "recordingtape", #selector(importPlaud(_:)), .brandNavy)
        // Continuity Camera: the system fills it with "Take Photo" and "Scan Documents" of the iPhone or iPad nearby.
        let device = NSMenuItem(title: "From iPhone or iPad", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        device.image = NSImage.symbol("iphone", size: 13, weight: .medium).tinted(NSColor.brandNavy.readable)
        menu.addItem(device)
        menu.addItem(.separator())
        // A note or to-do from one of the note templates.
        menu.addItem(NoteTemplateMenu.item(for: self))
        menu.addItem(.separator())
        add("New Bowl…", "folder.badge.plus", #selector(newBucket(_:)), .brandProject, key: "n", modifiers: [.command, .control])
        return menu
    }

    /// A recording started or ended: the counter shows while it runs.
    @objc private func recordingChanged() {
        let running = MeetingRecorder.isRecording
        recordingItem?.isHidden = !running
        recordingTimer?.invalidate()
        recordingTimer = nil
        if running {
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRecordingCounter() }
            }
        }
        updateRecordingCounter()
    }

    private func updateRecordingCounter() {
        let time = (MeetingRecorder.elapsed ?? 0).clockString
        recordingButton.attributedTitle = NSAttributedString(string: " " + time, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.systemRed,
        ])
        recordingButton.setAccessibilityValue(time)
    }

    // MARK: Inspector

    /// View › Details (⌥⌘I): the inspector's Details; again while they show, the inspector closes.
    @objc func showDetailsInspector(_ sender: Any?) {
        if split.isInspectorOpen, split.inspector.mode == .details {
            split.toggleInspector(sender)
        } else {
            split.show(.details)
        }
    }

    /// View › Record (⌥⌘R) and the toolbar's counter: the inspector's Record mode.
    @objc func showRecordInspector(_ sender: Any?) {
        split.show(.record)
    }

    private func updateShareItem() {
        let enabled = openNote.map { EntryMenus.share(for: $0) != nil } ?? false
        shareItem?.isEnabled = enabled
        shareButton.isEnabled = enabled
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.new: state.page.allowsCreating
        case Item.noteMenu: openNote != nil
        case Item.ai: openNote.map { !EntryMenus.ai(for: $0, context: entryContext(for: $0)).isEmpty } ?? false
        case Item.share: openNote.map { EntryMenus.share(for: $0) != nil } ?? false
        default: true
        }
    }

    /// What the menus of the toolbar read for an entry.
    func entryContext(for note: Note) -> EntryContext {
        EntryContext.live(for: note, bowls: library.projects, processing: library.processing)
    }

    /// The toolbar's Share: per kind (`EntryMenus.share`).
    @objc func shareEntry(_ sender: Any?) {
        guard let note = openNote, let share = EntryMenus.share(for: note) else { return }
        split.detail.noteDetail?.flushEditing()
        let items: [Any]
        switch share {
        case .exportSheet:
            split.detail.noteDetail?.perform(.export)
            return
        case .url:
            items = [note.linkURL.map { $0 as Any } ?? note.exportText]
        case .image, .file:
            items = [EntryMenus.shareFile(for: note).map { $0 as Any } ?? note.exportText]
        case .markdown, .todoText:
            items = [note.exportText]
        }
        let picker = NSSharingServicePicker(items: items)
        let anchor = (sender as? NSView) ?? shareButton
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    // MARK: Search or Ask

    /// The toolbar's field: on the search page it narrows the page as it is typed; elsewhere the results of Search or
    /// Ask hang below it.
    @objc private func searchChanged(_ sender: NSSearchField) {
        let text = sender.stringValue
        if state.page == .search {
            state.searchText = text
            return
        }
        // Only while typing: the field also sends its text when it stops being edited (a row was just run).
        guard sender.currentEditor() != nil else { return }
        CommandBarController.showAnchored(for: self, field: sender)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === searchField else { return false }
        if let bar = CommandBarController.current, bar.isAnchored {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                bar.close()
                searchField?.stringValue = ""
                window?.makeFirstResponder(nil)
                return true
            }
            return bar.handle(selector)
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        if let bar = CommandBarController.current, bar.isAnchored { bar.close() }
        // Return in the field of the search page moves to the results.
        if (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue, state.page == .search {
            split.content.notes.focusList()
        }
    }

    /// ⌘K (View › Search or Ask…): the toolbar's field with its results; without a toolbar field, the floating panel.
    @objc func focusSearch(_ sender: Any?) {
        guard let field = searchField, let item = searchItem, window?.toolbar?.isVisible == true,
              window?.toolbar?.items.contains(where: { $0 === item }) == true else {
            CommandBarController.show(for: self)
            return
        }
        item.beginSearchInteraction()
        window?.makeFirstResponder(field)
        if state.page != .search { CommandBarController.showAnchored(for: self, field: field) }
    }

    /// A `porridge://search?q=…` link: the search page with this text.
    func search(for text: String) {
        showAllResults(text)
    }

    /// "Ask Porridge: …" (⌘↩): the Chat place opens with a new chat about everything, and the question is asked there.
    func askPorridge(_ question: String) {
        state.chatScope = nil
        state.chatID = nil
        state.page = .chat
        state.pendingQuestion = question
    }

    /// "Show All Results" (⇧↩): the search page in the list column, with kind and tag pills and Save as Smart Filter.
    func showAllResults(_ query: String) {
        SearchAsk.RecentSearches.add(query)
        searchField?.stringValue = query
        if state.page != .search { state.page = .search }
        state.searchText = query
    }

    #if DEBUG
    /// `DebugDriver`: ⌘K and typing `text` into the toolbar's field.
    func debugSearchAsk(_ text: String) {
        focusSearch(nil)
        guard let field = searchField else { return }
        field.stringValue = text
        if let editor = field.currentEditor() as? NSTextView { editor.string = text }
        searchChanged(field)
    }
    #endif

    /// A recent search: back into the field, its results below.
    func fillSearch(_ line: String) {
        guard let field = searchField else { return showAllResults(line) }
        field.stringValue = line
        focusSearch(nil)
        if state.page == .search { state.searchText = line } else { CommandBarController.showAnchored(for: self, field: field) }
    }

    // MARK: Pages

    @objc func showToday(_ sender: Any?) { state.page = .today }
    @objc func showInbox(_ sender: Any?) { state.page = .inbox }
    @objc func showBowls(_ sender: Any?) { state.page = .bowls }
    @objc func showChat(_ sender: Any?) { state.page = .chat }
    @objc func showTodos(_ sender: Any?) { state.page = .todos }
    @objc func showArchive(_ sender: Any?) { state.page = .archive }
    @objc func showTrash(_ sender: Any?) { state.page = .trash }

    @objc func openChat(_ sender: Any?) {
        if state.page == .chat { return }
        state.openChat(threads: library.threads)
    }

    /// AI › Ask About This Bowl: the chat about the open entry's bowl, else the bowl that is open.
    @objc func askAboutBowl(_ sender: Any?) {
        guard let bowl = bowlToAsk else { return }
        state.openChat(about: bowl, threads: library.threads)
    }

    /// The bowl Ask About This Bowl and Export Bowl… act on: the open entry's, else the open page's.
    private var bowlToAsk: String? {
        if let note = openNote, note.modelContext != nil, !note.isDeleted { return note.projectIDs.first }
        return state.page.projectID?.uuidString
    }

    /// File › Export Bowl…: the bowl that is open, else the open entry's.
    @objc func exportBowl(_ sender: Any?) {
        let key = state.page.projectID?.uuidString ?? openNote?.projectIDs.first
        guard let key, let project = library.projects.first(where: { Projects.key($0) == key }) else { return }
        ExportSheetController.export(.bowl(project.id), title: String(localized: "Export “\(project.name)”"), in: window)
    }

    /// File › Export Everything…
    @objc func exportEverything(_ sender: Any?) {
        ExportSheetController.export(.everything, title: String(localized: "Export Everything"), in: window)
    }

    /// Entry › Pages › Merge PDFs…: the selected PDFs into one.
    @objc func mergePDFs(_ sender: Any?) {
        let mergeable = DocumentFiles.mergeable(selectedNotes.filter { $0.isStored && !$0.isDeleted })
        guard mergeable.count >= 2 else { return }
        NoteOperations.merge(mergeable, in: window)
    }

    /// The rows of the Entry and AI menus that open a submenu: never run, only validated (dimmed when nothing in
    /// the submenu applies).
    @objc func entrySubmenu(_ sender: Any?) {}

    @objc func newChat(_ sender: Any?) {
        state.page = .chat
        state.chatID = nil
        state.chatScope = nil
    }

    // MARK: Creating

    @objc func newNote(_ sender: Any?) { addNote(todo: false) }
    @objc func newTodo(_ sender: Any?) { addNote(todo: true) }

    /// A new note for an appointment: named after it, linked to it, in its bowl (else the one open).
    func addNote(for appointment: CalendarAppointment) {
        if state.page == .chat || state.page == .search { state.page = .today }
        let note = Note()
        note.source = .note
        note.title = appointment.title
        if let bowl = AppointmentLinks.shared.bowl(for: appointment) ?? state.projectForNew { note.projectIDs = [bowl] }
        AppointmentLinks.shared.link(note, to: appointment, in: nil)
        state.draft = note
        state.draftStartsRecording = false
        state.selection = [note.id]
        split.detail.noteDetail?.focusTitle()
    }

    /// A new note opens at once; it is stored once it has content. In a bowl it goes into it; in Open To-dos it is
    /// a to-do, in no bowl. From the Bowls place, the chat or the search it goes into the Inbox, which opens.
    private func addNote(todo asked: Bool) {
        let todo = asked || state.page == .todos
        if !state.page.allowsCreating || state.page == .chat || state.page == .search || state.page == .bowls { state.page = .inbox }
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
            if self.state.page == .search || self.state.page == .chat || self.state.page == .bowls { self.state.page = .inbox }
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
        // The rows of the toolbar's ✦ AI and ⋯ keep the words of `EntryMenus`.
        if EntryToolbarMenu.isToolbarRow(item) {
            let title = item.title
            defer { item.title = title }
            return validateEntryItem(item)
        }
        return validateEntryItem(item)
    }

    private func validateEntryItem(_ item: NSMenuItem) -> Bool {
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
            let deleted = !notes.isEmpty && notes.allSatisfy(\.isDeleted)
            item.title = deleted ? "Delete Now…" : "Delete"
            // Entries in a bowl shared with me to view only stay where they are.
            return deleted || notes.contains { !BowlSharing.shared.isReadOnly($0) }
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
        case #selector(recoverNote(_:)):
            item.isHidden = !notes.contains(where: \.isDeleted)
            return notes.contains(where: \.isDeleted)
        case #selector(askAboutBowl(_:)):
            return bowlToAsk != nil
        case #selector(exportBowl(_:)):
            return (state.page.projectID?.uuidString ?? openNote?.projectIDs.first) != nil
        case #selector(mergePDFs(_:)):
            let mergeable = DocumentFiles.mergeable(notes.filter { $0.isStored && !$0.isDeleted })
            item.title = mergeable.count >= 2 ? "Merge \(mergeable.count) PDFs…" : "Merge PDFs…"
            return mergeable.count >= 2 && !DocumentFiles.isBusy
        case #selector(entrySubmenu(_:)):
            return validateSubmenu(item, notes: notes, note: note)
        case #selector(showDetailsInspector(_:)):
            item.state = split.isInspectorOpen && split.inspector.mode == .details ? .on : .off
            return true
        case #selector(showRecordInspector(_:)):
            item.state = split.isInspectorOpen && split.inspector.mode == .record ? .on : .off
            return MeetingRecorder.isRecording || state.page.allowsCreating
        case #selector(pasteAsNote(_:)):
            return state.page.allowsCreating
        default:
            return true
        }
    }
}


extension MainWindowController {
    /// Whether a submenu row of the Entry or AI menu has anything for the selection.
    fileprivate func validateSubmenu(_ item: NSMenuItem, notes: [Note], note: Note?) -> Bool {
        let live = notes.filter { $0.modelContext != nil && !$0.isDeleted && !BowlSharing.shared.isReadOnly($0) }
        let todos = live.filter(\.isTodo)
        let one = live.count == 1 ? live.first : nil
        switch EntrySubmenu(rawValue: item.tag) {
        case .bowl: return !live.isEmpty
        case .due, .repeatRule: return !todos.isEmpty && todos.count == live.count
        case .later: return !live.isEmpty && live.allSatisfy(\.isInInbox)
        case .appointment, .linkAppointment: return one != nil
        case .documentKind, .document: return live.contains { $0.isStored && !$0.attachments.isEmpty }
        case .recording:
            // Copy Transcript works in a view-only bowl too.
            return note.map { $0.isRecording && !$0.isLink && !$0.isDeleted } ?? false
        case .addPages: return one.map { DocumentFiles.pdf(of: $0) != nil } ?? false
        case .pages: return live.contains { DocumentFiles.pdf(of: $0) != nil }
        case .summary: return note?.summary != nil && note?.isDeleted == false
        case nil: return false
        }
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
