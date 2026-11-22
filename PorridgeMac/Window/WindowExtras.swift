import AppKit
import SwiftUI

extension MainWindowController {
    /// ⌘K: the command bar over this window.
    @objc func showCommandBar(_ sender: Any?) {
        CommandBarController.show(for: self)
    }

    /// View › Triage Inbox and the Inbox's "Triage": the Inbox with the keyboard (J/K, L, F, D).
    @objc func triageInbox(_ sender: Any?) {
        state.page = .inbox
        split.content.notes.toggleTriage()
    }

    /// View › Weekly Review, the button in the Inbox's head and the command bar.
    @objc func showWeeklyReview(_ sender: Any?) {
        WeeklyReviewWindowController.show(opening: { [weak self] id in
            guard let self, let note = Library.shared.note(id) else { return }
            self.window?.makeKeyAndOrderFront(nil)
            self.state.reveal(note)
        })
    }
}

/// The weekly review in a window of its own (the SwiftUI view the iPhone shows as a sheet). It follows the entries.
@MainActor
final class WeeklyReviewWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: WeeklyReviewWindowController?
    private var token: UUID?
    private var onOpen: (UUID) -> Void = { _ in }

    static func show(opening onOpen: @escaping (UUID) -> Void) {
        let controller = shared ?? WeeklyReviewWindowController()
        shared = controller
        controller.onOpen = onOpen
        controller.render()
        NSApp.activate()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true
        )
        window.title = String(localized: "Weekly Review")
        window.minSize = NSSize(width: 440, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("PorridgeWeeklyReview")
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("PorridgeWeeklyReview") { window.center() }
        token = Library.shared.observe { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func render() {
        let library = Library.shared
        let view = WeeklyReviewView(notes: library.notes, bowls: library.projects) { [weak self] id in self?.onOpen(id) }
        if let hosting = window?.contentViewController as? NSHostingController<WeeklyReviewView> {
            hosting.rootView = view
        } else {
            window?.contentViewController = NSHostingController(rootView: view)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Library.shared.stopObserving(token)
        token = nil
        WeeklyReviewWindowController.shared = nil
    }
}

/// Keeps the hint of the day up to date on the Mac: when the entries change and when the app comes forward.
@MainActor
enum DailyHintFeed {
    private static var token: UUID?

    static func start() {
        let library = Library.shared
        token = library.observe { DailyHints.shared.refresh(notes: library.notes) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DailyHints.shared.refresh(notes: Library.shared.notes) }
        }
        DailyHints.shared.refresh(notes: library.notes)
    }

    /// The hint was clicked: what it is about opens in the window.
    static func open(_ hint: DailyHint, in controller: MainWindowController?) {
        DailyHints.shared.open()
        guard let controller else { return }
        switch hint.kind {
        case .meetingTodos:
            if let id = hint.noteID, let note = Library.shared.note(id) { controller.state.reveal(note) }
        case .overdue:
            controller.state.page = .todos
        case .inbox:
            controller.state.page = .inbox
        }
    }
}
