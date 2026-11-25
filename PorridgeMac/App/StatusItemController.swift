import AppKit

/// The microphone in the menu bar: the dictation shortcut, start and stop, the way back to the app, and the minutes
/// until the next meeting (`MeetingAlerts.countdownText`) with Record and Join for it. While a meeting is being
/// recorded it shows a red recording symbol, and its menu leads to the recording.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var observing: Observing?
    private var recordingObserver: NSObjectProtocol?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.setAccessibilityLabel("Porridge Dictation")
        item.button?.imagePosition = .imageOnly
        observing = Observing { [weak self] in
            _ = DictationController.shared.isRecording
            self?.refreshSymbol()
        }
        recordingObserver = NotificationCenter.default.addObserver(forName: MeetingRecorder.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSymbol() }
        }
        refreshCountdown()
    }

    /// A meeting being recorded (red), dictation (filled mic), or the plain mic.
    private func refreshSymbol() {
        guard let button = item.button else { return }
        if MeetingRecorder.isRecording {
            let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: String(localized: "Recording a Meeting"))?
                .withSymbolConfiguration(configuration)
        } else {
            let dictating = DictationController.shared.isRecording
            button.image = NSImage(systemSymbolName: dictating ? "mic.fill" : "mic", accessibilityDescription: dictating ? "Dictating" : "Dictation")
        }
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
        if MeetingRecorder.isRecording {
            let time = MeetingRecorder.elapsed.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) } ?? ""
            menu.addItem(.sectionHeader(title: String(localized: "Recording a Meeting · \(time)")))
            menu.add("Show Recording", symbol: "record.circle") {
                (NSApp.delegate as? AppDelegate)?.showMainWindow(nil)
                MeetingRecorder.reveal()
            }
            menu.addItem(.separator())
        }
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

