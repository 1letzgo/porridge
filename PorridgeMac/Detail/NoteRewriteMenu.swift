import AppKit

extension NoteTextCoordinator {
    /// "Rewrite with AI…" on top of the text's context menu when something is selected.
    @objc(textView:menu:forEvent:atIndex:)
    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard view.isEditable, view.selectedRange().length > 0 else { return menu }
        let item = NSMenuItem(title: "Rewrite with AI…", action: #selector(NoteEditorView.rewriteWithAI(_:)), keyEquivalent: "j")
        item.keyEquivalentModifierMask = .command
        item.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }
}
