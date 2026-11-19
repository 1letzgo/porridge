import AppKit
import AVFoundation
import Carbon.HIToolbox

/// Dictation anywhere on the Mac: the shortcut, how it behaves, and the two permissions it needs.
final class DictationSettingsPane: SettingsPane {
    private let controller = DictationController.shared

    private lazy var enabled = SettingsCheckbox("Dictate with a shortcut") { [weak self] on in
        UserDefaults.standard.set(on, forKey: DictationSettings.enabledKey)
        DictationController.shared.reloadShortcut()
        self?.render()
    }
    private lazy var recorder = ShortcutRecorderControl { [weak self] in self?.render() }
    private var hint = NSTextField()
    private lazy var modePopUp = SettingsPopUp { index in
        let modes = DictationMode.allCases
        guard index >= 0, index < modes.count else { return }
        UserDefaults.standard.set(modes[index].rawValue, forKey: DictationSettings.modeKey)
        DictationController.shared.reloadShortcut()
    }
    private lazy var sounds = SettingsCheckbox("Play sounds") {
        UserDefaults.standard.set($0, forKey: DictationSettings.soundsKey)
    }
    private lazy var keepClipboard = SettingsCheckbox("Restore the clipboard after pasting") {
        UserDefaults.standard.set($0, forKey: DictationSettings.keepClipboardKey)
    }
    private let microphone = PermissionControl()
    private let accessibility = PermissionControl()
    private var accessibilityHintRow: NSGridRow?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    override func build() {
        form.row("", enabled)
        form.row("Shortcut", recorder)
        hint = form.note().label
        form.row("Mode", modePopUp)
        form.row("", sounds)
        form.row("", keepClipboard)
        form.separator()
        form.row("Microphone", microphone)
        form.row("Accessibility", accessibility)
        let note = form.note(
            "Switch Porridge on under Accessibility in System Settings. If it is already on there, switch it off and on again — macOS forgets the permission when the app was replaced."
        )
        accessibilityHintRow = note.row

        microphone.onAllow = { [weak self] in
            if AVAudioApplication.shared.recordPermission == .undetermined {
                Task {
                    _ = await AVAudioApplication.requestRecordPermission()
                    self?.permissionsChanged()
                }
            } else {
                Self.openPrivacy("Privacy_Microphone")
            }
        }
        accessibility.onAllow = { TextInserter.requestAccess() }
        accessibility.setAccessibilityHelp("Needed to paste the dictated text")

        // Back from System Settings: a permission may have been given in the meantime.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissionsChanged() }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The permissions are given outside the app: re-read them every second until they are there.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !TextInserter.canPaste || AVAudioApplication.shared.recordPermission != .granted else { return }
                self?.permissionsChanged()
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
        timer = nil
        stopRecording()
    }

    func stopRecording() {
        recorder.stop()
    }

    private func permissionsChanged() {
        if DictationController.shared.shortcutNeedsAccessibility, TextInserter.canPaste {
            DictationController.shared.reloadShortcut()
        }
        render()
    }

    override func render() {
        let defaults = UserDefaults.standard
        let isEnabled = defaults.bool(forKey: DictationSettings.enabledKey)
        enabled.isOn = isEnabled
        recorder.refresh()

        if controller.shortcutUnavailable, isEnabled {
            hint.stringValue = "Another app already uses this shortcut. Choose a different one."
            hint.textColor = .brandDangerText
        } else if controller.shortcutNeedsAccessibility, isEnabled {
            hint.stringValue = "A modifier key on its own needs the Accessibility permission (below)."
            hint.textColor = .secondaryLabelColor
        } else {
            hint.stringValue = "Click, then press a key combination or a single right-hand modifier key."
            hint.textColor = .secondaryLabelColor
        }

        let mode = DictationSettings.mode
        modePopUp.set(DictationMode.allCases.map(\.label), selected: DictationMode.allCases.firstIndex(of: mode))
        sounds.isOn = defaults.bool(forKey: DictationSettings.soundsKey)
        keepClipboard.isOn = defaults.bool(forKey: DictationSettings.keepClipboardKey)

        microphone.show(granted: AVAudioApplication.shared.recordPermission == .granted, name: "Microphone")
        let canPaste = TextInserter.canPaste
        accessibility.show(granted: canPaste, name: "Accessibility (to paste)")
        if accessibilityHintRow?.isHidden != canPaste {
            accessibilityHintRow?.isHidden = canPaste
            contentChanged()
        }
    }

    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// A permission: a checkmark when it is given, otherwise an "Allow…" button.
private final class PermissionControl: NSStackView {
    var onAllow: (() -> Void)?
    private let check = NSImageView()
    private let status = NSTextField.label(color: .secondaryLabelColor)
    private lazy var allow = NSButton.push("Allow…") { [weak self] in self?.onAllow?() }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        check.image = .symbol("checkmark.circle.fill", size: 15, label: "Allowed")
        check.contentTintColor = .brandSkyText
        status.stringValue = "Allowed"
        addArrangedSubview(check)
        addArrangedSubview(status)
        addArrangedSubview(allow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(granted: Bool, name: String) {
        check.isHidden = !granted
        status.isHidden = !granted
        allow.isHidden = granted
        allow.setAccessibilityLabel("Allow \(name)")
    }
}

/// Click, then press the new shortcut: a key with modifiers, or one of the right-hand modifier keys on its own.
/// Escape cancels.
final class ShortcutRecorderControl: NSButton {
    private var recording = false
    private var monitor: Any?
    private var flagsMonitor: Any?
    private var onChange: (() -> Void)?

    convenience init(onChange: @escaping () -> Void) {
        self.init(frame: .zero)
        self.onChange = onChange
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        refresh()
    }

    func refresh() {
        title = recording ? "Press Shortcut…" : DictationSettings.shortcutDescription
        setAccessibilityLabel(recording ? "Press the new shortcut" : "Shortcut: \(DictationSettings.shortcutDescription)")
        setAccessibilityHelp("Click, then press a key combination")
    }

    @objc private func clicked() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        refresh()
        // The current shortcut is pressed here to choose it again, not to dictate.
        DictationController.shared.suspendShortcut()
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = Int(event.keyCode)
            guard let label = DictationSettings.modifierKeyLabels[keyCode],
                  let mask = ModifierKeyMonitor.mask(for: keyCode),
                  CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).contains(mask)
            else { return event }
            self?.save(keyCode: keyCode, modifiers: 0, label: label)
            return nil
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if Int(event.keyCode) == kVK_Escape {
                self?.stop()
                return nil
            }
            let modifiers = DictationSettings.carbonModifiers(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            // Plain typing keys would stop working everywhere: ask for a modifier (function keys may stand alone).
            // Shift alone is no modifier for this: ⇧A is the capital letter.
            guard modifiers & ~UInt32(shiftKey) != 0 || DictationSettings.isFunctionKey(Int(event.keyCode)) else {
                NSSound.beep()
                return nil
            }
            self?.save(keyCode: Int(event.keyCode), modifiers: Int(modifiers), label: DictationSettings.label(for: event))
            return nil
        }
    }

    private func save(keyCode: Int, modifiers: Int, label: String) {
        let defaults = UserDefaults.standard
        defaults.set(keyCode, forKey: DictationSettings.keyCodeKey)
        defaults.set(modifiers, forKey: DictationSettings.modifiersKey)
        defaults.set(label, forKey: DictationSettings.keyLabelKey)
        stop()
    }

    func stop() {
        // Back on, with the old shortcut or the new one.
        let was = recording
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        monitor = nil
        flagsMonitor = nil
        if was {
            DictationController.shared.reloadShortcut()
            refresh()
            onChange?()
        }
    }
}
