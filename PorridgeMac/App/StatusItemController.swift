import AppKit

/// The microphone in the menu bar: the dictation shortcut, start and stop, the way back to the app.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var observing: Observing?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.setAccessibilityLabel("Porridge Dictation")
        observing = Observing { [weak self] in
            let recording = DictationController.shared.isRecording
            self?.item.button?.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: recording ? "Dictating" : "Dictation")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let dictation = DictationController.shared
        if DictationSettings.enabled {
            if dictation.shortcutNeedsAccessibility {
                menu.add("Allow Accessibility for the Shortcut…") { TextInserter.requestAccess() }
            } else {
                let info = menu.addItem(
                    withTitle: dictation.shortcutUnavailable ? "Shortcut is used by another app" : "Dictate: \(DictationSettings.shortcutDescription)",
                    action: nil, keyEquivalent: ""
                )
                info.isEnabled = false
            }
        }
        menu.add(dictation.isRecording ? "Stop Dictation" : "Start Dictation") { dictation.toggleFromMenu() }
        menu.addItem(.separator())
        menu.add("Open Porridge") { (NSApp.delegate as? AppDelegate)?.showMainWindow(nil) }
        menu.add("Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
        if let release = AppUpdate.shared.available {
            menu.addItem(.separator())
            menu.add("Download Porridge \(release.version)…") { AppUpdate.shared.download() }
        }
        menu.addItem(.separator())
        menu.add("Quit Porridge") { NSApp.terminate(nil) }
    }
}

/// Tells about a newer version once it is found. "Later" keeps quiet for this run; "Skip" until the version after it.
@MainActor
final class UpdateNotice {
    private var observing: Observing?
    private var shownTag: String?

    init() {
        observing = Observing { [weak self] in
            guard let release = AppUpdate.shared.available else { return }
            Task { @MainActor in self?.show(release) }
        }
    }

    private func show(_ release: AppUpdate.Release) {
        guard release.tag != shownTag else { return }
        shownTag = release.tag
        let alert = NSAlert()
        alert.messageText = "Porridge \(release.version) Available"
        alert.informativeText = release.notes.isEmpty
            ? "You have \(AppUpdate.currentVersion). The download is a zip with the new app; replace the old one in Applications."
            : release.notes
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Skip This Version")
        let later = alert.addButton(withTitle: "Later")
        later.keyEquivalent = "\u{1b}"
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn: AppUpdate.shared.download()
            case .alertSecondButtonReturn: AppUpdate.shared.skip()
            default: break
            }
        }
        if let window = MainWindowController.frontIfAny?.window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}
