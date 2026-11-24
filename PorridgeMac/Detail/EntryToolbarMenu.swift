import AppKit

/// The toolbar's ✦ AI and ⋯ More: only what `EntryMenus` lists for the open entry's kind (the same contents as the
/// iPhone's pills), filled when the menu opens. Each row sends the same action as its row in the Entry or AI menu,
/// so it is validated and run the same way.
@MainActor
final class EntryToolbarMenu: NSObject, NSMenuDelegate {
    enum Kind { case ai, more }

    /// The delegates stay alive here (a toolbar item can be made again when the toolbar is customized).
    private static var all: [EntryToolbarMenu] = []
    private let kind: Kind
    let menu = NSMenu()

    private init(_ kind: Kind) {
        self.kind = kind
        super.init()
        menu.delegate = self
    }

    static func make(_ kind: Kind) -> NSMenu {
        let made = EntryToolbarMenu(kind)
        all.append(made)
        return made.menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller = MainWindowController.frontIfAny, let note = controller.openNote else { return }
        for item in Self.items(kind, for: note, in: controller) { menu.addItem(item) }
    }

    /// The rows for an entry, with separators between the groups.
    static func items(_ kind: Kind, for note: Note, in controller: MainWindowController) -> [NSMenuItem] {
        let context = controller.entryContext(for: note)
        var rows: [NSMenuItem] = []
        switch kind {
        case .ai:
            for (index, group) in EntryMenus.ai(for: note, context: context).enumerated() {
                if index > 0 { rows.append(.separator()) }
                rows += group.map { aiRow($0) }
            }
        case .more:
            for (index, group) in EntryMenus.more(for: note, context: context, platform: .mac).enumerated() {
                if index > 0 { rows.append(.separator()) }
                rows += group.compactMap { moreRow($0, note: note, controller: controller) }
            }
        }
        return rows
    }

    private static func entry(_ title: String, symbol: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command, command: NoteCommand? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let command { item.tag = command.rawValue }
        return item
    }

    private static let command = #selector(MainWindowController.noteCommand(_:))

    /// A row of ✦ AI; every item has its action here (the switch is the check that none is left out).
    static func aiRow(_ item: EntryMenus.AIItem) -> NSMenuItem {
        let title = item.title
        let symbol = item.systemImage
        let row: NSMenuItem = switch item {
        case .enhance: entry(title, symbol: symbol, command, command: .enhance)
        case .undoEnhance: entry(title, symbol: symbol, command, command: .undoEnhance)
        case .summarize: entry(title, symbol: symbol, command, key: "s", modifiers: [.command, .shift], command: .summarize)
        case .suggestTodos: entry(title, symbol: symbol, command, command: .suggestTodos)
        case .rewriteSelection: entry(title, symbol: symbol, #selector(NoteEditorView.rewriteWithAI(_:)), key: "j")
        case .splitIntoBowl: entry(title, symbol: symbol, command, command: .splitIntoBowl)
        case .askAboutBowl: entry(title, symbol: symbol, #selector(MainWindowController.askAboutBowl(_:)))
        }
        // The toolbar says it in its own words ("Summarize Again…"); the menu bar's validation leaves them.
        row.representedObject = toolbarMark
        return row
    }

    /// A row of ⋯ More; every item has its action here. Nil for what the Mac does not have (Scan More Pages).
    static func moreRow(_ item: EntryMenus.MoreItem, note: Note, controller: MainWindowController) -> NSMenuItem? {
        let title = item.title(for: note)
        let symbol = item.systemImage(for: note)
        let row: NSMenuItem
        switch item {
        case .pin: row = entry(title, symbol: symbol, #selector(MainWindowController.togglePin(_:)), key: "p", modifiers: [.command, .shift])
        case .markDone: row = entry(title, symbol: symbol, command, key: "d", modifiers: [.command, .shift], command: .toggleTodo)
        case .convertToTodo, .convertToNote: row = entry(title, symbol: symbol, command, command: .convertTodo)
        case .later:
            row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            let later = NoteOperations.laterMenu(for: [note], window: controller.window)
            if note.isSnoozed() {
                later.addItem(.separator())
                later.add("Back to Inbox Now", symbol: "tray.and.arrow.down") { InboxSnooze.unsnooze([note], in: Library.shared.context) }
            }
            row.submenu = later
        case .markPaid: row = entry(title, symbol: symbol, command, command: .markPaid)
        case .editPages: row = entry(title, symbol: symbol, command, command: .editPages)
        case .scanMorePages: return nil
        case .openInBrowser: row = entry(title, symbol: symbol, command, command: .openInBrowser)
        case .copyLink: row = entry(title, symbol: symbol, command, command: .copyLink)
        case .loadPageAgain: row = entry(title, symbol: symbol, command, command: .loadPageAgain)
        case .continueRecording: row = entry(title, symbol: symbol, command, command: .continueRecording)
        case .transcribeAgain: row = entry(title, symbol: symbol, #selector(MainWindowController.transcribeAgain(_:)))
        case .mergeWith: row = entry(title, symbol: symbol, command, command: .merge)
        case .copyTranscript: row = entry(title, symbol: symbol, #selector(MainWindowController.copyTranscript(_:)), key: "c", modifiers: [.command, .shift])
        case .deleteRecording: row = entry(title, symbol: symbol, command, command: .deleteRecording)
        case .saveAsTemplate: row = entry(title, symbol: symbol, command, command: .saveAsTemplate)
        case .copy: row = entry(title, symbol: symbol, command, command: .copyText)
        case .openInNewWindow: row = entry(title, symbol: symbol, #selector(MainWindowController.openNoteInNewWindow(_:)), key: "o")
        case .delete: row = entry(title, symbol: symbol, #selector(MainWindowController.deleteNote(_:)), key: "\u{8}")
        case .recover: row = entry(title, symbol: symbol, #selector(MainWindowController.recoverNote(_:)))
        case .deleteNow: row = entry(title, symbol: symbol, #selector(MainWindowController.deleteNote(_:)))
        }
        row.representedObject = toolbarMark
        return row
    }

    /// Marks a row of these menus (`isToolbarRow`).
    private static let toolbarMark = "entryToolbarMenu"

    /// A row of the toolbar's menus: its title is `EntryMenus`' and stays.
    static func isToolbarRow(_ item: NSMenuItem) -> Bool {
        item.representedObject as? String == toolbarMark
    }
}
