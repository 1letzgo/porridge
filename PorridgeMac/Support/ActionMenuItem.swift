import AppKit

/// A menu item that runs a closure (its own target, so nothing else has to stay alive for it).
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", isDestructive: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if isDestructive {
            attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true, isDestructive: Bool = false, handler: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title, symbol: symbol, key: key, isDestructive: isDestructive, handler: handler)
        item.isEnabled = enabled
        addItem(item)
        return item
    }

    func addSeparator() {
        if let last = items.last, !last.isSeparatorItem { addItem(.separator()) }
    }
}

/// A button whose action is a closure.
final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        imagePosition = symbol == nil ? .noImage : (title.isEmpty ? .imageOnly : .imageLeading)
        bezelStyle = .push
        self.handler = handler
        target = self
        action = #selector(run)
        translatesAutoresizingMaskIntoConstraints = false
    }

    func setHandler(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc private func run() { handler?() }
}
