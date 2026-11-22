import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What a paragraph draws behind its text: quotes a bar at the left edge, code a tint across the whole width.
/// Drawn per paragraph by its layout fragment, so the bar follows every wrapped line and the tint has no gaps
/// between letters, lines or empty lines (a `.backgroundColor` attribute only tints the glyphs).
final class NoteLayoutFragment: NSTextLayoutFragment {
    enum Decoration: Equatable {
        case quote
        case code
    }

    static let quoteBarWidth: CGFloat = 3
    static let quoteBarInset: CGFloat = 1

    let decoration: Decoration

    init(textElement: NSTextElement, range: NSTextRange?, decoration: Decoration) {
        self.decoration = decoration
        super.init(textElement: textElement, range: range)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The decoration of a paragraph of the editor, from its kind (`NoteMarkdown`'s `.noteBlock`).
    static func decoration(for paragraph: NSAttributedString) -> Decoration? {
        guard paragraph.length > 0 else { return nil }
        switch paragraph.attribute(.noteBlock, at: 0, effectiveRange: nil) as? String {
        case "quote": return .quote
        case "code": return .code
        default: return nil
        }
    }

    /// Where the decoration goes, in the fragment's own coordinates. The fragment starts where the text does (after
    /// the paragraph's indent), so both are placed from the container's edge (`-frame.minX`). Both are as tall as
    /// the fragment, spacing after it included: the bars of consecutive quote lines and the tint of consecutive
    /// code lines meet exactly, without gaps or darker overlaps (the colors are translucent).
    var decorationRect: CGRect {
        let frame = layoutFragmentFrame
        let height = frame.height
        switch decoration {
        case .quote:
            return CGRect(x: Self.quoteBarInset - frame.minX, y: 0, width: Self.quoteBarWidth, height: height)
        case .code:
            var width = textLayoutManager?.textContainer?.size.width ?? frame.width
            if !(width.isFinite && width > 0 && width < 100_000) { width = frame.width }
            // A point up into the line before: fragments are drawn on their own surfaces, at whole pixels, which
            // otherwise leaves a hairline between code lines.
            return CGRect(x: -frame.minX, y: -1, width: width, height: height + 1)
        }
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(decorationRect)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = decorationRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        context.setFillColor(resolvedColor.cgColor)
        // Without antialiasing the edge of one paragraph's fill and the next one's share no pixel: no seam
        // (lighter or darker) between lines at fractional positions.
        context.setShouldAntialias(false)
        context.fill(rect)
        context.restoreGState()
        super.draw(at: point, in: context)
    }

    /// The color in the appearance the text is drawn in (light or dark): the Mac's current drawing appearance,
    /// iOS's current traits (both set by the text view while it draws).
    private var resolvedColor: PlatformColor {
        let color = decoration == .quote ? NoteMarkdown.quoteBarColor : NoteMarkdown.codeBackground
        #if os(macOS)
        return color
        #else
        return color.resolvedColor(with: UITraitCollection.current)
        #endif
    }
}

/// Hands TextKit 2 the decorated fragments for quote and code paragraphs. One for all editors: it keeps no state.
final class NoteLayoutDecorator: NSObject, NSTextLayoutManagerDelegate {
    static let shared = NoteLayoutDecorator()

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, let decoration = NoteLayoutFragment.decoration(for: paragraph.attributedString) {
            return NoteLayoutFragment(textElement: textElement, range: textElement.elementRange, decoration: decoration)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}
