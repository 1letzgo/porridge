import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Rewriting the selection with AI (`AIRewrite`): the selection as a piece of the note's Markdown, and the answer
/// put back as one change that Undo takes back whole.
extension NoteTextCoordinator {
    /// The selection to rewrite, or nil: nothing selected, or the editor cannot be written to (a view-only bowl,
    /// a deleted note, while enhancing).
    func rewriteTarget() -> RewriteTarget? {
        guard let textView, textView.isEditable, let storage = textView.noteStorage else { return nil }
        let selection = textView.selectedRange
        guard selection.length > 0, selection.location + selection.length <= storage.length else { return nil }
        let markdown = NoteMarkdown.markdown(from: storage)
        let start = markdownOffset(of: selection.location, in: storage, afterMark: true)
        let end = markdownOffset(of: selection.location + selection.length, in: storage, afterMark: false)
        guard let range = RewriteEdit.normalize(min(start, end)..<max(start, end), in: markdown) else { return nil }
        return RewriteTarget(markdown: markdown, range: range)
    }

    /// A place in the view as a character offset in the Markdown (as `cursorOffset`). `afterMark`: at the start of a
    /// heading or quote, after its hidden "# " or "> ".
    private func markdownOffset(of location: Int, in storage: NSTextStorage, afterMark: Bool) -> Int {
        if location >= storage.length { return NoteMarkdown.markdown(from: storage).count }
        let before = NoteMarkdown.markdown(from: storage.attributedSubstring(from: NSRange(location: 0, length: location)), openEnded: true).count
        let paragraph = paragraphRange(at: location)
        guard afterMark, location == paragraph.location else { return before }
        let (kind, _) = kind(of: paragraph)
        guard kind == .quote || kind.headingLevel > 0 else { return before }
        return before + NoteBlock(kind: kind, indent: 0, text: "").mark(number: 1).count
    }

    /// Puts the rewrite into the note: in place of the selection, or on new lines below it. Returns false when the
    /// selection is not in the note anymore (changed meanwhile) or the editor cannot be written to. `undoManager`:
    /// the text view's when nil.
    @discardableResult
    func applyRewrite(_ target: RewriteTarget, text: String, insertBelow: Bool, undoManager: UndoManager? = nil) -> Bool {
        guard let textView, textView.isEditable, let storage = textView.noteStorage else { return false }
        let current = NoteMarkdown.markdown(from: storage)
        guard let range = RewriteEdit.locate(target, in: current) else { return false }
        let result = insertBelow
            ? RewriteEdit.insertingBelow(range, text: text, in: current)
            : RewriteEdit.replacing(range, with: text, in: current)
        let attributed = NoteMarkdown.attributed(from: result.markdown)
        // The new text selected, so it can be seen (and rewritten again).
        let start = NoteMarkdown.attributed(from: RewriteEdit.substring(result.markdown, 0..<result.range.lowerBound)).length
        let end = NoteMarkdown.attributed(from: RewriteEdit.substring(result.markdown, 0..<result.range.upperBound)).length
        let selection = NSRange(location: min(start, attributed.length), length: max(0, min(end, attributed.length) - min(start, attributed.length)))
        #if os(macOS)
        textView.breakUndoCoalescing()
        #endif
        swapContents(to: attributed, selection: selection, actionName: insertBelow ? "Insert AI Text" : "Rewrite with AI", undoManager: undoManager ?? textView.undoManager)
        return true
    }

    /// The whole text exchanged as one step of Undo: undoing it brings back the text and selection from before,
    /// so the steps recorded before it still fit; redoing it exchanges them again.
    private func swapContents(to new: NSAttributedString, selection: NSRange, actionName: String, undoManager: UndoManager?) {
        guard let textView, let storage = textView.noteStorage else { return }
        let old = NSAttributedString(attributedString: storage)
        let oldSelection = textView.selectedRange
        storage.setAttributedString(new)
        textView.selectedRange = NSRange(location: min(selection.location, storage.length), length: min(selection.length, storage.length - min(selection.location, storage.length)))
        resetTypingAttributes()
        updateEmpty()
        textView.didRestyle()
        flush()
        guard let undo = undoManager else { return }
        undo.registerUndo(withTarget: self) { coordinator in
            MainActor.assumeIsolated {
                coordinator.swapContents(to: old, selection: oldSelection, actionName: actionName, undoManager: undo)
            }
        }
        undo.setActionName(actionName)
    }
}

#if os(iOS)
extension NoteTextCoordinator {
    /// "Rewrite with AI…" in the menu over a selection.
    @objc(textView:editMenuForTextInRange:suggestedActions:)
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0, textView.isEditable else { return nil }
        let rewrite = UIAction(title: "Rewrite with AI…", image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in
            self?.controller.beginRewrite()
        }
        return UIMenu(children: suggestedActions + [rewrite])
    }
}
#endif
