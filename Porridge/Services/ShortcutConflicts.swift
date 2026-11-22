import Foundation

/// A keyboard shortcut as the Mac stores it: a virtual key code, Carbon modifier masks and the key's readable
/// name. Kept free of AppKit and Carbon so its rules can be tested anywhere.
struct ShortcutKey: Codable, Equatable, Hashable {
    var keyCode: Int
    /// Carbon masks: `cmdKey` 0x100, `shiftKey` 0x200, `optionKey` 0x800, `controlKey` 0x1000.
    var modifiers: Int
    /// "Space", "K", "F5", "Right ⌥".
    var label: String

    static let command = 0x100
    static let shift = 0x200
    static let option = 0x800
    static let control = 0x1000

    /// The right-hand modifier keys that may be a shortcut on their own (dictation).
    static let modifierOnlyKeyCodes: Set<Int> = [0x3D, 0x36, 0x3C, 0x3E]

    var isModifierOnly: Bool { modifiers == 0 && Self.modifierOnlyKeyCodes.contains(keyCode) }

    /// As shown to the user, e.g. "⌃⌥ Space".
    var display: String {
        var parts = ""
        if modifiers & Self.control != 0 { parts += "⌃" }
        if modifiers & Self.option != 0 { parts += "⌥" }
        if modifiers & Self.shift != 0 { parts += "⇧" }
        if modifiers & Self.command != 0 { parts += "⌘" }
        return parts.isEmpty ? label : "\(parts) \(label)"
    }

    /// The same keys: same modifiers and the same key (by its code, or by its name where only that is known).
    func collides(with other: ShortcutKey) -> Bool {
        guard modifiers == other.modifiers else { return false }
        if keyCode >= 0, other.keyCode >= 0 { return keyCode == other.keyCode }
        return label.caseInsensitiveCompare(other.label) == .orderedSame
    }
}

/// Finds what a new global shortcut would clash with: another of Porridge's global shortcuts, a shortcut of
/// macOS itself, or a command of Porridge's own menus (a global shortcut takes the keys away from the menu).
/// Whether another app holds it is only known when it is registered (`RegisterEventHotKey` fails).
enum ShortcutConflicts {
    struct Taken: Equatable {
        /// Who uses it: "Spotlight", "Porridge › New Note", "Dictation".
        var owner: String
        var key: ShortcutKey
    }

    /// Shortcuts of macOS that a global hot key would break.
    static let system: [Taken] = [
        Taken(owner: "Spotlight", key: ShortcutKey(keyCode: 0x31, modifiers: ShortcutKey.command, label: "Space")),
        Taken(owner: "Finder Search", key: ShortcutKey(keyCode: 0x31, modifiers: ShortcutKey.command | ShortcutKey.option, label: "Space")),
        Taken(owner: "Input Sources", key: ShortcutKey(keyCode: 0x31, modifiers: ShortcutKey.control, label: "Space")),
        Taken(owner: "Character Viewer", key: ShortcutKey(keyCode: 0x31, modifiers: ShortcutKey.control | ShortcutKey.command, label: "Space")),
        Taken(owner: "App Switcher", key: ShortcutKey(keyCode: 0x30, modifiers: ShortcutKey.command, label: "Tab")),
        Taken(owner: "Screenshot", key: ShortcutKey(keyCode: 0x14, modifiers: ShortcutKey.command | ShortcutKey.shift, label: "3")),
        Taken(owner: "Screenshot", key: ShortcutKey(keyCode: 0x15, modifiers: ShortcutKey.command | ShortcutKey.shift, label: "4")),
        Taken(owner: "Screenshot", key: ShortcutKey(keyCode: 0x17, modifiers: ShortcutKey.command | ShortcutKey.shift, label: "5")),
        Taken(owner: "Quit", key: ShortcutKey(keyCode: 0x0C, modifiers: ShortcutKey.command, label: "Q")),
        Taken(owner: "Close Window", key: ShortcutKey(keyCode: 0x0D, modifiers: ShortcutKey.command, label: "W")),
        Taken(owner: "Hide", key: ShortcutKey(keyCode: 0x04, modifiers: ShortcutKey.command, label: "H")),
        Taken(owner: "Minimize", key: ShortcutKey(keyCode: 0x2E, modifiers: ShortcutKey.command, label: "M")),
        Taken(owner: "Copy", key: ShortcutKey(keyCode: 0x08, modifiers: ShortcutKey.command, label: "C")),
        Taken(owner: "Paste", key: ShortcutKey(keyCode: 0x09, modifiers: ShortcutKey.command, label: "V")),
        Taken(owner: "Cut", key: ShortcutKey(keyCode: 0x07, modifiers: ShortcutKey.command, label: "X")),
        Taken(owner: "Undo", key: ShortcutKey(keyCode: 0x06, modifiers: ShortcutKey.command, label: "Z")),
        Taken(owner: "Select All", key: ShortcutKey(keyCode: 0x00, modifiers: ShortcutKey.command, label: "A")),
        Taken(owner: "Force Quit", key: ShortcutKey(keyCode: 0x35, modifiers: ShortcutKey.command | ShortcutKey.option, label: "Esc")),
        Taken(owner: "Lock Screen", key: ShortcutKey(keyCode: 0x0C, modifiers: ShortcutKey.command | ShortcutKey.control, label: "Q")),
    ]

    /// What the key clashes with, in this order: Porridge's other global shortcuts, macOS, Porridge's menus.
    /// `others` are the other global shortcuts (by their name); the one being set is not among them.
    static func conflicts(for key: ShortcutKey, others: [Taken], menu: [Taken] = [], system: [Taken] = ShortcutConflicts.system) -> [Taken] {
        (others + system + menu).filter { $0.key.collides(with: key) }
    }

    /// One line for the settings, or nil when the key is free.
    static func message(for key: ShortcutKey, others: [Taken], menu: [Taken] = [], system: [Taken] = ShortcutConflicts.system) -> String? {
        guard let first = conflicts(for: key, others: others, menu: menu, system: system).first else { return nil }
        if others.contains(first) {
            return String(localized: "\(key.display) is already the shortcut for \(first.owner).")
        }
        return String(localized: "\(key.display) is used by \(first.owner).")
    }

    /// Whether a key may be a global shortcut at all: it needs a modifier other than Shift (plain typing keys would
    /// stop working everywhere), except function keys and the right-hand modifier keys on their own.
    static func isAllowed(_ key: ShortcutKey, allowsModifierOnly: Bool) -> Bool {
        if key.isModifierOnly { return allowsModifierOnly }
        if functionKeyCodes.contains(key.keyCode) { return true }
        return key.modifiers & ~ShortcutKey.shift != 0
    }

    static let functionKeyCodes: Set<Int> = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
}
