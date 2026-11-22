import AppKit

/// The microphone in the menu bar: the dictation shortcut, start and stop, the way back to the app, and the minutes
/// until the next meeting (`MeetingAlerts.countdownText`) with Record and Join for it.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var observing: Observing?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.setAccessibilityLabel("Porridge Dictation")
        item.button?.imagePosition = .imageOnly
        observing = Observing { [weak self] in
            let recording = DictationController.shared.isRecording
            self?.item.button?.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: recording ? "Dictating" : "Dictation")
        }
        refreshCountdown()
    }

    /// The minutes until the next meeting next to the microphone, while one is less than half an hour away.
    func refreshCountdown() {
        let next = MeetingAlertController.shared.next
        let text = MeetingAlerts.isEnabled && MeetingAlerts.showsCountdown
            ? next.flatMap { MeetingAlerts.countdownText(until: $0.start, now: Date()) } : nil
        guard let button = item.button, button.title != (text ?? "") else { return }
        button.title = text ?? ""
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        button.imagePosition = text == nil ? .imageOnly : .imageLeading
        button.setAccessibilityLabel(text.map { _ in String(localized: "Porridge Dictation, next meeting \(next?.title ?? "")") } ?? "Porridge Dictation")
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
        if MeetingAlerts.isEnabled, let next = MeetingAlertController.shared.next {
            let time = next.start.formatted(.dateTime.hour().minute())
            menu.addItem(.sectionHeader(title: String(localized: "Next Meeting · \(time)")))
            let title = menu.addItem(withTitle: next.title, action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.add("Record Meeting", symbol: "mic.fill") { MeetingAlertController.record(next) }
            if next.videoURL != nil {
                menu.add("Join", symbol: "video.fill") { MeetingAlertController.join(next) }
            }
            menu.addItem(.separator())
        }
        menu.add("Open Porridge") { (NSApp.delegate as? AppDelegate)?.showMainWindow(nil) }
        menu.add("Settings…") { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
        menu.addItem(.separator())
        menu.add("Quit Porridge") { NSApp.terminate(nil) }
    }
}

