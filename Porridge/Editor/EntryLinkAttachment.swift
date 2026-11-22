import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// On the attachment character of a link to another entry: the entry's UUID string (`EntryLinks`).
    static let noteEntryLink = NSAttributedString.Key("PorridgeNoteEntryLink")
}

/// A link to another entry in the editor: one attachment character that shows the entry's current title in the
/// accent color on a light wash of it, like a word of the text. A link whose entry is missing shows the label it
/// was written with, dimmed and struck through. It is one character: the cursor steps over it, Backspace removes it
/// whole, and the Markdown gets `[Title](porridge://entry/<UUID>)` back (`NoteMarkdown.inlineMarkdown`).
final class EntryLinkAttachment: NSTextAttachment {
    let target: UUID
    /// The entry's current title, or the stored label when it is missing.
    let title: String
    let isMissing: Bool

    static let horizontalPadding: CGFloat = 4
    static let verticalPadding: CGFloat = 1
    static let maximumWidth: CGFloat = 360

    init(target: UUID, title: String, isMissing: Bool) {
        self.target = target
        self.title = title
        self.isMissing = isMissing
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func font(_ attributes: [NSAttributedString.Key: Any]) -> PlatformFont {
        attributes[.font] as? PlatformFont ?? NoteMarkdown.baseFont(kind: .paragraph)
    }

    var shownTitle: String { title.isEmpty ? String(localized: "Untitled") : title }

    private func label(_ font: PlatformFont) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: isMissing ? NoteMarkdown.secondaryColor : NoteMarkdown.tagColor,
            .paragraphStyle: style,
        ]
        if isMissing { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: shownTitle, attributes: attributes)
    }

    func size(font: PlatformFont, maxWidth: CGFloat) -> CGSize {
        let text = label(font).size()
        let limit = max(40, min(Self.maximumWidth, maxWidth.isFinite && maxWidth > 0 ? maxWidth - 4 : Self.maximumWidth))
        let width = min(ceil(text.width) + 2 * Self.horizontalPadding, limit)
        return CGSize(width: width, height: ceil(font.ascender - font.descender) + 2 * Self.verticalPadding)
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        let font = font(attributes)
        let size = size(font: font, maxWidth: proposedLineFragment.width)
        // The label's baseline on the line's baseline.
        return CGRect(x: 0, y: floor(font.descender) - Self.verticalPadding, width: size.width, height: size.height)
    }

    override func image(
        for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> PlatformImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let text = label(font(attributes))
        let missing = isMissing
        return NoteBlockRenderer.render(size: bounds.size) { rect in
            if !missing {
                NoteBlockRenderer.fill(rect, color: NoteMarkdown.tagColor.withAlphaComponent(0.12), radius: 4)
            }
            let inner = rect.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
            text.draw(with: inner, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
        }
    }
}

extension NoteMarkdown {
    /// The attachment character of a link to `id`: the entry's current title when it is there (`EntryLinks.lookup`),
    /// otherwise `label`, shown as missing. `attributes` are those of the text around it (font, color, paragraph).
    static func entryLinkString(id: UUID, label: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let target = EntryLinks.lookup(id)
        let attachment = EntryLinkAttachment(target: id, title: target?.title ?? label, isMissing: target == nil)
        let result = NSMutableAttributedString(attachment: attachment)
        var attributes = attributes
        attributes[.noteEntryLink] = id.uuidString
        attributes[.attachment] = attachment
        result.setAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// The Markdown of the link character at `index`, nil when there is none.
    static func entryLinkMarkdown(in attributed: NSAttributedString, at index: Int) -> String? {
        guard let id = (attributed.attribute(.noteEntryLink, at: index, effectiveRange: nil) as? String).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        let title = (attributed.attribute(.attachment, at: index, effectiveRange: nil) as? EntryLinkAttachment)?.title ?? ""
        return EntryLinks.markdown(id: id, title: title)
    }
}
