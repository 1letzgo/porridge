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
        menu.addItem(.separator())
        menu.add("Quit Porridge") { NSApp.terminate(nil) }
    }
}

