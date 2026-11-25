import AppKit
import SwiftUI
import UniformTypeIdentifiers


/// The body of a note: one text view (TextKit 2) with headings, lists, checklists and bold/italic, stored as
/// Markdown. The editing rules are the shared ones of `NoteTextCoordinator`; this view gives them an AppKit home,
/// a format bar above the text and the Format menu's commands through the responder chain.
final class NoteEditorView: NSView {
    /// Reads and writes the note's Markdown.
    private let getText: () -> String
    private let setText: (String) -> Void
    let controller = NoteEditorController()
    private(set) var coordinator: NoteTextCoordinator!
    private let textView = NotePlatformTextView(usingTextLayoutManager: true)
    private let scroll = NoteScrollView()
    private let placeholder = NSTextField.label(color: .placeholderTextColor)
    private let formatBar = NSStackView()

    var placeholderText: String {
        get { placeholder.stringValue }
        set { placeholder.stringValue = newValue }
    }

    var isEditable = true {
        didSet {
            textView.isEditable = isEditable
            formatBar.isHidden = !isEditable
        }
    }

    /// Something below the text (a to-do's "Add Subtask"), inside the scrolling page.
    var footer: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let footer { footerStack.addArrangedSubview(footer) }
        }
    }

    private let footerStack = NSStackView()

    init(get: @escaping () -> String, set: @escaping (String) -> Void) {
        getText = get
        setText = set
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        coordinator = NoteTextCoordinator(text: NoteTextBinding(get: get, set: set), controller: controller)

        textView.coordinator = coordinator
        textView.delegate = coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.font = NoteMarkdown.baseFont(kind: .paragraph)
        textView.setAccessibilityLabel("Note")

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        coordinator.textView = textView
        coordinator.load(get())
        controller.bind(coordinator)
        coordinator.observeAppEnd()

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = NoteMarkdown.baseFont(kind: .paragraph)

        // The format bar: the paragraph kinds in a menu, then checklist, outdent, indent.
        formatBar.orientation = .horizontal
        formatBar.spacing = 14
        formatBar.translatesAutoresizingMaskIntoConstraints = false
        let format = NSPopUpButton(frame: .zero, pullsDown: true)
        format.isBordered = false
        format.addItem(withTitle: "")
        format.item(at: 0)?.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: "Format")
        let menu = format.menu!
        for (title, symbol, action) in [
            ("Title", "textformat.size.larger", #selector(makeHeading1(_:))),
            ("Heading", "textformat.size", #selector(makeHeading2(_:))),
            ("Subheading", "textformat.size.smaller", #selector(makeHeading3(_:))),
            ("Body", "text.alignleft", #selector(makeBody(_:))),
        ] as [(String, String, Selector)] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        for (title, symbol, action) in [
            ("Bold", "bold", #selector(toggleBold(_:))),
            ("Italic", "italic", #selector(toggleItalic(_:))),
        ] as [(String, String, Selector)] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        for (title, symbol, action) in [
            ("Bulleted List", "list.bullet", #selector(makeBulleted(_:))),
            ("Numbered List", "list.number", #selector(makeNumbered(_:))),
            ("Quote", "text.quote", #selector(makeQuote(_:))),
        ] as [(String, String, Selector)] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move Line Up", action: #selector(moveLineUp(_:)), keyEquivalent: "").image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        menu.addItem(withTitle: "Move Line Down", action: #selector(moveLineDown(_:)), keyEquivalent: "").image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        for item in menu.items { item.target = self }
        format.toolTip = "Format"
        format.setAccessibilityLabel("Format")
        formatBar.addArrangedSubview(format)
        // The places of the iPhone's editor bar: Format · Checklist · Insert · ✦ Rewrite · Outdent · Indent.
        func barButton(_ symbol: String, _ label: String, _ action: Selector, tint: NSColor = .brandNavy) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
            button.isBordered = false
            button.contentTintColor = tint
            button.toolTip = label
            return button
        }
        formatBar.addArrangedSubview(barButton("checklist", "Checklist", #selector(makeChecklist(_:))))
        formatBar.addArrangedSubview(barButton("plus.circle", "Insert", #selector(showInsertMenu(_:))))
        let rewrite = barButton("sparkles", String(localized: "Rewrite with AI (⌘J)"), #selector(rewriteFromBar(_:)), tint: .brandProjectText)
        rewrite.setAccessibilityLabel(String(localized: "Rewrite with AI"))
        rewrite.setAccessibilityIdentifier("EditorRewrite")
        formatBar.addArrangedSubview(rewrite)
        formatBar.addArrangedSubview(barButton("decrease.indent", "Outdent", #selector(outdentItems(_:))))
        formatBar.addArrangedSubview(barButton("increase.indent", "Indent", #selector(indentItems(_:))))

        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(formatBar)
        addSubview(scroll)
        addSubview(placeholder)
        addSubview(footerStack)
        NSLayoutConstraint.activate([
            formatBar.topAnchor.constraint(equalTo: topAnchor),
            formatBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: formatBar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerStack.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            footerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 7),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
        ])
        // The text view shows and hides the placeholder with every change of its text (`updateEmpty`).
        textView.placeholderView = placeholder
        tables = Observing { [weak self] in
            guard let self, let request = self.controller.tableRequest else { return }
            self.presentTableEditor(request)
        }
        rewrites = Observing { [weak self] in
            guard let self, let request = self.controller.rewriteRequest else { return }
            self.presentRewrite(request)
        }
        // After "[[": the entries to link, under the cursor.
        linkSuggestions = Observing { [weak self] in
            guard let self else { return }
            let results = self.controller.linkResults
            let highlight = self.controller.linkHighlight
            guard let search = self.controller.linkSearch, !results.isEmpty, let window = self.window else {
                self.suggestionPanel.hide()
                return
            }
            let caret = self.textView.firstRect(forCharacterRange: NSRange(location: search.range.location, length: 0), actualRange: nil)
            self.suggestionPanel.show(results, highlight: highlight, under: caret, in: window) { [weak self] candidate in
                self?.controller.chooseLink(candidate)
            }
        }
    }

    private var tables: Observing?
    private var linkSuggestions: Observing?
    private let suggestionPanel = EntryLinkSuggestionPanel()
    private weak var tableSheet: NSViewController?
    private var rewrites: Observing?
    private weak var rewriteSheet: NSViewController?

    // MARK: Rewrite with AI

    /// The selection rewritten with AI (⌘J, the text's context menu).
    @objc func rewriteWithAI(_ sender: Any?) { controller.beginRewrite() }

    /// ✦ in the format bar: the selection, or a word on what to select first.
    @objc private func rewriteFromBar(_ sender: Any?) {
        _ = performRewriteFromBar()
    }

    /// What ✦ of the format bar does, the same as the iPhone's ✦: the rewrite sheet for the selection; without one
    /// the notice "Select Text to Rewrite" as a sheet on the window (never an app-modal alert or a menu, so the window
    /// and the debug driver go on). Returns what it did, for the driver (`rewrite-bar`).
    @discardableResult
    func performRewriteFromBar() -> String {
        guard isEditable else {
            NSSound.beep()
            return "beep: not editable"
        }
        guard controller.canRewrite else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Select Text to Rewrite")
            alert.informativeText = String(localized: "Select the words or lines to rewrite, then click ✦ again or press ⌘J.")
            alert.addButton(withTitle: String(localized: "OK"))
            guard let window else { return "ask: no window" }
            alert.beginSheetModal(for: window)
            return "ask: \(alert.messageText) · \(alert.informativeText)"
        }
        controller.beginRewrite()
        return "rewrite sheet"
    }

    private func presentRewrite(_ request: RewriteRequest) {
        guard rewriteSheet == nil, let host = window?.contentViewController else { return }
        let close: () -> Void = { [weak self, weak host] in
            guard let self else { return }
            if let sheet = self.rewriteSheet { host?.dismiss(sheet) }
            self.rewriteSheet = nil
            self.controller.rewriteRequest = nil
            self.focus()
        }
        let view = AIRewriteView(request: request, apply: { [weak self] text, insertBelow in
            self?.controller.finishRewrite(request, text: text, insertBelow: insertBelow) ?? false
        }, close: close)
        let sheet = NSHostingController(rootView: view)
        sheet.title = "Rewrite with AI"
        rewriteSheet = sheet
        host.presentAsSheet(sheet)
    }

    // MARK: Insert menu

    /// Heading, checklist, table, image, divider, quote, code, at the cursor.
    @objc private func showInsertMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Insert")
        for item in NoteInsertItem.allCases where item != .photo {
            if item.isImage {
                menu.add("Image…", symbol: "photo", enabled: isEditable && controller.canInsertImages) { [weak self] in self?.chooseImages() }
            } else {
                menu.add(item.title, symbol: item.systemImage, enabled: isEditable) { [weak self] in self?.controller.insert(item) }
            }
        }
        menu.addItem(.separator())
        // "[[" at the cursor: the entries to link come up under it.
        menu.add(String(localized: "Link to Entry [["), symbol: "link", enabled: isEditable) { [weak self] in
            self?.focus()
            self?.controller.beginEntryLink()
        }
        if let templates = NoteTemplateActions.insertMenu(enabled: isEditable, insert: { [weak self] template in
            self?.controller.insertTemplate(template)
            self?.focus()
        }) {
            menu.addItem(.separator())
            menu.addItem(templates)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc func insertTable(_ sender: Any?) { controller.insert(.table) }
    @objc func insertDivider(_ sender: Any?) { controller.insert(.divider) }
    @objc func insertCodeBlock(_ sender: Any?) { controller.insert(.code) }

    /// Images from disk, put on the note and shown at the cursor.
    @objc func chooseImages() {
        guard controller.canInsertImages else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        let insert: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls { self.controller.insertImage(fileAt: url) }
            self.focus()
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: insert) } else { insert(panel.runModal()) }
    }

    /// The table editor as a sheet of the window; the editor puts its result into the note.
    private func presentTableEditor(_ request: TableEditRequest) {
        guard tableSheet == nil, let host = window?.contentViewController else { return }
        // The sheet is reached weakly: the closure lives in the sheet's own view, and a strong hold would keep it
        // (and `tableSheet`) alive for good, so the table editor would open only once.
        let view = TableEditorView(table: request.table, isNew: request.isNew) { [weak self, weak host] table, delete in
            guard let self else { return }
            if let sheet = self.tableSheet { host?.dismiss(sheet) }
            self.tableSheet = nil
            self.controller.finishTable(request, table: table, delete: delete)
            self.focus()
        }
        let controller = NSHostingController(rootView: view)
        controller.title = request.isNew ? "New Table" : "Edit Table"
        tableSheet = controller
        host.presentAsSheet(controller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The note's text changed from outside (dictation, enhancing, the sync): shown unless typing is on its way.
    func reloadIfChanged() {
        let text = getText()
        guard text != coordinator.lastWritten else { return }
        if coordinator.hasPendingCommit {
            mergeTicks(from: text)
        } else {
            coordinator.load(text)
        }
    }

    /// Typing on its way is newer than a text from outside and wins. Boxes ticked or unticked outside in the
    /// meantime (the to-do's box in the list or here, "Mark as Done" in a menu) are kept though: they go into the
    /// editor, and the pending commit writes them back with the typing. Nothing else from outside is taken over.
    /// After the load `lastWritten` is the merged text, so the next reload finds nothing more to merge.
    private func mergeTicks(from outside: String) {
        // A word being composed (marked text) would be torn apart by a reload: typing wins as before.
        guard !textView.hasMarkedText(), let storage = textView.noteStorage else { return }
        let typed = NoteMarkdown.markdown(from: storage)
        let merged = Todos.mergeTicks(base: coordinator.lastWritten, winner: typed, loser: outside)
        guard merged != typed else { return }
        coordinator.load(merged)
        // Written back outside the render that called this; the note's change renders again and finds it settled.
        Task { @MainActor [weak self] in self?.flush() }
    }

    /// What was typed last goes to the note now.
    func flush() {
        if coordinator.hasPendingCommit { coordinator.flush() }
    }

    func stop() {
        flush()
        coordinator.stopObserving()
        controller.updateLinkSearch(nil)
        suggestionPanel.hide()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    // MARK: Format commands (Format menu, format bar)

    @objc func toggleBold(_ sender: Any?) { controller.perform(.toggleInline("**")) }
    @objc func toggleItalic(_ sender: Any?) { controller.perform(.toggleInline("*")) }
    @objc func makeHeading1(_ sender: Any?) { controller.perform(.setKind(.heading(1))) }
    @objc func makeHeading2(_ sender: Any?) { controller.perform(.setKind(.heading(2))) }
    @objc func makeHeading3(_ sender: Any?) { controller.perform(.setKind(.heading(3))) }
    @objc func makeBody(_ sender: Any?) { controller.perform(.setKind(.paragraph)) }
    @objc func makeBulleted(_ sender: Any?) { controller.perform(.setKind(.bullet)) }
    @objc func makeNumbered(_ sender: Any?) { controller.perform(.setKind(.numbered)) }
    @objc func makeChecklist(_ sender: Any?) { controller.perform(.setKind(.checklist(checked: false))) }
    @objc func makeQuote(_ sender: Any?) { controller.perform(.setKind(.quote)) }
    @objc func indentItems(_ sender: Any?) { controller.perform(.shift(deeper: true)) }
    @objc func outdentItems(_ sender: Any?) { controller.perform(.shift(deeper: false)) }
    @objc func moveLineUp(_ sender: Any?) { EditorCommands.moveLine(up: true, controller) }
    @objc func moveLineDown(_ sender: Any?) { EditorCommands.moveLine(up: false, controller) }

    func appendChecklistItem() {
        EditorCommands.appendChecklistItem(controller)
        focus()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(rewriteWithAI(_:)) { return controller.canRewrite }
        return isEditable
    }
}
