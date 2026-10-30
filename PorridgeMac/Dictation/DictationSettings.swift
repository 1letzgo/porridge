import AppKit
import Carbon.HIToolbox
import Foundation

/// How the dictation shortcut behaves.
enum DictationMode: String, CaseIterable, Identifiable {
    /// Speak while the shortcut is held down; releasing it inserts the text.
    case hold
    /// Press once to start, press again to stop.
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hold: "Hold to talk"
        case .toggle: "Press to start and stop"
        }
    }
}

/// Stored settings of the dictation shortcut.
enum DictationSettings {
    static let enabledKey = "dictationEnabled"
    static let keyCodeKey = "dictationKeyCode"
    static let modifiersKey = "dictationModifiers"
    static let keyLabelKey = "dictationKeyLabel"
    static let modeKey = "dictationMode"
    static let soundsKey = "dictationSounds"
    static let keepClipboardKey = "dictationKeepClipboard"
    /// Bumped when the default shortcut changes, so an untouched old default moves to the new one.
    static let shortcutVersionKey = "dictationShortcutVersion"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            enabledKey: true,
            keyCodeKey: kVK_RightOption,
            modifiersKey: 0,
            keyLabelKey: "Right ⌥",
            modeKey: DictationMode.hold.rawValue,
            soundsKey: true,
            keepClipboardKey: true,
        ])
        migrateShortcut()
    }

    /// Version 1 defaulted to ⌥ Space; who kept that gets the new default (the right Option key).
    private static func migrateShortcut() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: shortcutVersionKey) < 2 else { return }
        if defaults.integer(forKey: keyCodeKey) == kVK_Space, defaults.integer(forKey: modifiersKey) == optionKey {
            defaults.removeObject(forKey: keyCodeKey)
            defaults.removeObject(forKey: modifiersKey)
            defaults.removeObject(forKey: keyLabelKey)
        }
        defaults.set(2, forKey: shortcutVersionKey)
    }

    /// Modifier keys that can be the shortcut on their own. Only the right-hand keys: the left ones are
    /// part of everyday typing (⌥ for special characters, ⌘ for commands).
    static let modifierKeyLabels: [Int: String] = [
        kVK_RightOption: "Right ⌥",
        kVK_RightCommand: "Right ⌘",
        kVK_RightShift: "Right ⇧",
        kVK_RightControl: "Right ⌃",
    ]

    /// The shortcut is a single modifier key (watched with an event tap, not a Carbon hot key).
    static var isModifierOnly: Bool {
        modifiers == 0 && modifierKeyLabels[Int(keyCode)] != nil
    }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var keyCode: UInt32 { UInt32(UserDefaults.standard.integer(forKey: keyCodeKey)) }
    static var modifiers: UInt32 { UInt32(UserDefaults.standard.integer(forKey: modifiersKey)) }
    static var keyLabel: String { UserDefaults.standard.string(forKey: keyLabelKey) ?? "Right ⌥" }
    static var mode: DictationMode { DictationMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .hold }
    static var sounds: Bool { UserDefaults.standard.bool(forKey: soundsKey) }
    static var keepClipboard: Bool { UserDefaults.standard.bool(forKey: keepClipboardKey) }

    /// The shortcut as shown to the user, e.g. "⌥ Space".
    static func description(modifiers: UInt32, keyLabel: String) -> String {
        var parts = ""
        if modifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        return parts.isEmpty ? keyLabel : "\(parts) \(keyLabel)"
    }

    static var shortcutDescription: String {
        description(modifiers: modifiers, keyLabel: keyLabel)
    }

    /// Carbon modifier mask for an AppKit event.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// A readable name for the key of an event.
    static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    /// Function keys can be used alone; everything else needs a modifier so normal typing keeps working.
    static func isFunctionKey(_ keyCode: Int) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12].contains(keyCode)
    }
}
