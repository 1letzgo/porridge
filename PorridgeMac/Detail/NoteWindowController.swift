import AppKit

/// A note in a window of its own (double-click in the list, File › Open Note in New Window).
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static var open: [UUID: NoteWindowController] = [:]
    private let detail: NoteDetailViewController

    static func open(_ id: UUID) {
        if let existing = open[id] {
            existing.showWindow(nil)
            return
        }
        guard let note = Library.shared.note(id), note.modelContext != nil else { return }
        let controller = NoteWindowController(note: note)
        open[id] = controller
        controller.showWindow(nil)
    }

    private init(note: Note) {
        let state = WindowState()
        state.selection = [note.id]
        detail = NoteDetailViewController(note: note, state: state, startsRecording: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentViewController = detail
        window.title = note.displayTitle
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 460, height: 420)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("PorridgeNoteWindow")
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        detail.flushEditing()
        detail.removeFromParent()
        NoteWindowController.open[detail.note.id] = nil
    }

    // The Note menu's commands act on this window's note.
    @objc func noteCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = NoteCommand(rawValue: item.tag) else { return }
        detail.perform(command)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(noteCommand(_:)), let command = NoteCommand(rawValue: item.tag) {
            return detail.validate(command, item: item)
        }
        return true
    }
}
