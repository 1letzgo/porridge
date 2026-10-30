import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the format bar and the note screen ask the editor to do.
enum NoteEditorCommand {
    /// Makes the paragraphs of the selection that kind; the same kind again turns them back into plain text.
    case setKind(NoteBlock.Kind)
    /// Indents (`deeper`) or outdents list items.
    case shift(deeper: Bool)
    /// Bold (`**`) or italic (`*`) around the selection or the word at the cursor; again removes it.
    case toggleInline(String)
}

/// The note as one native text view (TextKit 2), the same editing logic on both platforms:
/// Return and Backspace know about lists and checklists, typing "- " or "# " at the start of a line
/// turns it into that kind, Tab indents a list item. The view hands its text back as Markdown.
@MainActor
final class NoteTextCoordinator: NSObject {
    var text: Binding<String>
    let controller: NoteEditorController
    weak var textView: NotePlatformTextView?
    /// The Markdown this editor wrote last; a different `text` came from outside (dictation, sync).
    var lastWritten: String
    private var pendingCommit: Task<Void, Never>?
    /// The editor is changing the text itself (markers, renumbering): no rules, no commit.
    private var isAdjusting = false

    init(text: Binding<String>, controller: NoteEditorController) {
        self.text = text
        self.controller = controller
        self.lastWritten = text.wrappedValue
    }

    // MARK: Loading and storing

    func load(_ markdown: String) {
        guard let textView, let storage = textView.noteStorage else { return }
        lastWritten = markdown
        let selected = textView.selectedRange
        isAdjusting = true
        storage.setAttributedString(NoteMarkdown.attributed(from: markdown))
        isAdjusting = false
        textView.selectedRange = NSRange(location: min(selected.location, storage.length), length: 0)
        resetTypingAttributes()
    }

    /// Hands the text to the note shortly after the last change. Writing on every key press makes the
    /// notes list update while typing, which costs letters.
    func commit() {
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { self?.flush() }
        }
    }

    func flush() {
        pendingCommit?.cancel()
        pendingCommit = nil
        guard let storage = textView?.noteStorage else { return }
        let markdown = NoteMarkdown.markdown(from: storage)
        lastWritten = markdown
        if text.wrappedValue != markdown { text.wrappedValue = markdown }
    }

    /// Cursor as a character offset in the Markdown: the Markdown of everything before it; the end of the
    /// text when nothing is being edited.
    func cursorOffset() -> Int {
        guard let textView, let storage = textView.noteStorage else { return text.wrappedValue.count }
        let location = controller.isEditing ? min(textView.selectedRange.location, storage.length) : storage.length
        if location == storage.length { return NoteMarkdown.markdown(from: storage).count }
        return NoteMarkdown.markdown(from: storage.attributedSubstring(from: NSRange(location: 0, length: location))).count
    }

    func blur() {
        flush()
        textView?.endEditing()
    }

    // MARK: Paragraphs

    private var storage: NSTextStorage? { textView?.noteStorage }
    private var string: NSString { (storage?.string ?? "") as NSString }

    /// The paragraph (with its newline) around `location`.
    func paragraphRange(at location: Int) -> NSRange {
        string.paragraphRange(for: NSRange(location: max(0, min(location, string.length)), length: 0))
    }

    /// The paragraph without its newline.
    func contentRange(of paragraph: NSRange) -> NSRange {
        var range = paragraph
        if range.length > 0, string.character(at: range.location + range.length - 1) == 0x0A { range.length -= 1 }
        return range
    }

    func kind(of paragraph: NSRange) -> (NoteBlock.Kind, Int) {
        guard let storage else { return (.paragraph, 0) }
        if paragraph.length == 0 {
            // An empty last paragraph has no characters: its kind is what would be typed.
            return NoteMarkdown.kind(of: textView?.typingAttributes ?? [:])
        }
        return NoteMarkdown.paragraphKind(in: storage, at: paragraph.location)
    }

    private func markerLength(of paragraph: NSRange) -> Int {
        guard let storage else { return 0 }
        return NoteMarkdown.markerLength(in: storage, paragraph: paragraph)
    }

    /// Where the text of a paragraph starts (after the marker or the checkbox).
    func textStart(of paragraph: NSRange) -> Int {
        paragraph.location + markerLength(of: paragraph)
    }

    /// The paragraphs touched by the selection.
    private func selectedParagraphs() -> [NSRange] {
        guard let textView else { return [] }
        let selection = textView.selectedRange
        var ranges: [NSRange] = []
        var location = selection.location
        repeat {
            let paragraph = paragraphRange(at: location)
            ranges.append(paragraph)
            location = paragraph.location + max(paragraph.length, 1)
        } while location < selection.location + selection.length
        return ranges
    }

    /// Gives a paragraph a kind and indent: marker, paragraph style, fonts. Returns the paragraph's new range.
    @discardableResult
    func restyle(_ paragraph: NSRange, kind: NoteBlock.Kind, indent: Int) -> NSRange {
        guard let storage, let textView else { return paragraph }
        var range = paragraph
        let selection = textView.selectedRange
        isAdjusting = true
        storage.beginEditing()
        // The marker of the old kind goes, the one of the new kind comes.
        let oldMarker = markerLength(of: range)
        let marker = NoteMarkdown.marker(kind: kind, number: 1)
        storage.replaceCharacters(in: NSRange(location: range.location, length: oldMarker), with: marker)
        range.length += marker.length - oldMarker
        for key in NoteMarkdown.blockKeys { storage.removeAttribute(key, range: range) }
        storage.addAttributes(NoteMarkdown.paragraphAttributes(kind: kind, indent: indent), range: range)
        // Fonts follow the kind; bold and italic of the runs stay.
        let text = NSRange(location: range.location + marker.length, length: range.length - marker.length)
        storage.enumerateAttribute(.font, in: text, options: []) { value, runRange, _ in
            let font = value as? PlatformFont
            let bold = font.map(NoteMarkdown.isBold) ?? false
            let italic = font.map(NoteMarkdown.isItalic) ?? false
            storage.addAttribute(.font, value: NoteMarkdown.font(kind: kind, bold: bold, italic: italic), range: runRange)
        }
        let content = contentRange(of: range)
        NoteMarkdown.colorTags(in: storage, range: NSRange(location: text.location, length: max(0, content.location + content.length - text.location)), kind: kind)
        storage.endEditing()
        isAdjusting = false
        // The cursor keeps its place in the text; never inside the marker.
        if selection.location >= paragraph.location {
            let shifted = selection.location + (selection.location >= paragraph.location + oldMarker ? marker.length - oldMarker : 0)
            textView.selectedRange = NSRange(location: max(range.location + marker.length, min(shifted, storage.length)), length: selection.length)
        }
        if kind == .numbered { renumber() }
        if range.length == 0 {
            // No characters to carry the kind: what is typed next gets it.
            var typing = NoteMarkdown.inlineAttributes(kind: kind, bold: false, italic: false)
            typing.merge(NoteMarkdown.paragraphAttributes(kind: kind, indent: indent)) { $1 }
            textView.typingAttributes = typing
        }
        resetTypingAttributes()
        textView.didRestyle()
        return range
    }

    /// Numbered items count on from the item before; the markers in the text are made to match.
    private func renumber() {
        guard let storage, let textView else { return }
        var counters: [Int: Int] = [:]
        var location = 0
        var selection = textView.selectedRange
        isAdjusting = true
        while location < storage.length {
            let paragraph = paragraphRange(at: location)
            let (kind, indent) = kind(of: paragraph)
            let number = NoteMarkdown.next(counters: &counters, kind: kind, indent: indent)
            var length = paragraph.length
            if kind == .numbered {
                let old = markerLength(of: paragraph)
                let marker = NoteMarkdown.marker(kind: .numbered, number: number)
                if (storage.string as NSString).substring(with: NSRange(location: paragraph.location, length: old)) != marker.string {
                    storage.replaceCharacters(in: NSRange(location: paragraph.location, length: old), with: marker)
                    storage.addAttributes(NoteMarkdown.paragraphAttributes(kind: .numbered, indent: indent), range: NSRange(location: paragraph.location, length: marker.length))
                    let delta = marker.length - old
                    length += delta
                    if selection.location >= paragraph.location + old { selection.location += delta }
                }
            }
            location = paragraph.location + max(length, 1)
        }
        isAdjusting = false
        if selection != textView.selectedRange { textView.selectedRange = selection }
    }

    /// Typing attributes from the paragraph at the cursor, never the checkbox's own (attachment, kern).
    /// An empty paragraph has no characters to read: it keeps the attributes it was given.
    func resetTypingAttributes() {
        guard let textView, let storage else { return }
        let paragraph = paragraphRange(at: textView.selectedRange.location)
        let content = contentRange(of: paragraph)
        let start = textStart(of: paragraph)
        var typing: [NSAttributedString.Key: Any]
        if content.length > markerLength(of: paragraph) {
            // The character before the cursor carries the run (bold stays bold); at the start of the text, the first one.
            let at = min(max(start, textView.selectedRange.location), content.location + content.length)
            let index = max(start, min(at - 1, storage.length - 1))
            typing = storage.attributes(at: min(index, storage.length - 1), effectiveRange: nil)
            typing[.foregroundColor] = NoteMarkdown.textColor(kind: kind(of: paragraph).0)
        } else if paragraph.length > 0 {
            // Only a marker (or a newline): the kind of the paragraph, the font of the body.
            let (kind, indent) = kind(of: paragraph)
            typing = NoteMarkdown.inlineAttributes(kind: kind, bold: false, italic: false)
            typing.merge(NoteMarkdown.paragraphAttributes(kind: kind, indent: indent)) { $1 }
        } else {
            typing = textView.typingAttributes
            if typing[.paragraphStyle] == nil {
                typing = NoteMarkdown.inlineAttributes(kind: .paragraph, bold: false, italic: false)
                typing[.paragraphStyle] = NoteMarkdown.paragraphStyle(kind: .paragraph, indent: 0)
            }
        }
        typing[.attachment] = nil
        typing[.noteChecked] = nil
        typing[.kern] = nil
        textView.typingAttributes = typing
    }

    // MARK: Editing rules

    /// Return, Backspace and Tab with their meaning in lists. `true` lets the text view do the usual thing.
    func shouldChange(in range: NSRange, replacement: String) -> Bool {
        guard let storage, let textView, !isAdjusting else { return true }
        let paragraph = paragraphRange(at: range.location)
        let (kind, indent) = kind(of: paragraph)
        let content = contentRange(of: paragraph)
        let start = textStart(of: paragraph)
        let textLength = max(0, content.location + content.length - start)

        if replacement == "\n", range.length == 0 {
            switch kind {
            case .bullet, .numbered, .checklist:
                if textLength == 0 {
                    // Return on an empty item ends the list, one level at a time.
                    if indent > 0 {
                        restyle(paragraph, kind: kind, indent: indent - 1)
                    } else {
                        restyle(paragraph, kind: .paragraph, indent: 0)
                    }
                    commit()
                    return false
                }
                // The next line is an item of the same kind (a checklist item starts unticked).
                var next = kind
                if case .checklist = kind { next = .checklist(checked: false) }
                let newline = NSMutableAttributedString(string: "\n", attributes: textView.typingAttributes)
                newline.append(NoteMarkdown.marker(kind: next, number: 1))
                newline.addAttributes(NoteMarkdown.paragraphAttributes(kind: next, indent: indent), range: NSRange(location: 0, length: newline.length))
                isAdjusting = true
                storage.replaceCharacters(in: range, with: newline)
                isAdjusting = false
                textView.selectedRange = NSRange(location: range.location + newline.length, length: 0)
                if kind == .numbered { renumber() }
                resetTypingAttributes()
                textView.didRestyle()
                commit()
                return false
            case .heading, .quote:
                // The line after a heading or quote is plain text.
                isAdjusting = true
                storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: textView.typingAttributes))
                isAdjusting = false
                restyle(paragraphRange(at: range.location + 1), kind: .paragraph, indent: 0)
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                resetTypingAttributes()
                commit()
                return false
            case .paragraph:
                return true
            }
        }

        if replacement.isEmpty, range.length == 1 {
            // Backspace into the marker: the mark goes first; only then does the line join the one above.
            if kind.isList, range.location == start - 1 {
                if indent > 0 {
                    restyle(paragraph, kind: kind, indent: indent - 1)
                } else {
                    restyle(paragraph, kind: .paragraph, indent: 0)
                }
                commit()
                return false
            }
            if (kind == .quote || kind.headingLevel > 0), range.location == paragraph.location - 1 {
                restyle(paragraph, kind: .paragraph, indent: 0)
                textView.selectedRange = NSRange(location: paragraph.location, length: 0)
                commit()
                return false
            }
        }

        if replacement == "\t" {
            if kind.isList { shift(deeper: true) }
            return false
        }

        // Nothing is typed into a marker.
        if range.location < start, range.length == 0, !replacement.isEmpty {
            isAdjusting = true
            storage.replaceCharacters(in: NSRange(location: start, length: 0), with: NSAttributedString(string: replacement, attributes: textView.typingAttributes))
            isAdjusting = false
            textView.selectedRange = NSRange(location: start + (replacement as NSString).length, length: 0)
            didChange()
            return false
        }

        return true
    }

    /// After a change: typing "- ", "1. ", "[] ", "# " or "> " at the start of a line makes it that kind.
    func didChange() {
        guard let textView, !isAdjusting else { return }
        var paragraph = paragraphRange(at: textView.selectedRange.location)
        var (kind, _) = kind(of: paragraph)
        if kind.isList, markerLength(of: paragraph) == 0 {
            // The marker was deleted (a selection across it): the line is plain again.
            paragraph = restyle(paragraph, kind: .paragraph, indent: 0)
            kind = .paragraph
        }
        if kind == .paragraph, paragraph.length > 0 {
            let content = contentRange(of: paragraph)
            let line = string.substring(with: content)
            let typed = textView.selectedRange.location - content.location
            if typed == (line as NSString).length, let converted = Self.shortcut(for: line) {
                isAdjusting = true
                storage?.deleteCharacters(in: content)
                isAdjusting = false
                textView.selectedRange = NSRange(location: content.location, length: 0)
                restyle(paragraphRange(at: content.location), kind: converted, indent: 0)
                commit()
                return
            }
        }
        renumberIfNeeded()
        recolor(paragraphRange(at: textView.selectedRange.location))
        commit()
    }

    private func renumberIfNeeded() {
        guard let storage else { return }
        var found = false
        storage.enumerateAttribute(.noteBlock, in: NSRange(location: 0, length: storage.length), options: []) { value, _, stop in
            if value as? String == "numbered" { found = true; stop.pointee = true }
        }
        if found { renumber() }
    }

    private func recolor(_ paragraph: NSRange) {
        guard let storage else { return }
        let content = contentRange(of: paragraph)
        let start = textStart(of: paragraph)
        let range = NSRange(location: start, length: max(0, content.location + content.length - start))
        guard range.length > 0 else { return }
        isAdjusting = true
        NoteMarkdown.colorTags(in: storage, range: range, kind: kind(of: paragraph).0)
        isAdjusting = false
        if let textView, textView.typingAttributes[.foregroundColor] as? PlatformColor == NoteMarkdown.tagColor {
            textView.typingAttributes[.foregroundColor] = NoteMarkdown.textColor(kind: kind(of: paragraph).0)
        }
    }

    static func shortcut(for value: String) -> NoteBlock.Kind? {
        switch value {
        case "- ", "* ", "• ": return .bullet
        case "[] ", "- [ ] ": return .checklist(checked: false)
        case "# ": return .heading(1)
        case "## ": return .heading(2)
        case "### ": return .heading(3)
        case "> ": return .quote
        default:
            if value.count >= 3, value.hasSuffix(". "), value.dropLast(2).allSatisfy(\.isNumber) { return .numbered }
            return nil
        }
    }

    /// The cursor never sits inside a marker or in front of a checkbox.
    func selectionChanged() {
        guard let textView, !isAdjusting else { return }
        let selection = textView.selectedRange
        if selection.length == 0 {
            let paragraph = paragraphRange(at: selection.location)
            let start = textStart(of: paragraph)
            if selection.location < start {
                textView.selectedRange = NSRange(location: start, length: 0)
                return
            }
        }
        resetTypingAttributes()
    }

    /// A click on a checkbox ticks it.
    func toggleCheckbox(near index: Int) -> Bool {
        guard let storage else { return false }
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard storage.attribute(.attachment, at: candidate, effectiveRange: nil) != nil else { continue }
            let checked = storage.attribute(.noteChecked, at: candidate, effectiveRange: nil) as? Bool ?? false
            let paragraph = paragraphRange(at: candidate)
            let (_, indent) = kind(of: paragraph)
            restyle(paragraph, kind: .checklist(checked: !checked), indent: indent)
            commit()
            return true
        }
        return false
    }

    // MARK: Commands

    func perform(_ command: NoteEditorCommand) {
        guard let textView else { return }
        switch command {
        case .setKind(let kind):
            for paragraph in selectedParagraphs().reversed() {
                let (current, indent) = self.kind(of: paragraph)
                var same = current == kind
                if case .checklist = kind, case .checklist = current { same = true }
                let next: NoteBlock.Kind = same ? .paragraph : kind
                restyle(paragraph, kind: next, indent: next.isList ? indent : 0)
            }
            renumberIfNeeded()
            selectionChanged()
        case .shift(let deeper):
            shift(deeper: deeper)
        case .toggleInline(let mark):
            toggleInline(mark)
        }
        textView.didRestyle()
        commit()
    }

    private func shift(deeper: Bool) {
        for paragraph in selectedParagraphs().reversed() {
            let (kind, indent) = self.kind(of: paragraph)
            guard kind.isList else { continue }
            let next = min(NoteBlock.maxIndent, max(0, indent + (deeper ? 1 : -1)))
            if next != indent { restyle(paragraph, kind: kind, indent: next) }
        }
        renumberIfNeeded()
        commit()
    }

    private func toggleInline(_ mark: String) {
        guard let storage, let textView else { return }
        var range = textView.selectedRange
        if range.length == 0 {
            // The word at the cursor.
            let start = textStart(of: paragraphRange(at: range.location))
            var lower = range.location, upper = range.location
            func isWord(_ at: Int) -> Bool {
                guard at >= start, at < storage.length else { return false }
                let scalar = Unicode.Scalar(string.character(at: at)).map(Character.init)
                return scalar.map { $0.isLetter || $0.isNumber } ?? false
            }
            while isWord(lower - 1) { lower -= 1 }
            while isWord(upper) { upper += 1 }
            range = NSRange(location: lower, length: upper - lower)
        }
        let bold = mark == "**"
        if range.length == 0 {
            // Nothing to wrap: what is typed next gets the trait.
            var typing = textView.typingAttributes
            let font = typing[.font] as? PlatformFont ?? NoteMarkdown.baseFont(kind: .paragraph)
            let on = bold ? NoteMarkdown.isBold(font) : NoteMarkdown.isItalic(font)
            typing[.font] = NoteMarkdown.withTraits(font, bold: bold ? !on : NoteMarkdown.isBold(font), italic: bold ? NoteMarkdown.isItalic(font) : !on)
            textView.typingAttributes = typing
            return
        }
        // On when every run has the trait; then it is taken away, otherwise given to all.
        var allOn = true
        storage.enumerateAttribute(.font, in: range, options: []) { value, _, _ in
            guard let font = value as? PlatformFont else { allOn = false; return }
            if !(bold ? NoteMarkdown.isBold(font) : NoteMarkdown.isItalic(font)) { allOn = false }
        }
        isAdjusting = true
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, runRange, _ in
            if storage.attribute(.attachment, at: runRange.location, effectiveRange: nil) != nil { return }
            let font = value as? PlatformFont ?? NoteMarkdown.baseFont(kind: .paragraph)
            let newFont = NoteMarkdown.withTraits(
                font,
                bold: bold ? !allOn : NoteMarkdown.isBold(font),
                italic: bold ? NoteMarkdown.isItalic(font) : !allOn
            )
            storage.addAttribute(.font, value: newFont, range: runRange)
        }
        storage.endEditing()
        isAdjusting = false
        textView.selectedRange = range
    }
}

// MARK: - Platform text views

#if os(macOS)
/// NSTextView with TextKit 2; a click on a checkbox ticks it.
final class NotePlatformTextView: NSTextView {
    weak var coordinator: NoteTextCoordinator?
    var noteStorage: NSTextStorage? { textStorage }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let coordinator, coordinator.toggleCheckbox(near: index) { return }
        super.mouseDown(with: event)
    }

    func endEditing() {
        window?.makeFirstResponder(nil)
    }

    func didRestyle() {
        needsDisplay = true
    }
}

/// The text view fills the visible height (a click below the last line still lands in the editor);
/// the scroller only shows once the text is taller than that.
final class NoteScrollView: NSScrollView {
    override func layout() {
        super.layout()
        if let textView = documentView as? NSTextView {
            textView.minSize = NSSize(width: 0, height: contentSize.height)
        }
    }
}

struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    let controller: NoteEditorController

    func makeCoordinator() -> NoteTextCoordinator {
        NoteTextCoordinator(text: $text, controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NotePlatformTextView(usingTextLayoutManager: true)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
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

        let scrollView = NoteScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        context.coordinator.textView = textView
        context.coordinator.load(text)
        context.coordinator.controller.bind(context.coordinator)
        textView.isEditable = isEditable
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        guard let textView = coordinator.textView else { return }
        textView.isEditable = isEditable
        if text != coordinator.lastWritten { coordinator.load(text) }
    }
}

extension NoteTextCoordinator: NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        shouldChange(in: range, replacement: replacementString ?? "")
    }

    func textDidChange(_ notification: Notification) {
        didChange()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        selectionChanged()
    }

    func textDidBeginEditing(_ notification: Notification) {
        controller.isEditing = true
    }

    func textDidEndEditing(_ notification: Notification) {
        controller.isEditing = false
        flush()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            let (kind, _) = kind(of: paragraphRange(at: textView.selectedRange.location))
            guard kind.isList else { return false }
            perform(.shift(deeper: true))
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            let (kind, _) = kind(of: paragraphRange(at: textView.selectedRange.location))
            guard kind.isList else { return false }
            perform(.shift(deeper: false))
            return true
        default:
            return false
        }
    }
}

#else
/// UITextView with TextKit 2; a tap on a checkbox ticks it.
final class NotePlatformTextView: UITextView {
    weak var coordinator: NoteTextCoordinator?
    var noteStorage: NSTextStorage? { textStorage }

    func endEditing() {
        resignFirstResponder()
    }

    func didRestyle() {
        setNeedsDisplay()
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let position = closestPosition(to: point) else { return }
        let index = offset(from: beginningOfDocument, to: position)
        _ = coordinator?.toggleCheckbox(near: index)
    }
}

struct NoteTextView: UIViewRepresentable {
    @Binding var text: String
    var isEditable = true
    let controller: NoteEditorController

    func makeCoordinator() -> NoteTextCoordinator {
        NoteTextCoordinator(text: $text, controller: controller)
    }

    func makeUIView(context: Context) -> NotePlatformTextView {
        let textView = NotePlatformTextView(usingTextLayoutManager: true)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = NoteMarkdown.baseFont(kind: .paragraph)
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 200, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.alwaysBounceVertical = true
        textView.allowsEditingTextAttributes = false
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        let tap = UITapGestureRecognizer(target: textView, action: #selector(NotePlatformTextView.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        context.coordinator.load(text)
        context.coordinator.controller.bind(context.coordinator)
        textView.isEditable = isEditable
        return textView
    }

    func updateUIView(_ textView: NotePlatformTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        textView.isEditable = isEditable
        if text != coordinator.lastWritten { coordinator.load(text) }
    }
}

extension NoteTextCoordinator: UITextViewDelegate, UIGestureRecognizerDelegate {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        shouldChange(in: range, replacement: text)
    }

    func textViewDidChange(_ textView: UITextView) {
        didChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selectionChanged()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        controller.isEditing = true
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        controller.isEditing = false
        flush()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
