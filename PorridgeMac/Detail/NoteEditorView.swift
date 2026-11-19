import AppKit
import SwiftUI

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
    private var observing: Observing?

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
        coordinator = NoteTextCoordinator(text: Binding(get: get, set: set), controller: controller)

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
        for (symbol, label, action) in [
            ("checklist", "Checklist", #selector(makeChecklist(_:))),
            ("decrease.indent", "Outdent", #selector(outdentItems(_:))),
            ("increase.indent", "Indent", #selector(indentItems(_:))),
        ] as [(String, String, Selector)] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
            button.isBordered = false
            button.contentTintColor = .brandNavy
            button.toolTip = label
            formatBar.addArrangedSubview(button)
        }

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
        observing = Observing { [weak self] in
            guard let self else { return }
            self.placeholder.isHidden = !self.controller.isEmpty
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The note's text changed from outside (dictation, enhancing, the sync): shown unless typing is on its way.
    func reloadIfChanged() {
        let text = getText()
        if text != coordinator.lastWritten, !coordinator.hasPendingCommit { coordinator.load(text) }
    }

    /// What was typed last goes to the note now.
    func flush() {
        if coordinator.hasPendingCommit { coordinator.flush() }
    }

    func stop() {
        flush()
        coordinator.stopObserving()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    var textViewForFocus: NSTextView { textView }

    // MARK: Format commands (Format menu, format bar)

    private var canFormat: Bool { isEditable && window != nil }

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
        isEditable
    }
}
