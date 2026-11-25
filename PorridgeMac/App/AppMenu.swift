import AppKit

/// The menu bar. Every command of the toolbars is here too, with its shortcut; what does not apply right now is
/// dimmed, not hidden. Commands go up the responder chain (text view, note, window, app).
@MainActor
enum AppMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(entryMenu()))
        main.addItem(submenu(aiMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func item(
        _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
        symbol: String? = nil, tag: Int = 0
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? .symbol(symbol) }
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Porridge")
        item(menu, "About Porridge", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        menu.addItem(.separator())
        item(menu, "Settings…", #selector(AppDelegate.showSettings(_:)), ",")
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = item(menu, "Services", nil)
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        item(menu, "Hide Porridge", #selector(NSApplication.hide(_:)), "h")
        item(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        item(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        item(menu, "Quit Porridge", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        item(menu, "New Note", #selector(MainWindowController.newNote(_:)), "n")
        item(menu, "New To-do", #selector(MainWindowController.newTodo(_:)), "n", [.command, .shift], symbol: "checklist")
        item(menu, "Record Meeting", #selector(MainWindowController.recordMeeting(_:)), "r")
        item(menu, "Add Link…", #selector(MainWindowController.addLink(_:)), "l")
        item(menu, "New Bowl…", #selector(MainWindowController.newBucket(_:)), "n", [.command, .control])
        menu.addItem(.separator())
        item(menu, "Import Audio…", #selector(MainWindowController.importAudio(_:)))
        item(menu, "Import Plaud…", #selector(MainWindowController.importPlaud(_:)))
        item(menu, "Import Photo or File…", #selector(MainWindowController.importFile(_:)), "i", [.command, .shift])
        // Continuity Camera: the system fills it with "Take Photo" and "Scan Documents" of the iPhone or iPad nearby.
        let device = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(device)
        menu.addItem(.separator())
        item(menu, "New Window", #selector(MainWindowController.newWindow(_:)), "n", [.command, .option])
        item(menu, "Open in New Window", #selector(MainWindowController.openNoteInNewWindow(_:)), "o")
        item(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        menu.addItem(.separator())
        item(menu, "Export…", #selector(MainWindowController.noteCommand(_:)), "e", [.command, .shift], tag: NoteCommand.export.rawValue)
        item(menu, "Export Bowl…", #selector(MainWindowController.exportBowl(_:)))
        item(menu, "Export Everything…", #selector(MainWindowController.exportEverything(_:)))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        item(menu, "Undo", Selector(("undo:")), "z")
        item(menu, "Redo", Selector(("redo:")), "z", [.command, .shift])
        menu.addItem(.separator())
        item(menu, "Cut", #selector(NSText.cut(_:)), "x")
        item(menu, "Copy", #selector(NSText.copy(_:)), "c")
        item(menu, "Paste", #selector(NSText.paste(_:)), "v")
        item(menu, "Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift])
        item(menu, "Delete", #selector(NSText.delete(_:)))
        item(menu, "Select All", #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        item(menu, "Paste as New Note", #selector(MainWindowController.pasteAsNote(_:)), "v", [.command, .shift])
        menu.addItem(.separator())
        let find = NSMenu(title: "Find")
        item(find, "Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue))
        item(find, "Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: Int(NSFindPanelAction.next.rawValue))
        item(find, "Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: Int(NSFindPanelAction.previous.rawValue))
        item(find, "Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: Int(NSFindPanelAction.setFindString.rawValue))
        item(menu, "Find", nil).submenu = find
        let spelling = NSMenu(title: "Spelling and Grammar")
        item(spelling, "Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":")
        item(spelling, "Check Document Now", #selector(NSText.checkSpelling(_:)), ";")
        item(spelling, "Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:)))
        item(menu, "Spelling and Grammar", nil).submenu = spelling
        let substitutions = NSMenu(title: "Substitutions")
        item(substitutions, "Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)))
        item(substitutions, "Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:)))
        item(substitutions, "Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:)))
        item(menu, "Substitutions", nil).submenu = substitutions
        let speech = NSMenu(title: "Speech")
        item(speech, "Start Speaking", #selector(NSTextView.startSpeaking(_:)))
        item(speech, "Stop Speaking", #selector(NSTextView.stopSpeaking(_:)))
        item(menu, "Speech", nil).submenu = speech
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        item(menu, "Bold", #selector(NoteEditorView.toggleBold(_:)), "b")
        item(menu, "Italic", #selector(NoteEditorView.toggleItalic(_:)), "i")
        menu.addItem(.separator())
        item(menu, "Title", #selector(NoteEditorView.makeHeading1(_:)), "1", [.command, .option])
        item(menu, "Heading", #selector(NoteEditorView.makeHeading2(_:)), "2", [.command, .option])
        item(menu, "Subheading", #selector(NoteEditorView.makeHeading3(_:)), "3", [.command, .option])
        item(menu, "Body", #selector(NoteEditorView.makeBody(_:)), "0", [.command, .option])
        menu.addItem(.separator())
        item(menu, "Bulleted List", #selector(NoteEditorView.makeBulleted(_:)), "8", [.command, .shift])
        item(menu, "Numbered List", #selector(NoteEditorView.makeNumbered(_:)), "7", [.command, .shift])
        item(menu, "Checklist", #selector(NoteEditorView.makeChecklist(_:)), "l", [.command, .shift])
        item(menu, "Quote", #selector(NoteEditorView.makeQuote(_:)), "'", [.command, .shift])
        menu.addItem(.separator())
        item(menu, "Indent", #selector(NoteEditorView.indentItems(_:)), "]")
        item(menu, "Outdent", #selector(NoteEditorView.outdentItems(_:)), "[")
        menu.addItem(.separator())
        item(menu, "Move Line Up", #selector(NoteEditorView.moveLineUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option])
        item(menu, "Move Line Down", #selector(NoteEditorView.moveLineDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option])
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        item(menu, "Search or Ask…", #selector(MainWindowController.showCommandBar(_:)), "k", symbol: "magnifyingglass")
        menu.addItem(.separator())
        // The four places, then the two fixed rows at the end of the sidebar.
        item(menu, "Today", #selector(MainWindowController.showToday(_:)), "1", symbol: "calendar")
        item(menu, "Inbox", #selector(MainWindowController.showInbox(_:)), "2", symbol: "tray")
        item(menu, "Bowls", #selector(MainWindowController.showBowls(_:)), "3", symbol: Places.bowlsSymbol)
        item(menu, "Chat", #selector(MainWindowController.showChat(_:)), "4", symbol: "bubble.left.and.bubble.right")
        item(menu, "Archive", #selector(MainWindowController.showArchive(_:)), "5", symbol: "archivebox")
        item(menu, "Recently Deleted", #selector(MainWindowController.showTrash(_:)), "6", symbol: "trash")
        menu.addItem(.separator())
        item(menu, "Open To-dos", #selector(MainWindowController.showTodos(_:)), "", symbol: "checklist")
        item(menu, "Weekly Review", #selector(MainWindowController.showWeeklyReview(_:)), "", symbol: "calendar.badge.checkmark")
        item(menu, "Triage Inbox", #selector(MainWindowController.triageInbox(_:)), "", symbol: "keyboard")
        menu.addItem(.separator())
        item(menu, "Summary", #selector(MainWindowController.noteCommand(_:)), "1", [.command, .control], tag: NoteCommand.showSummary.rawValue)
        item(menu, "Note", #selector(MainWindowController.noteCommand(_:)), "2", [.command, .control], tag: NoteCommand.showNote.rawValue)
        item(menu, "Transcript", #selector(MainWindowController.noteCommand(_:)), "3", [.command, .control], tag: NoteCommand.showTranscript.rawValue)
        item(menu, "Article", #selector(MainWindowController.noteCommand(_:)), "4", [.command, .control], tag: NoteCommand.showArticle.rawValue)
        menu.addItem(.separator())
        item(menu, "Details", #selector(MainWindowController.showDetailsInspector(_:)), "i", [.command, .option], symbol: "info.circle")
        item(menu, "Record", #selector(MainWindowController.showRecordInspector(_:)), "r", [.command, .option], symbol: "mic")
        menu.addItem(.separator())
        item(menu, "Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        item(menu, "Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])
        item(menu, "Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        menu.addItem(.separator())
        item(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    /// The Entry menu (was "Note"): what is done to the selected entries, by verb. What does not apply is dimmed; the
    /// toolbar's ⋯ shows only the short More of the entry's kind (`EntryMenus.more`).
    static func entryMenu() -> NSMenu {
        let menu = NSMenu(title: "Entry")
        let command = #selector(MainWindowController.noteCommand(_:))
        item(menu, "Pin", #selector(MainWindowController.togglePin(_:)), "p", [.command, .shift], symbol: "pin")
        item(menu, "Mark as Done", command, "d", [.command, .shift], symbol: "checkmark.square", tag: NoteCommand.toggleTodo.rawValue)
        item(menu, "Convert to To-do", command, "", symbol: "checklist", tag: NoteCommand.convertTodo.rawValue)
        menu.addItem(.separator())
        // Into one bowl or back to the Inbox.
        let bowl = item(menu, "Bowl", #selector(MainWindowController.entrySubmenu(_:)), symbol: "folder", tag: EntrySubmenu.bowl.rawValue)
        bowl.submenu = BucketsMenu.make()
        // The due day of the selected to-dos, and how they repeat.
        let due = NSMenu(title: "Due Date")
        let dueAction = #selector(MainWindowController.setDueDate(_:))
        item(due, "Today", dueAction, "t", [.command, .control], symbol: "star", tag: 0)
        item(due, "Tomorrow", dueAction, "m", [.command, .control], symbol: "sunrise", tag: 1)
        item(due, "Next Week", dueAction, "w", [.command, .control], symbol: "calendar.badge.clock", tag: 2)
        item(due, "Pick Date…", dueAction, "p", [.command, .control], symbol: "calendar", tag: 3)
        let repeatItem = item(due, "Repeat", #selector(MainWindowController.entrySubmenu(_:)), symbol: "repeat", tag: EntrySubmenu.repeatRule.rawValue)
        repeatItem.submenu = DynamicMenu.make("Repeat") { menu, controller in
            let todos = controller.selectedNotes.filter { $0.isTodo && $0.modelContext != nil && !$0.isDeleted }
            guard let sub = DueDateMenu.repeatItem(for: todos, window: controller.window).submenu else { return }
            DynamicMenu.move(sub, into: menu)
        }
        due.addItem(.separator())
        item(due, "Clear Due Date", dueAction, "\u{8}", [.command, .control], symbol: "calendar.badge.minus", tag: 4)
        item(menu, "Due Date", #selector(MainWindowController.entrySubmenu(_:)), symbol: "calendar", tag: EntrySubmenu.due.rawValue).submenu = due
        item(menu, "Add Tag…", command, "t", [.command, .shift], symbol: "number", tag: NoteCommand.addTag.rawValue)
        menu.addItem(.separator())
        // The appointment the entry belongs to.
        let appointment = NSMenu(title: "Appointment")
        let link = item(appointment, "Link Appointment", #selector(MainWindowController.entrySubmenu(_:)), symbol: "calendar.badge.plus", tag: EntrySubmenu.linkAppointment.rawValue)
        link.submenu = DynamicMenu.make("Link Appointment") { menu, controller in
            guard let note = controller.openNote, note.modelContext != nil, !note.isDeleted else { return }
            let links = AppointmentActions.linkMenu(for: note)
            // "Remove Appointment" has its own row beside.
            if let remove = links.items.last(where: { $0.title == String(localized: "Remove Appointment") }) {
                links.removeItem(remove)
                if links.items.last?.isSeparatorItem == true { links.removeItem(at: links.items.count - 1) }
            }
            DynamicMenu.move(links, into: menu)
        }
        item(appointment, "Remove Appointment", command, symbol: "calendar.badge.minus", tag: NoteCommand.removeAppointment.rawValue)
        item(menu, "Appointment", #selector(MainWindowController.entrySubmenu(_:)), symbol: "calendar", tag: EntrySubmenu.appointment.rawValue).submenu = appointment
        // A stored document: its kind, sender and the rest of its details.
        let document = NSMenu(title: "Document")
        let kind = item(document, "Kind", #selector(MainWindowController.entrySubmenu(_:)), symbol: "tag", tag: EntrySubmenu.documentKind.rawValue)
        kind.submenu = DynamicMenu.make("Kind") { menu, controller in
            let documents = controller.selectedNotes.filter { $0.isStored && !$0.attachments.isEmpty && !$0.isDeleted && $0.modelContext != nil }
            guard !documents.isEmpty else { return }
            let context = Library.shared.context
            let none = menu.add("Not Set") { Undoable.apply(.kind(nil), to: documents, in: context) }
            none.state = documents.allSatisfy { $0.documentInfo?.kind == nil } ? .on : .off
            menu.addItem(.separator())
            for kind in DocumentKind.allCases {
                let item = menu.add(kind.title, symbol: kind.symbol) { Undoable.apply(.kind(kind), to: documents, in: context) }
                item.state = documents.allSatisfy { $0.documentInfo?.kind == kind } ? .on : .off
            }
        }
        item(document, "Set Sender…", command, symbol: "person.crop.square", tag: NoteCommand.setSender.rawValue)
        item(document, "Edit Details…", command, symbol: "doc.text", tag: NoteCommand.editDocument.rawValue)
        item(menu, "Document", #selector(MainWindowController.entrySubmenu(_:)), symbol: "doc.text", tag: EntrySubmenu.document.rawValue).submenu = document
        // A meeting's recording.
        let recording = NSMenu(title: "Recording")
        item(recording, "Continue Recording", command, "", symbol: "mic.badge.plus", tag: NoteCommand.continueRecording.rawValue)
        item(recording, "Transcribe Again", #selector(MainWindowController.transcribeAgain(_:)), "", symbol: "waveform")
        item(recording, "Merge with…", command, "", symbol: "arrow.triangle.merge", tag: NoteCommand.merge.rawValue)
        item(recording, "Copy Transcript", #selector(MainWindowController.copyTranscript(_:)), "c", [.command, .shift], symbol: "doc.on.doc")
        recording.addItem(.separator())
        item(recording, "Delete Recording…", command, "", symbol: "waveform.slash", tag: NoteCommand.deleteRecording.rawValue)
        item(menu, "Recording", #selector(MainWindowController.entrySubmenu(_:)), symbol: "waveform", tag: EntrySubmenu.recording.rawValue).submenu = recording
        // A PDF's pages.
        let pages = NSMenu(title: "Pages")
        item(pages, "Edit Pages…", command, symbol: "doc.on.doc", tag: NoteCommand.editPages.rawValue)
        let addPages = NSMenu(title: "Add Pages")
        item(addPages, "From a File…", command, symbol: "doc.badge.plus", tag: NoteCommand.addPagesFromFile.rawValue)
        item(pages, "Add Pages", #selector(MainWindowController.entrySubmenu(_:)), symbol: "plus.rectangle.on.rectangle", tag: EntrySubmenu.addPages.rawValue).submenu = addPages
        item(pages, "Merge PDFs…", #selector(MainWindowController.mergePDFs(_:)), symbol: "arrow.triangle.merge")
        item(menu, "Pages", #selector(MainWindowController.entrySubmenu(_:)), symbol: "doc.on.doc", tag: EntrySubmenu.pages.rawValue).submenu = pages
        item(menu, "Load Page Again", command, "", symbol: "arrow.clockwise", tag: NoteCommand.loadPageAgain.rawValue)
        menu.addItem(.separator())
        item(menu, "Dictate", command, "d", [.command, .option], symbol: "mic", tag: NoteCommand.dictate.rawValue)
        item(menu, "Save as Template…", command, "", symbol: "doc.badge.plus", tag: NoteCommand.saveAsTemplate.rawValue)
        menu.addItem(.separator())
        // Only for entries in Recently Deleted (hidden otherwise); Delete then reads "Delete Now…".
        item(menu, "Recover", #selector(MainWindowController.recoverNote(_:)), "", symbol: "arrow.uturn.backward")
        item(menu, "Delete", #selector(MainWindowController.deleteNote(_:)), "\u{8}", .command, symbol: "trash")
        return menu
    }

    /// The AI menu: chats, and what a model does to the open entry.
    static func aiMenu() -> NSMenu {
        let menu = NSMenu(title: "AI")
        let command = #selector(MainWindowController.noteCommand(_:))
        item(menu, "New Chat", #selector(MainWindowController.newChat(_:)), "k", [.command, .shift], symbol: "bubble.left.and.bubble.right")
        item(menu, "Ask About This Bowl", #selector(MainWindowController.askAboutBowl(_:)), symbol: "bubble.left.and.text.bubble.right")
        menu.addItem(.separator())
        item(menu, "Summarize with AI…", command, "s", [.command, .shift], symbol: "sparkles", tag: NoteCommand.summarize.rawValue)
        item(menu, "Suggest To-dos", command, "", symbol: "checklist", tag: NoteCommand.suggestTodos.rawValue)
        item(menu, "Enhance with AI…", command, "", symbol: "wand.and.stars", tag: NoteCommand.enhance.rawValue)
        item(menu, "Undo Enhance", command, "", symbol: "arrow.uturn.backward", tag: NoteCommand.undoEnhance.rawValue)
        item(menu, "Split into Bowl…", command, "", symbol: "square.split.2x2", tag: NoteCommand.splitIntoBowl.rawValue)
        item(menu, "Rewrite with AI…", #selector(NoteEditorView.rewriteWithAI(_:)), "j", symbol: "pencil.line")
        menu.addItem(.separator())
        let summary = NSMenu(title: "Summary")
        item(summary, "Edit Summary", command, "", symbol: "pencil", tag: NoteCommand.editSummary.rawValue)
        item(summary, "Insert into Note", command, "", symbol: "text.insert", tag: NoteCommand.insertSummary.rawValue)
        item(summary, "Copy Summary", command, "", symbol: "doc.on.doc", tag: NoteCommand.copySummary.rawValue)
        summary.addItem(.separator())
        item(summary, "Delete Summary…", command, "", symbol: "trash", tag: NoteCommand.deleteSummary.rawValue)
        item(menu, "Summary", #selector(MainWindowController.entrySubmenu(_:)), symbol: "text.alignleft", tag: EntrySubmenu.summary.rawValue).submenu = summary
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        item(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        item(menu, "Porridge", #selector(AppDelegate.showMainWindow(_:)), "0")
        menu.addItem(.separator())
        item(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        return menu
    }
}

/// The submenus of the Entry and AI menus: their row is dimmed when nothing in them applies to the selection.
enum EntrySubmenu: Int {
    case bowl = 1, due, repeatRule, linkAppointment, appointment, documentKind, document, recording, addPages, pages, summary
}

/// A submenu filled when it opens, for the entries selected in the window in front (Entry › Repeat, …).
@MainActor
final class DynamicMenu: NSObject, NSMenuDelegate {
    /// Every menu keeps its own delegate; they stay alive here.
    private static var all: [DynamicMenu] = []
    let menu: NSMenu
    private let fill: (NSMenu, MainWindowController) -> Void

    private init(_ title: String, fill: @escaping (NSMenu, MainWindowController) -> Void) {
        menu = NSMenu(title: title)
        self.fill = fill
        super.init()
        menu.delegate = self
    }

    static func make(_ title: String, fill: @escaping (NSMenu, MainWindowController) -> Void) -> NSMenu {
        let dynamic = DynamicMenu(title, fill: fill)
        all.append(dynamic)
        return dynamic.menu
    }

    /// The items of one menu moved into another (an item belongs to one menu at a time).
    static func move(_ source: NSMenu, into menu: NSMenu) {
        for item in source.items {
            source.removeItem(item)
            menu.addItem(item)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let controller = MainWindowController.frontIfAny { fill(menu, controller) }
        if menu.items.isEmpty {
            menu.addItem(withTitle: String(localized: "Nothing Here"), action: nil, keyEquivalent: "").isEnabled = false
        }
    }
}

/// The bowls as a menu for the open note (Entry › Bowl): ticked where it is in, a click puts it in or takes it out.
@MainActor
final class BucketsMenu: NSObject, NSMenuDelegate {
    /// Every menu keeps its own (a menu can be the submenu of one item only); the delegates stay alive here.
    private static var all: [BucketsMenu] = []
    let menu = NSMenu(title: "Bowl")

    static func make() -> NSMenu {
        let buckets = BucketsMenu()
        all.append(buckets)
        return buckets.menu
    }

    override init() {
        super.init()
        menu.delegate = self
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller = MainWindowController.frontIfAny else { return }
        let notes = controller.selectedNotes.filter { $0.modelContext != nil && !$0.isDeleted }
        guard !notes.isEmpty else {
            menu.addItem(withTitle: "No Entry Selected", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        for item in NoteOperations.bucketMenu(for: notes, window: controller.window).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }
}

extension MainWindowController {
    /// The window in front, if any.
    static var frontIfAny: MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController { return main }
        return all.first { $0.window?.isVisible == true }
    }
}
