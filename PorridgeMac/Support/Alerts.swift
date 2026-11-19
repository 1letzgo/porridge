import AppKit

/// Alerts as sheets on a window: a question, or a question with a text field. Destructive buttons are red and
/// never the default; "Cancel" answers Escape.
@MainActor
enum Alerts {
    static func confirm(
        _ title: String, message: String, action: String, isDestructive: Bool = true, in window: NSWindow?, then: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = isDestructive ? .warning : .informational
        let button = alert.addButton(withTitle: action)
        button.hasDestructiveAction = isDestructive
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        if isDestructive {
            // Return does not delete.
            button.keyEquivalent = ""
        }
        run(alert, in: window) { response in
            if response == .alertFirstButtonReturn { then() }
        }
    }

    static func ask(
        _ title: String, message: String = "", placeholder: String = "", value: String = "", action: String,
        validate: ((String) -> Bool)? = nil, in window: NSWindow?, then: @escaping (String) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        let ok = alert.addButton(withTitle: action)
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        let validator = FieldValidator(field: field, button: ok, validate: validate ?? { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        alert.window.initialFirstResponder = field
        run(alert, in: window) { response in
            _ = validator
            if response == .alertFirstButtonReturn { then(field.stringValue) }
        }
    }

    static func inform(_ title: String, message: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        run(alert, in: window) { _ in }
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?, then: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: then)
        } else {
            then(alert.runModal())
        }
    }
}

/// Keeps the action button of an alert dimmed while the text does not fit.
private final class FieldValidator: NSObject, NSTextFieldDelegate {
    let field: NSTextField
    let button: NSButton
    let validate: (String) -> Bool

    init(field: NSTextField, button: NSButton, validate: @escaping (String) -> Bool) {
        self.field = field
        self.button = button
        self.validate = validate
        super.init()
        field.delegate = self
        button.isEnabled = validate(field.stringValue)
    }

    func controlTextDidChange(_ obj: Notification) {
        button.isEnabled = validate(field.stringValue)
    }
}
