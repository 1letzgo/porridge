import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Links to other entries in the editor: "[[" offers entries to link, a tap or click on a link opens its entry.
extension NoteTextCoordinator {
    /// The range holds a link to an entry.
    func hasEntryLink(_ range: NSRange) -> Bool {
        guard let storage, range.length > 0, range.location < storage.length else { return false }
        var found = false
        let clipped = NSRange(location: range.location, length: min(range.length, storage.length - range.location))
        storage.enumerateAttribute(.noteEntryLink, in: clipped, options: []) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// A tap or click on a link opens its entry (also in a note that cannot be edited). `index` and `point` as for
    /// `toggleCheckbox`. A link whose entry is missing opens nothing.
    func tapEntryLink(near index: Int, at point: CGPoint) -> Bool {
        guard let storage else { return false }
        for candidate in [index, index - 1] where candidate >= 0 && candidate < storage.length {
            guard let attachment = storage.attribute(.attachment, at: candidate, effectiveRange: nil) as? EntryLinkAttachment else { continue }
            if let box = frame(ofCharacterAt: candidate), !box.contains(point) { continue }
            guard !attachment.isMissing, let open = controller.openEntry else { return false }
            controller.updateLinkSearch(nil)
            open(attachment.target)
            return true
        }
        return false
    }

    /// Looks for "[[" before the cursor in its paragraph and tells the controller what was typed after it. Not in
    /// code, not across a "]" or another link, not over a selection.
    func updateLinkSearch() {
        controller.updateLinkSearch(currentLinkSearch())
    }

    private func currentLinkSearch() -> EntryLinkSearch? {
        guard let textView, let storage, textView.isEditable, controller.isEditing || textView.isFirstResponderNow,
              controller.linkCandidates != nil else { return nil }
        let selection = textView.selectedRange
        guard selection.length == 0, selection.location <= storage.length else { return nil }
        let cursor = selection.location
        let paragraph = paragraphRange(at: cursor)
        guard kind(of: paragraph).0 != .code, !hasBlock(paragraph) else { return nil }
        let start = textStart(of: paragraph)
        guard cursor > start else { return nil }
        let before = string.substring(with: NSRange(location: start, length: cursor - start)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else {
            controller.dismissedLinkSearch = nil
            return nil
        }
        let queryStart = open.location + open.length
        let query = before.substring(from: queryStart)
        guard !query.contains("]"), !query.contains("\u{FFFC}"), !query.hasPrefix(" "), query.count <= 60 else { return nil }
        let location = start + open.location
        if controller.dismissedLinkSearch == location { return nil }
        controller.dismissedLinkSearch = nil
        return EntryLinkSearch(query: query, range: NSRange(location: location, length: cursor - location))
    }

    /// The link in place of `range` ("[[" and the query), then a space; the cursor after it.
    func insertEntryLink(_ candidate: EntryLinks.Candidate, replacing range: NSRange) {
        guard let storage, let textView, range.location + range.length <= storage.length else { return }
        var attributes = textView.typingAttributes
        attributes[.attachment] = nil
        attributes[.noteEntryLink] = nil
        let piece = NSMutableAttributedString(attributedString: NoteMarkdown.entryLinkString(
            id: candidate.id, label: candidate.title, attributes: attributes
        ))
        // A space after the link, unless one follows already.
        let next = range.location + range.length
        let followedBySpace = next < storage.length && string.character(at: next) == 0x20
        if !followedBySpace { piece.append(NSAttributedString(string: " ", attributes: attributes)) }
        isAdjusting = true
        storage.replaceCharacters(in: range, with: piece)
        isAdjusting = false
        forgetUndo()
        textView.selectedRange = NSRange(location: range.location + piece.length + (followedBySpace ? 1 : 0), length: 0)
        textView.typingAttributes = attributes
        resetTypingAttributes()
        textView.didRestyle()
        commit()
    }

    #if os(macOS)
    /// Arrow keys, Return, Tab and Escape while entries are offered after "[[".
    func handleLinkSearchCommand(_ selector: Selector) -> Bool {
        guard controller.linkSearch != nil, !controller.linkResults.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            controller.moveLinkHighlight(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            controller.moveLinkHighlight(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            return controller.chooseHighlightedLink()
        case #selector(NSResponder.cancelOperation(_:)):
            controller.dismissLinkSearch()
        default:
            return false
        }
        return true
    }
    #endif
}

private extension NotePlatformTextView {
    /// The text view has the keyboard focus.
    var isFirstResponderNow: Bool {
        #if os(macOS)
        window?.firstResponder === self
        #else
        isFirstResponder
        #endif
    }
}
