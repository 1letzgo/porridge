import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts dictated text into the field you are typing in: copies it and presses ⌘V for you.
@MainActor
enum TextInserter {
    /// Pressing keys in other apps needs the Accessibility permission.
    static var canPaste: Bool { AXIsProcessTrusted() }

    private static let promptedKey = "accessibilityPrompted"

    /// Asks macOS for the Accessibility permission. The system prompt is shown only once per app; after
    /// that the Accessibility list in System Settings is opened instead, where the switch is.
    static func requestAccess() {
        guard !canPaste else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: promptedKey) {
            openAccessibilitySettings()
        } else {
            defaults.set(true, forKey: promptedKey)
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Pastes `text` into the focused field of the frontmost app. Returns `false` when the app may not press keys;
    /// the text then stays on the clipboard so the user can paste it by hand.
    static func insert(_ text: String) async -> Bool {
        let board = NSPasteboard.general
        let saved = DictationSettings.keepClipboard ? snapshot(of: board) : nil

        board.clearContents()
        board.setString(text, forType: .string)
        let ours = board.changeCount
        guard canPaste else { return false }

        await waitForModifiersReleased()
        pressCommandV()

        // Give the target app time to read the clipboard before the old content comes back.
        try? await Task.sleep(for: .milliseconds(450))
        if let saved, board.changeCount == ours {
            restore(saved, to: board)
        }
        return true
    }

    /// The shortcut's own keys must be up, or the paste would arrive as ⌥⌘V.
    private static func waitForModifiersReleased() async {
        let relevant: NSEvent.ModifierFlags = [.option, .control, .shift]
        for _ in 0..<20 {
            if NSEvent.modifierFlags.intersection(relevant).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
    }

    private static func snapshot(of board: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]], to board: NSPasteboard) {
        board.clearContents()
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { board.writeObjects(items) }
    }
}
