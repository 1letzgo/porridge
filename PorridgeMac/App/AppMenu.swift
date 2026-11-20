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
        main.addItem(submenu(noteMenu(title: "Note")))
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
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Porridge")
        item(menu, "About Porridge", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        if AppUpdate.isEnabled {
            item(menu, "Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
        }
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
        item(menu, "New Bucket…", #selector(MainWindowController.newBucket(_:)), "n", [.command, .control])
        item(menu, "New Chat", #selector(MainWindowController.newChat(_:)), "k", [.command, .shift])
        menu.addItem(.separator())
        item(menu, "Import Audio…", #selector(MainWindowController.importAudio(_:)))
        item(menu, "Import Plaud…", #selector(MainWindowController.importPlaud(_:)))
        item(menu, "Import Photo or File…", #selector(MainWindowController.importFile(_:)), "i", [.command, .shift])
        menu.addItem(.separator())
        item(menu, "New Window", #selector(MainWindowController.newWindow(_:)), "n", [.command, .option])
        item(menu, "Open Note in New Window", #selector(MainWindowController.openNoteInNewWindow(_:)), "o")
        item(menu, "Close", #selector(NSWindow.performClose(_:)), "w")
        menu.addItem(.separator())
        item(menu, "Export…", #selector(MainWindowController.noteCommand(_:)), "e", [.command, .shift], tag: NoteCommand.export.rawValue)
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
        item(find, "Search Notes…", #selector(MainWindowController.focusSearch(_:)), "f", [.command, .option])
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
        item(menu, "Inbox", #selector(MainWindowController.showInbox(_:)), "1")
        item(menu, "Chat", #selector(MainWindowController.showChat(_:)), "2")
        item(menu, "Archive", #selector(MainWindowController.showArchive(_:)), "3")
        item(menu, "Recently Deleted", #selector(MainWindowController.showTrash(_:)), "4")
        menu.addItem(.separator())
        item(menu, "Summary", #selector(MainWindowController.noteCommand(_:)), "1", [.command, .control], tag: NoteCommand.showSummary.rawValue)
        item(menu, "Note", #selector(MainWindowController.noteCommand(_:)), "2", [.command, .control], tag: NoteCommand.showNote.rawValue)
        item(menu, "Transcript", #selector(MainWindowController.noteCommand(_:)), "3", [.command, .control], tag: NoteCommand.showTranscript.rawValue)
        item(menu, "Article", #selector(MainWindowController.noteCommand(_:)), "4", [.command, .control], tag: NoteCommand.showArticle.rawValue)
        menu.addItem(.separator())
        item(menu, "Show Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control])
        item(menu, "Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])
        item(menu, "Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        menu.addItem(.separator())
        item(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    /// The Note menu: also the toolbar's More menu. Grouped by a line: the note and its summary, the recording,
    /// what deletes.
    static func noteMenu(title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        let command = #selector(MainWindowController.noteCommand(_:))
        item(menu, "Pin", #selector(MainWindowController.togglePin(_:)), "p", [.command, .shift], symbol: "pin")
        item(menu, "Mark as Done", command, "d", [.command, .shift], symbol: "checkmark.square", tag: NoteCommand.toggleTodo.rawValue)
        item(menu, "Make To-do", command, "", symbol: "checklist", tag: NoteCommand.convertTodo.rawValue)
        // The due day of the selected to-dos.
        let due = NSMenu(title: "Due Date")
        let dueAction = #selector(MainWindowController.setDueDate(_:))
        item(due, "Today", dueAction, "t", [.command, .control], symbol: "star", tag: 0)
        item(due, "Tomorrow", dueAction, "m", [.command, .control], symbol: "sunrise", tag: 1)
        item(due, "Next Week", dueAction, "w", [.command, .control], symbol: "calendar.badge.clock", tag: 2)
        item(due, "Pick Date…", dueAction, "p", [.command, .control], symbol: "calendar", tag: 3)
        due.addItem(.separator())
        item(due, "Clear Due Date", dueAction, "\u{8}", [.command, .control], symbol: "calendar.badge.minus", tag: 4)
        item(menu, "Due Date", nil, symbol: "calendar").submenu = due
        item(menu, "Add Tag…", command, "t", [.command, .shift], symbol: "number", tag: NoteCommand.addTag.rawValue)
        let buckets = item(menu, "Buckets", nil, symbol: "folder")
        buckets.submenu = BucketsMenu.make()
        menu.addItem(.separator())
        item(menu, "Summarize with AI…", command, "s", [.command, .shift], symbol: "sparkles", tag: NoteCommand.summarize.rawValue)
        item(menu, "Enhance with AI…", command, "", symbol: "wand.and.stars", tag: NoteCommand.enhance.rawValue)
        item(menu, "Undo Enhance", command, "", symbol: "arrow.uturn.backward", tag: NoteCommand.undoEnhance.rawValue)
        item(menu, "Edit Summary", command, "", symbol: "pencil", tag: NoteCommand.editSummary.rawValue)
        item(menu, "Insert Summary into Note", command, "", symbol: "text.insert", tag: NoteCommand.insertSummary.rawValue)
        menu.addItem(.separator())
        item(menu, "Dictate", command, "d", [.command, .option], symbol: "mic", tag: NoteCommand.dictate.rawValue)
        item(menu, "Continue Recording", command, "", symbol: "mic.badge.plus", tag: NoteCommand.continueRecording.rawValue)
        item(menu, "Transcribe Again", #selector(MainWindowController.transcribeAgain(_:)), "", symbol: "waveform")
        item(menu, "Load Page Again", command, "", symbol: "arrow.clockwise", tag: NoteCommand.loadPageAgain.rawValue)
        item(menu, "Copy Transcript", #selector(MainWindowController.copyTranscript(_:)), "c", [.command, .shift], symbol: "doc.on.doc")
        item(menu, "Merge with…", command, "", symbol: "arrow.triangle.merge", tag: NoteCommand.merge.rawValue)
        item(menu, "Export…", command, "", symbol: "arrow.up.doc", tag: NoteCommand.export.rawValue)
        menu.addItem(.separator())
        item(menu, "Archive", #selector(MainWindowController.toggleArchive(_:)), "", symbol: "archivebox")
        item(menu, "Recover", #selector(MainWindowController.recoverNote(_:)), "", symbol: "arrow.uturn.backward")
        item(menu, "Delete Recording…", command, "", symbol: "waveform.slash", tag: NoteCommand.deleteRecording.rawValue)
        item(menu, "Delete", #selector(MainWindowController.deleteNote(_:)), "\u{8}", .command, symbol: "trash")
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

/// The buckets as a menu for the open note (Note › Buckets): ticked where it is in, a click puts it in or takes it out.
@MainActor
final class BucketsMenu: NSObject, NSMenuDelegate {
    /// Every menu keeps its own (a menu can be the submenu of one item only); the delegates stay alive here.
    private static var all: [BucketsMenu] = []
    let menu = NSMenu(title: "Buckets")

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
            menu.addItem(withTitle: "No Note Selected", action: nil, keyEquivalent: "").isEnabled = false
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
