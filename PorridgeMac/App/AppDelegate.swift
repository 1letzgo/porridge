import AppKit
import CloudKit
import SwiftData

/// The app: the menu bar, the main windows, Settings and the dictation in the menu bar.
/// Updates come through TestFlight.
/// Closing the last window keeps Porridge running in the menu bar, so the dictation shortcut stays available.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        DictationSettings.registerDefaults()
        NSApp.mainMenu = AppMenu.build()
        // The store is opened before windows are restored.
        _ = Library.shared
        // Links between entries show the current title of the entry they point to.
        EntryLinks.install { Library.shared.note($0) }
        // `porridge://entry/<UUID>`: the entry is shown in the window in front.
        NotificationCenter.default.addObserver(forName: .porridgeOpenEntry, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.openRequestedEntry() }
        }
        // The other `porridge://` links (new, meeting, inbox, todos, search): the same in the window in front.
        NotificationCenter.default.addObserver(forName: .porridgeQuickAction, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppDelegate.runQuickAction() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        if MainWindowController.all.isEmpty {
            MainWindowController.open()
        }
        statusItem = StatusItemController()
        // The alert a minute before a meeting, and the countdown in the menu bar.
        MeetingAlertController.shared.onTick = { [weak self] in self?.statusItem?.refreshCountdown() }
        MeetingAlertController.shared.start()
        // The local MCP server, when it is turned on in Settings.
        MCPService.shared.applySettings()
        #if DEBUG
        DebugDriver.start()
        #endif
        // The shortcuts work even when no window is open.
        GlobalShortcuts.shared.reload()
        // The undo toast, the hint of the day.
        UndoToastPanel.start()
        DailyHintFeed.start()
        Task { @MainActor in
            await Library.shared.start()
            // Loading the speech model takes a moment; do it before the first dictation.
            if TranscriptionEngine.asrInstalled || AppSettings.speechEngine == .apple {
                try? await ModelManager.shared.ensureASR()
            }
        }
        let window = MainWindowController.frontIfAny?.window
        if let error = AppContainer.storeError {
            Alerts.inform(
                "Your Notes Could Not Be Opened",
                message: "Porridge started without them. They are still on this device, but nothing you write now is kept. Please update the app or get in touch.\n\n\(error)",
                in: window
            )
        } else {
            Onboarding.showIfNeeded(in: window)
        }
    }

    /// Back from System Settings: a permission may have been given in the meantime.
    func applicationDidBecomeActive(_ notification: Notification) {
        if DictationController.shared.shortcutNeedsAccessibility || DictationController.shared.shortcutUnavailable {
            DictationController.shared.reloadShortcut()
        }
        if !GlobalShortcuts.shared.unavailable.isEmpty { GlobalShortcuts.shared.reload() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A click on the Dock icon with no window open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Quitting during a meeting recording would cut it off: ask first, and keep what was recorded.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RecordingWindowController.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A Meeting Is Being Recorded"
        alert.informativeText = "Quitting stops the recording. What was recorded so far is kept."
        alert.addButton(withTitle: "Stop Recording and Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        RecordingWindowController.stopAll()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in MainWindowController.all { controller.split.detail.noteDetail?.flushEditing() }
        Library.shared.save()
    }

    /// Files dropped on the Dock icon or opened with Porridge come in as notes.
    func application(_ application: NSApplication, open urls: [URL]) {
        let controller = MainWindowController.front
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { Intake.addFiles(files, project: controller.state.projectForNew, state: controller.state) }
        for url in urls where url.scheme == "http" || url.scheme == "https" {
            Intake.addLink(url.absoluteString, project: controller.state.projectForNew, state: controller.state)
        }
        for url in urls where url.scheme == PorridgeURL.scheme { EntryLinkRouter.handle(url) }
    }

    /// Shows the entry an entry link asked for, when this Mac has it.
    static func openRequestedEntry() {
        guard let id = EntryLinkRouter.take(), let note = Library.shared.note(id) else { return }
        NSApp.activate()
        let controller = MainWindowController.front
        controller.window?.makeKeyAndOrderFront(nil)
        controller.state.reveal(note)
    }

    /// A `porridge://` link other than an entry (made for the iPhone's widgets, but they mean the same here).
    static func runQuickAction() {
        guard let (action, fromLink) = QuickActionCenter.takeRequest() else { return }
        NSApp.activate()
        let controller = MainWindowController.front
        controller.window?.makeKeyAndOrderFront(nil)
        switch action {
        case .newNote: controller.newNote(nil)
        case .startMeeting:
            // Any app or website can open a `porridge://meeting` link: Porridge is in front and asks first.
            if fromLink {
                let alert = NSAlert()
                alert.messageText = String(localized: "Start Recording?")
                alert.informativeText = String(localized: "A link asked Porridge to record a meeting.")
                alert.addButton(withTitle: String(localized: "Start Recording"))
                let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
                cancel.keyEquivalent = "\u{1b}"
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            controller.recordMeeting(nil)
        case .openInbox: controller.showInbox(nil)
        case .openTodos: controller.showTodos(nil)
        case .search(let query): controller.search(for: query)
        case .openNote(let id): EntryLinkRouter.request(id)
        }
    }

    /// An invitation to a shared bowl was opened: the bowl joins the sidebar.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in
            await BowlSharing.shared.accept(metadata)
            if let notice = BowlSharing.shared.notice {
                BowlSharing.shared.notice = nil
                Alerts.inform(String(localized: "Sharing"), message: notice, in: MainWindowController.frontIfAny?.window)
            }
        }
    }

    // MARK: Commands

    @objc func showSettings(_ sender: Any?) {
        NSApp.activate()
        SettingsWindowController.shared.showWindow(nil)
        SettingsWindowController.shared.window?.makeKeyAndOrderFront(nil)
    }

    @objc func showMainWindow(_ sender: Any?) {
        NSApp.activate()
        let controller = MainWindowController.front
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// File › New Note with no window open.
    @objc func newNote(_ sender: Any?) {
        showMainWindow(nil)
        MainWindowController.front.newNote(sender)
    }
}
