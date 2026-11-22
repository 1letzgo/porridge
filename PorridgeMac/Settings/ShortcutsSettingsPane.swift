import AppKit

/// Settings › Shortcuts: the system-wide shortcuts (dictation, recording a meeting now, the command bar), each
/// changed by clicking it and pressing new keys. A shortcut that clashes with another one, with macOS or with a
/// menu command is refused and the reason shows below it; one another app holds is reported after registering.
final class ShortcutsSettingsPane: SettingsPane {
    private var recorders: [GlobalShortcutAction: ShortcutRecorderControl] = [:]
    private var notes: [GlobalShortcutAction: NSTextField] = [:]
    private var clearButtons: [GlobalShortcutAction: NSButton] = [:]

    override func build() {
        for (index, action) in GlobalShortcutAction.allCases.enumerated() {
            if index > 0 { form.separator() }
            let recorder = ShortcutRecorderControl(action: action) { [weak self] in self?.render() }
            recorders[action] = recorder
            let clear = NSButton.push(action == .dictation ? "Turn Off" : "Clear") { [weak self] in
                self?.recorders[action]?.stop()
                action.set(nil)
                self?.render()
            }
            clear.controlSize = .small
            clearButtons[action] = clear
            form.row(action.title, NSStackView.horizontal([recorder, clear], spacing: 8))
            notes[action] = form.note().label
        }
        form.separator()
        form.note("The command bar also opens with ⌘K while Porridge is in front. Dictation's mode and permissions are under Dictation.")
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopRecording()
    }

    func stopRecording() {
        recorders.values.forEach { $0.stop() }
    }

    override func render() {
        let shortcuts = GlobalShortcuts.shared
        for action in GlobalShortcutAction.allCases {
            recorders[action]?.refresh()
            clearButtons[action]?.isEnabled = action.key != nil
            guard let note = notes[action] else { continue }
            if let problem = recorders[action]?.problem {
                note.stringValue = problem
                note.textColor = .brandDangerText
            } else if action.key != nil, shortcuts.unavailable.contains(action) {
                note.stringValue = String(localized: "Another app already uses this shortcut. Choose a different one.")
                note.textColor = .brandDangerText
            } else {
                note.stringValue = switch action {
                case .dictation: String(localized: "Hold to talk, or press to start and stop. A right-hand modifier key works on its own.")
                case .recordMeeting: String(localized: "Starts recording a meeting at once, from any app. It lands in the Inbox.")
                case .commandBar: String(localized: "Opens the command bar from any app.")
                }
                note.textColor = .secondaryLabelColor
            }
        }
    }
}
