import AppKit
import SwiftData

/// The app: the menu bar, the main windows, Settings, the dictation in the menu bar, and the update check.
/// Closing the last window keeps Porridge running in the menu bar, so the dictation shortcut stays available.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var statusItem: StatusItemController?
    private var updates: UpdateNotice?

    func applicationWillFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IONBF, 0)
        AppSettings.registerDefaults()
        DictationSettings.registerDefaults()
        NSApp.mainMenu = AppMenu.build()
        // The store is opened before windows are restored.
        _ = Library.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        if MainWindowController.all.isEmpty {
            MainWindowController.open()
        }
        statusItem = StatusItemController()
        #if DEBUG
        DebugDriver.start()
        #endif
        updates = UpdateNotice()
        // The shortcut works even when no window is open.
        DictationController.shared.reloadShortcut()
        AppUpdate.shared.start()
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
        NextcloudSync.shared.syncSoon(after: .zero)
        if DictationController.shared.shortcutNeedsAccessibility || DictationController.shared.shortcutUnavailable {
            DictationController.shared.reloadShortcut()
        }
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

    /// Asked by the user, so the result is always told: a newer version, up to date, or what went wrong.
    @objc func checkForUpdates(_ sender: Any?) {
        Task { @MainActor in
            let outcome = await AppUpdate.shared.check(manual: true)
            let window = MainWindowController.frontIfAny?.window
            switch outcome {
            case .available(let release):
                updates?.show(release, again: true)
            case .upToDate:
                Alerts.inform("Porridge Is Up to Date", message: "Version \(AppUpdate.currentVersion) is the newest one.", in: window)
            case .failed(let reason):
                Alerts.inform("Could Not Check for Updates", message: reason, in: window)
            case .alreadyChecking:
                Alerts.inform("Already Checking for Updates", message: "Porridge is looking for a newer version right now. Try again in a moment.", in: window)
            }
        }
    }

    /// File › New Note with no window open.
    @objc func newNote(_ sender: Any?) {
        showMainWindow(nil)
        MainWindowController.front.newNote(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) { return !AppUpdate.shared.checking }
        return true
    }
}
