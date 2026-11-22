import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The note's Markdown as the editor reads and writes it; the SwiftUI views hand in a binding, AppKit a pair of
/// closures.
struct NoteTextBinding {
    let get: () -> String
    let set: (String) -> Void

    var wrappedValue: String {
        get { get() }
        nonmutating set { set(newValue) }
    }
}

/// What the format bar and the note screen ask the editor to do.
enum NoteEditorCommand {
    /// Makes the paragraphs of the selection that kind; the same kind again turns them back into plain text.
    case setKind(NoteBlock.Kind)
    /// Indents (`deeper`) or outdents list items.
    case shift(deeper: Bool)
    /// Bold (`**`) or italic (`*`) around the selection or the word at the cursor; again removes it.
    case toggleInline(String)
    /// Moves the line with the cursor one place up or down (reorders list items and subtasks).
    case moveLine(up: Bool)
    /// A new unticked checklist item at the end, with the cursor in it (a to-do's "Add Subtask").
    case appendChecklistItem
    /// A table, image or divider after the paragraph with the cursor (or in its place when it is empty).
    case insertBlock(RichBlock)
    /// A fenced code block ("```", an empty line, "```") with the cursor in it.
    case insertCodeBlock
}

/// The note as one native text view (TextKit 2), the same editing logic on both platforms:
/// Return and Backspace know about lists and checklists, typing "- " or "# " at the start of a line
/// turns it into that kind, Tab indents a list item. The view hands its text back as Markdown.
@MainActor
final class NoteTextCoordinator: NSObject {
    var text: NoteTextBinding
    let controller: NoteEditorController
    weak var textView: NotePlatformTextView? {
        // Quotes get their bar and code blocks their tint from the layout fragments (`NoteLayoutDecorator`).
        didSet { textView?.textLayoutManager?.delegate = NoteLayoutDecorator.shared }
    }
    /// The Markdown this editor wrote last; a different `text` came from outside (dictation, sync).
    var lastWritten: String
    private var pendingCommit: Task<Void, Never>?
    /// The editor is changing the text itself (markers, renumbering): no rules, no commit.
    var isAdjusting = false

    init(text: NoteTextBinding, controller: NoteEditorController) {
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
        updateEmpty()
        textView.selectedRange = NSRange(location: min(selected.location, storage.length), length: 0)
        resetTypingAttributes()
        forgetUndo()
    }

    /// The editor changed the text itself (another note's text, a marker, new numbers). The undo steps recorded
    /// before point at places that have moved; replaying them would put text in the wrong spot.
    func forgetUndo() {
        textView?.undoManager?.removeAllActions()
    }

    /// Typing that has not reached the note yet (see `commit`).
    var hasPendingCommit: Bool { pendingCommit != nil }

    /// The app ends or leaves the screen: what was typed last must not wait for its turn.
    func observeAppEnd() {
        #if os(macOS)
        let names = [NSApplication.willTerminateNotification, NSApplication.willResignActiveNotification]
        #else
        let names = [UIApplication.willResignActiveNotification, UIApplication.willTerminateNotification]
        #endif
        for name in names {
            appObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.hasPendingCommit == true { self?.flush() } }
            })
        }
        observeImages()
    }

    func stopObserving() {
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers.removeAll()
    }

    private var appObservers: [NSObjectProtocol] = []

    /// Hands the text to the note shortly after the last change. Writing on every key press makes the
    /// notes list update while typing, which costs letters.
    func commit() {
        pendingCommit?.cancel()
        updateEmpty()
        pendingCommit = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { self?.flush() }
        }
    }

    /// Whether the editor has any text: the placeholder shows only when it has none. The text view shows or hides
    /// it right away (not through a SwiftUI update, which may be under way while a note is loaded and then misses
    /// the change, leaving the placeholder over the text).
    func updateEmpty() {
        let isEmpty = (textView?.noteStorage?.length ?? 0) == 0
        if controller.isEmpty != isEmpty { controller.isEmpty = isEmpty }
        textView?.showsPlaceholder = isEmpty
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
        let before = NoteMarkdown.markdown(from: storage.attributedSubstring(from: NSRange(location: 0, length: location)), openEnded: true).count
        // At the start of a heading or quote the cut-off text ends before its hidden "# " or "> ": the cursor is after it.
        let paragraph = paragraphRange(at: location)
        guard location == paragraph.location else { return before }
        let (kind, _) = kind(of: paragraph)
        guard kind == .quote || kind.headingLevel > 0 else { return before }
        return before + NoteBlock(kind: kind, indent: 0, text: "").mark(number: 1).count
    }

    func blur() {
        flush()
        textView?.endEditing()
    }

    // MARK: Paragraphs

    var storage: NSTextStorage? { textView?.noteStorage }
    var string: NSString { (storage?.string ?? "") as NSString }

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
        // A table, image or divider has no kind of its own.
        if hasBlock(paragraph) { return paragraph }
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
        // Older text may still carry a background on code runs; the tint is drawn per paragraph now.
        storage.removeAttribute(.backgroundColor, range: text)
        let content = contentRange(of: range)
        NoteMarkdown.colorTags(in: storage, range: NSRange(location: text.location, length: max(0, content.location + content.length - text.location)), kind: kind)
        storage.endEditing()
        isAdjusting = false
        // The cursor keeps its place in the text; never inside the marker.
        if selection.location >= paragraph.location {
            let shifted = selection.location + (selection.location >= paragraph.location + oldMarker ? marker.length - oldMarker : 0)
            textView.selectedRange = NSRange(location: max(range.location + marker.length, min(shifted, storage.length)), length: selection.length)
        }
        if oldMarker != marker.length { forgetUndo() }
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
                    if delta != 0 { forgetUndo() }
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
        typing[.noteRawBlock] = nil
        typing[.noteEntryLink] = nil
        typing[.kern] = nil
        typing[.backgroundColor] = nil
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

        // Return while entries are offered after "[[": the highlighted one is linked.
        if replacement == "\n", range.length == 0, controller.chooseHighlightedLink() { return false }

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
                forgetUndo()
                if kind == .numbered { renumber() }
                resetTypingAttributes()
                textView.didRestyle()
                commit()
                return false
            case .quote:
                // Return in a quote goes on with the quote (consecutive "> " lines are one quote); Return on an
                // empty quote line ends it.
                if textLength == 0 {
                    restyle(paragraph, kind: .paragraph, indent: 0)
                    commit()
                    return false
                }
                var quote = NoteMarkdown.inlineAttributes(kind: .quote, bold: false, italic: false)
                quote.merge(NoteMarkdown.paragraphAttributes(kind: .quote, indent: 0)) { $1 }
                isAdjusting = true
                storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: quote))
                isAdjusting = false
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                // An empty last line has no characters to carry the kind: what is typed next gets it.
                textView.typingAttributes = quote
                forgetUndo()
                resetTypingAttributes()
                textView.didRestyle()
                commit()
                return false
            case .heading:
                // The line after a heading is plain text.
                isAdjusting = true
                storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: textView.typingAttributes))
                isAdjusting = false
                restyle(paragraphRange(at: range.location + 1), kind: .paragraph, indent: 0)
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                forgetUndo()
                resetTypingAttributes()
                commit()
                return false
            case .code:
                // Return on the closing fence leaves the code block; inside it, lines stay code.
                guard isClosingFence(paragraph) else { return true }
                isAdjusting = true
                storage.replaceCharacters(in: range, with: NSAttributedString(string: "\n", attributes: textView.typingAttributes))
                isAdjusting = false
                restyle(paragraphRange(at: range.location + 1), kind: .paragraph, indent: 0)
                textView.selectedRange = NSRange(location: range.location + 1, length: 0)
                forgetUndo()
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
            // In code a tab is text.
            if kind == .code { return true }
            if kind.isList { shift(deeper: true) }
            return false
        }

        // Nothing is typed into a marker.
        if range.location < start, range.length == 0, !replacement.isEmpty {
            isAdjusting = true
            storage.replaceCharacters(in: NSRange(location: start, length: 0), with: NSAttributedString(string: replacement, attributes: textView.typingAttributes))
            isAdjusting = false
            textView.selectedRange = NSRange(location: start + (replacement as NSString).length, length: 0)
            forgetUndo()
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
                forgetUndo()
                textView.selectedRange = NSRange(location: content.location, length: 0)
                restyle(paragraphRange(at: content.location), kind: converted, indent: 0)
                commit()
                return
            }
        }
        renumberIfNeeded()
        recolor(paragraphRange(at: textView.selectedRange.location))
        updateLinkSearch()
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
        updateLinkSearch()
    }

    /// A click on a checkbox ticks it. `index` is the insertion point nearest the click (either side of the box),
    /// `point` the click in text container coordinates: only a click on the box itself counts, not one at the
    /// start of the item's first letter.
    func toggleCheckbox(near index: Int, at point: CGPoint) -> Bool {
        guard let storage, textView?.isEditable == true else { return false }
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard storage.attribute(.attachment, at: candidate, effectiveRange: nil) != nil,
                  storage.attribute(.noteRawBlock, at: candidate, effectiveRange: nil) == nil,
                  storage.attribute(.noteEntryLink, at: candidate, effectiveRange: nil) == nil else { continue }
            // Without a layout to ask (never with TextKit 2) the nearest box counts, as before.
            if let box = frame(ofCharacterAt: candidate), !box.contains(point) { continue }
            let checked = storage.attribute(.noteChecked, at: candidate, effectiveRange: nil) as? Bool ?? false
            let paragraph = paragraphRange(at: candidate)
            let (_, indent) = kind(of: paragraph)
            restyle(paragraph, kind: .checklist(checked: !checked), indent: indent)
            commit()
            return true
        }
        return false
    }

    /// Where one character is laid out, in text container coordinates (the line's height, the glyph's width).
    func frame(ofCharacterAt location: Int) -> CGRect? {
        guard let layout = textView?.textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location),
              let end = content.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return nil }
        var frame: CGRect?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, segment, _, _ in
            frame = frame.map { $0.union(segment) } ?? segment
            return true
        }
        return frame
    }

    // MARK: Blocks (tables, images, dividers, code)

    /// The paragraph holds a table, image or divider.
    func hasBlock(_ paragraph: NSRange) -> Bool {
        guard let storage, paragraph.length > 0, paragraph.location < storage.length else { return false }
        var found = false
        let range = NSRange(location: paragraph.location, length: min(paragraph.length, storage.length - paragraph.location))
        storage.enumerateAttribute(.noteRawBlock, in: range, options: []) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// A fence line that closes a code block: an even number of fences up to and including it.
    private func isClosingFence(_ paragraph: NSRange) -> Bool {
        let content = contentRange(of: paragraph)
        guard NoteRichText.isFence(string.substring(with: content)) else { return false }
        var fences = 0
        var location = 0
        while location <= paragraph.location, location < string.length {
            let range = paragraphRange(at: location)
            if kind(of: range).0 == .code, NoteRichText.isFence(string.substring(with: contentRange(of: range))) { fences += 1 }
            location = range.location + max(range.length, 1)
        }
        return fences % 2 == 0
    }

    /// Plain paragraph attributes for text put around blocks.
    private var plainAttributes: [NSAttributedString.Key: Any] {
        var attributes = NoteMarkdown.inlineAttributes(kind: .paragraph, bold: false, italic: false)
        attributes.merge(NoteMarkdown.paragraphAttributes(kind: .paragraph, indent: 0)) { $1 }
        return attributes
    }

    /// Where a new block goes: in place of the paragraph with the cursor when that is empty, otherwise after it.
    /// `piece` gets the newline in front when needed; the returned location is where the block starts.
    private func insertionPoint(_ piece: NSMutableAttributedString) -> (at: Int, hasNewline: Bool)? {
        guard let storage, let textView else { return nil }
        let cursor = min(textView.selectedRange.location, storage.length)
        let paragraph = paragraphRange(at: cursor)
        let content = contentRange(of: paragraph)
        let isEmpty = content.length == 0 && kind(of: paragraph).0 == .paragraph
        if !isEmpty { piece.append(NSAttributedString(string: "\n", attributes: plainAttributes)) }
        return (content.location + content.length, paragraph.length > content.length)
    }

    /// Puts a block in a paragraph of its own (see `insertionPoint`). An empty line follows when the block would
    /// end the text, so there is somewhere to type on. Returns where the block's character is.
    @discardableResult
    func insertBlock(_ block: RichBlock) -> Int? {
        guard let storage, let textView else { return nil }
        flush()
        let piece = NSMutableAttributedString()
        guard let point = insertionPoint(piece) else { return nil }
        let (at, hasNewline) = point
        let blockLocation = at + piece.length
        piece.append(NoteMarkdown.blockString(block, source: block.markdown))
        if !hasNewline { piece.append(NSAttributedString(string: "\n", attributes: plainAttributes)) }
        isAdjusting = true
        storage.replaceCharacters(in: NSRange(location: at, length: 0), with: piece)
        isAdjusting = false
        forgetUndo()
        // On the line after the block, as plain text (an empty last line has no characters to read its kind from,
        // and the typing attributes may still be those of a quote or code line before the block).
        textView.selectedRange = NSRange(location: min(blockLocation + 2, storage.length), length: 0)
        textView.typingAttributes = plainAttributes
        resetTypingAttributes()
        renumberIfNeeded()
        textView.didRestyle()
        commit()
        return blockLocation
    }

    /// "```", an empty code line, "```" (see `insertionPoint`); the cursor on the empty line.
    func insertCodeBlock() {
        guard let storage, let textView else { return }
        flush()
        let piece = NSMutableAttributedString()
        guard let point = insertionPoint(piece) else { return }
        let (at, hasNewline) = point
        let start = at + piece.length
        var code = NoteMarkdown.inlineAttributes(kind: .code, bold: false, italic: false)
        code.merge(NoteMarkdown.paragraphAttributes(kind: .code, indent: 0)) { $1 }
        piece.append(NSAttributedString(string: "```\n\n```", attributes: code))
        if !hasNewline { piece.append(NSAttributedString(string: "\n", attributes: plainAttributes)) }
        isAdjusting = true
        storage.replaceCharacters(in: NSRange(location: at, length: 0), with: piece)
        isAdjusting = false
        forgetUndo()
        textView.selectedRange = NSRange(location: start + 4, length: 0)
        resetTypingAttributes()
        textView.didRestyle()
        commit()
    }

    /// The block at `location` (or else the first one with `source`) gets new Markdown; nil takes it away.
    func replaceBlock(at location: Int, source: String, with block: RichBlock?) {
        guard let storage, let textView else { return }
        flush()
        func sourceAt(_ index: Int) -> String? {
            guard index >= 0, index < storage.length else { return nil }
            return storage.attribute(.noteRawBlock, at: index, effectiveRange: nil) as? String
        }
        var index = sourceAt(location) == source ? location : nil
        if index == nil {
            storage.enumerateAttribute(.noteRawBlock, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
                if value as? String == source { index = range.location; stop.pointee = true }
            }
        }
        guard let index else {
            if let block { insertBlock(block) }
            return
        }
        isAdjusting = true
        if let block {
            storage.replaceCharacters(in: NSRange(location: index, length: 1), with: NoteMarkdown.blockString(block, source: block.markdown))
        } else {
            // A block alone on its line goes with the line.
            let paragraph = paragraphRange(at: index)
            let alone = contentRange(of: paragraph).length == 1
            storage.deleteCharacters(in: alone ? paragraph : NSRange(location: index, length: 1))
        }
        isAdjusting = false
        forgetUndo()
        textView.selectedRange = NSRange(location: min(index, storage.length), length: 0)
        resetTypingAttributes()
        textView.didRestyle()
        commit()
    }

    /// The block under a tap or click: a table opens its editor. `index` and `point` as for `toggleCheckbox`.
    func tapBlock(near index: Int, at point: CGPoint) -> Bool {
        guard let storage, textView?.isEditable == true else { return false }
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard let source = storage.attribute(.noteRawBlock, at: candidate, effectiveRange: nil) as? String,
                  let attachment = storage.attribute(.attachment, at: candidate, effectiveRange: nil) as? NoteBlockAttachment else { continue }
            if let box = frame(ofCharacterAt: candidate), !box.contains(point) { continue }
            guard case .table(let table) = attachment.block else { return false }
            controller.tableRequest = TableEditRequest(table: table, location: candidate, source: source, isNew: false)
            return true
        }
        return false
    }

    /// An image came in from iCloud: the blocks showing it are laid out again.
    func refreshImage(_ fileName: String) {
        guard let storage, let textView else { return }
        var places: [(Int, String)] = []
        storage.enumerateAttribute(.noteRawBlock, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let source = value as? String, source.contains(fileName) else { return }
            for offset in 0..<range.length { places.append((range.location + offset, source)) }
        }
        guard !places.isEmpty else { return }
        let selection = textView.selectedRange
        isAdjusting = true
        for (location, source) in places.reversed() {
            guard case .block(let block, _)? = NoteRichText.scan(source).first else { continue }
            storage.replaceCharacters(in: NSRange(location: location, length: 1), with: NoteMarkdown.blockString(block, source: source))
        }
        isAdjusting = false
        textView.selectedRange = selection
        textView.didRestyle()
    }

    /// Markdown from outside (a paste) put in at the selection: tables, images and dividers in it become blocks.
    /// Returns false when it has none, so the text view pastes as usual.
    func pasteMarkdown(_ pasted: String) -> Bool {
        guard let storage, let textView, textView.isEditable else { return false }
        let hasBlocks = NoteRichText.scan(pasted).contains { if case .block = $0 { true } else { false } }
        guard hasBlocks || !EntryLinks.links(in: pasted).isEmpty else { return false }
        // Images of another note come along as files of this one.
        let pasted = controller.adoptingImages(in: pasted)
        let selection = textView.selectedRange
        let converted = NSMutableAttributedString(attributedString: NoteMarkdown.attributed(from: pasted))
        // On a line of its own.
        if selection.location > paragraphRange(at: selection.location).location {
            converted.insert(NSAttributedString(string: "\n", attributes: plainAttributes), at: 0)
        }
        isAdjusting = true
        storage.replaceCharacters(in: selection, with: converted)
        isAdjusting = false
        forgetUndo()
        textView.selectedRange = NSRange(location: min(selection.location + converted.length, storage.length), length: 0)
        resetTypingAttributes()
        renumberIfNeeded()
        textView.didRestyle()
        commit()
        return true
    }

    /// Markdown put in at the selection on lines of its own (a note template): headings, lists, tables and the
    /// rest as the editor shows them. The cursor goes to `cursor` (an offset in `markdown`), else after it.
    func insertMarkdown(_ markdown: String, cursor: Int? = nil) {
        guard let storage, let textView, textView.isEditable else { return }
        flush()
        var selection = textView.selectedRange
        selection.location = min(selection.location, storage.length)
        selection.length = min(selection.length, storage.length - selection.location)
        let converted = NSMutableAttributedString(attributedString: NoteMarkdown.attributed(from: markdown))
        let paragraph = paragraphRange(at: selection.location)
        let content = contentRange(of: paragraph)
        // On a line of its own: after the text before the cursor, before the text after it.
        var lead = 0
        if selection.location > paragraph.location {
            converted.insert(NSAttributedString(string: "\n", attributes: plainAttributes), at: 0)
            lead = 1
        }
        let insertedLength = converted.length
        if selection.location + selection.length < content.location + content.length {
            converted.append(NSAttributedString(string: "\n", attributes: plainAttributes))
        }
        isAdjusting = true
        storage.replaceCharacters(in: selection, with: converted)
        isAdjusting = false
        forgetUndo()
        var caret = selection.location + insertedLength
        if let cursor {
            let before = String(markdown.prefix(max(0, cursor)))
            caret = selection.location + lead + NoteMarkdown.attributed(from: before).length
        }
        textView.selectedRange = NSRange(location: min(caret, storage.length), length: 0)
        resetTypingAttributes()
        renumberIfNeeded()
        textView.didRestyle()
        commit()
    }

    /// The selection as Markdown for copy and cut, when it holds a block (tables, images and dividers as their
    /// source); nil leaves copying to the text view.
    func selectedMarkdown() -> String? {
        guard let storage, let textView, textView.selectedRange.length > 0 else { return nil }
        let range = textView.selectedRange
        guard hasBlock(range) || hasEntryLink(range) else { return nil }
        return NoteMarkdown.markdown(from: storage.attributedSubstring(from: range))
    }

    private func observeImages() {
        appObservers.append(NotificationCenter.default.addObserver(forName: .noteInlineImageReady, object: nil, queue: .main) { [weak self] note in
            guard let name = note.object as? String else { return }
            MainActor.assumeIsolated { self?.refreshImage(name) }
        })
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
        case .moveLine(let up):
            moveLine(up: up)
            return
        case .appendChecklistItem:
            appendChecklistItem()
            return
        case .insertBlock(let block):
            insertBlock(block)
            return
        case .insertCodeBlock:
            insertCodeBlock()
            return
        }
        textView.didRestyle()
        commit()
    }

    /// Where line `index` of the Markdown starts in the view. A table is one paragraph of the view but several lines
    /// of the Markdown: the paragraph that holds the line.
    private func location(ofLine index: Int) -> Int {
        guard let storage else { return 0 }
        var location = 0
        var line = 0
        while location < string.length {
            let paragraph = paragraphRange(at: location)
            let content = contentRange(of: paragraph)
            let lines = NoteMarkdown.blockLines(in: storage, content: content)?.reduce(0) { $0 + $1.components(separatedBy: "\n").count } ?? 1
            if line + lines > index { return paragraph.location }
            line += lines
            location = paragraph.location + max(paragraph.length, 1)
        }
        return min(location, string.length)
    }

    /// The Markdown line the paragraph at `location` starts on.
    private func markdownLine(at location: Int) -> Int {
        guard let storage else { return 0 }
        let start = paragraphRange(at: location).location
        guard start > 0 else { return 0 }
        return NoteMarkdown.markdown(from: storage.attributedSubstring(from: NSRange(location: 0, length: start))).components(separatedBy: "\n").count - 1
    }

    /// Markdown changed here as lines (move, append): written to the note and shown, the cursor on `line`.
    private func replaceMarkdown(_ markdown: String, cursorLine line: Int, atEnd: Bool) {
        guard let textView else { return }
        load(markdown)
        let start = location(ofLine: line)
        let end = contentRange(of: paragraphRange(at: start))
        textView.selectedRange = NSRange(location: atEnd ? end.location + end.length : textStart(of: paragraphRange(at: start)), length: 0)
        resetTypingAttributes()
        textView.didRestyle()
        if text.wrappedValue != markdown { text.wrappedValue = markdown }
    }

    private func moveLine(up: Bool) {
        guard let textView else { return }
        flush()
        let markdown = text.wrappedValue
        // Tables, images and dividers are not moved line by line, nor is a line moved into them.
        let current = paragraphRange(at: textView.selectedRange.location)
        let neighbor: NSRange? = up
            ? (current.location > 0 ? paragraphRange(at: current.location - 1) : nil)
            : (current.location + current.length < string.length ? paragraphRange(at: current.location + current.length) : nil)
        if hasBlock(current) || neighbor.map(hasBlock) == true { return }
        let line = markdownLine(at: min(textView.selectedRange.location, string.length))
        let moved = Todos.moveLine(line, by: up ? -1 : 1, in: markdown)
        guard moved != markdown else { return }
        replaceMarkdown(moved, cursorLine: line + (up ? -1 : 1), atEnd: true)
    }

    private func appendChecklistItem() {
        guard let textView else { return }
        flush()
        let markdown = Todos.appendingSubtask(to: text.wrappedValue)
        #if os(macOS)
        textView.window?.makeFirstResponder(textView)
        #else
        textView.becomeFirstResponder()
        #endif
        replaceMarkdown(markdown, cursorLine: markdown.components(separatedBy: "\n").count - 1, atEnd: true)
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

    /// The placeholder shown over the empty editor (owned by the view around it); the coordinator shows and hides it.
    weak var placeholderView: NSView? {
        didSet { placeholderView?.isHidden = !showsPlaceholder }
    }

    /// Kept as its opposite: no stored default values here, `init(usingTextLayoutManager:)` may not set them.
    private var hidesPlaceholder = false

    var showsPlaceholder: Bool {
        get { !hidesPlaceholder }
        set {
            hidesPlaceholder = !newValue
            placeholderView?.isHidden = hidesPlaceholder
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        if let coordinator, coordinator.toggleCheckbox(near: index, at: inContainer) { return }
        if let coordinator, coordinator.tapBlock(near: index, at: inContainer) { return }
        if let coordinator, coordinator.tapEntryLink(near: index, at: inContainer) { return }
        super.mouseDown(with: event)
    }

    // Tables, images and dividers are copied as their Markdown; Markdown with them is pasted as them, and a
    // picture on the pasteboard becomes an image of the note.
    override func copy(_ sender: Any?) {
        guard let markdown = coordinator?.selectedMarkdown() else { return super.copy(sender) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard coordinator?.selectedMarkdown() != nil else { return super.cut(sender) }
        copy(sender)
        delete(sender)
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let coordinator, board.string(forType: .string) == nil, coordinator.controller.canInsertImages,
           board.availableType(from: [.fileURL]) == nil,
           let data = board.data(forType: .png) ?? board.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }) {
            coordinator.controller.insertImage(data: data, fileExtension: "png", name: "Pasted Image")
            return
        }
        if let text = board.string(forType: .string), coordinator?.pasteMarkdown(text) == true { return }
        super.paste(sender)
    }

    func endEditing() {
        window?.makeFirstResponder(nil)
    }

    // Files and pictures dragged onto the note don't go into its text: they go to the nearest view around it that
    // takes files (on the Mac the window's import). Text and links dragged in are still put where they are dropped.
    private func fileDropTarget(_ sender: NSDraggingInfo) -> NSDraggingDestination? {
        guard sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil else { return nil }
        var view = superview
        while let current = view {
            if current.registeredDraggedTypes.contains(.fileURL) { return current }
            view = current.superview
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let target = fileDropTarget(sender) { return target.draggingEntered?(sender) ?? [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let target = fileDropTarget(sender) { return target.draggingUpdated?(sender) ?? [] }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, let target = fileDropTarget(sender) { target.draggingExited?(sender); return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let target = fileDropTarget(sender) { return target.prepareForDragOperation?(sender) ?? false }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let target = fileDropTarget(sender) { return target.performDragOperation?(sender) ?? false }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, fileDropTarget(sender) != nil { return }
        super.concludeDragOperation(sender)
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
        if handleLinkSearchCommand(selector) { return true }
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

    // No stored default values in this class: `init(usingTextLayoutManager:)` is a factory of UIKit's that does not
    // run Swift's property initializers, so their storage stays zero (nil, false).

    /// Shown over the empty editor, where the first line starts.
    var placeholder: String? {
        didSet { updatePlaceholder() }
    }

    /// Kept as its opposite, so that zero means "shown".
    private var hidesPlaceholder = false

    /// Set by the coordinator whenever the text changes (see `NoteTextCoordinator.updateEmpty`).
    var showsPlaceholder: Bool {
        get { !hidesPlaceholder }
        set {
            guard newValue == hidesPlaceholder else { return }
            hidesPlaceholder = !newValue
            updatePlaceholder()
        }
    }

    private(set) var placeholderLabel: UILabel?

    /// The placeholder is on screen.
    var isShowingPlaceholder: Bool {
        guard let placeholderLabel else { return false }
        return !placeholderLabel.isHidden && placeholderLabel.superview === self
    }

    private func updatePlaceholder() {
        let visible = showsPlaceholder && !(placeholder ?? "").isEmpty
        if visible, placeholderLabel == nil {
            let label = UILabel()
            label.textColor = .tertiaryLabel
            label.font = NoteMarkdown.baseFont(kind: .paragraph)
            label.numberOfLines = 0
            label.isUserInteractionEnabled = false
            label.isAccessibilityElement = false
            addSubview(label)
            placeholderLabel = label
        }
        placeholderLabel?.text = placeholder
        placeholderLabel?.isHidden = !visible
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let placeholderLabel, !placeholderLabel.isHidden else { return }
        let x = textContainerInset.left + textContainer.lineFragmentPadding
        let width = max(0, bounds.width - x - textContainerInset.right - textContainer.lineFragmentPadding)
        let height = placeholderLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        placeholderLabel.frame = CGRect(x: x, y: textContainerInset.top, width: width, height: height)
    }

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
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        if coordinator?.toggleCheckbox(near: index, at: inContainer) == true { return }
        if coordinator?.tapBlock(near: index, at: inContainer) == true { return }
        if coordinator?.tapEntryLink(near: index, at: inContainer) == true {
            // A tap on a link opens its entry; it does not start typing here.
            DispatchQueue.main.async { [weak self] in _ = self?.resignFirstResponder() }
        }
    }

    // Tables, images and dividers are copied as their Markdown; Markdown with them is pasted as them, and a
    // picture on the pasteboard becomes an image of the note.
    override func copy(_ sender: Any?) {
        guard let markdown = coordinator?.selectedMarkdown() else { return super.copy(sender) }
        UIPasteboard.general.string = markdown
    }

    override func cut(_ sender: Any?) {
        guard let markdown = coordinator?.selectedMarkdown() else { return super.cut(sender) }
        UIPasteboard.general.string = markdown
        deleteBackward()
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if let coordinator, !board.hasStrings, board.hasImages, coordinator.controller.canInsertImages,
           let data = board.image?.pngData() {
            coordinator.controller.insertImage(data: data, fileExtension: "png", name: "Pasted Image")
            return
        }
        if let text = board.string, coordinator?.pasteMarkdown(text) == true { return }
        super.paste(sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages, coordinator?.controller.canInsertImages == true {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
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