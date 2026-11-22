import XCTest
import UIKit
@testable import Porridge

/// How the editor draws its block styles (quotes, code, headings, lists, dividers) and when it shows its
/// placeholder: a real text view, laid out offscreen.
@MainActor
final class EditorRenderingTests: XCTestCase {
    private let sample = """
    # Title
    Some text before.
    > A quote that is long enough to wrap onto a second line in a narrow text view, so the bar has to follow it.
    > Second quote line
    After the quote.
    ```
    let x = 1

    print(x)
    ```
    - bullet item
    1. numbered
    - [ ] open task
    ---
    The end.
    """

    private func makeEditor(_ markdown: String, width: CGFloat = 320, style: UIUserInterfaceStyle = .light) -> (NotePlatformTextView, NoteTextCoordinator, UIWindow) {
        var stored = markdown
        let controller = NoteEditorController()
        let coordinator = NoteTextCoordinator(text: NoteTextBinding(get: { stored }, set: { stored = $0 }), controller: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 900))
        window.overrideUserInterfaceStyle = style
        let textView = NotePlatformTextView(usingTextLayoutManager: true)
        textView.frame = window.bounds
        textView.backgroundColor = .systemBackground
        textView.overrideUserInterfaceStyle = style
        textView.placeholder = "Start typing or dictate…"
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.coordinator = coordinator
        textView.delegate = coordinator
        window.addSubview(textView)
        window.isHidden = false
        coordinator.textView = textView
        coordinator.load(markdown)
        controller.bind(coordinator)
        return (textView, coordinator, window)
    }

    private func snapshot(_ textView: UITextView, name: String) {
        textView.layoutIfNeeded()
        textView.textLayoutManager?.ensureLayout(for: textView.textLayoutManager!.documentRange)
        let renderer = UIGraphicsImageRenderer(bounds: textView.bounds)
        let image = renderer.image { _ in textView.drawHierarchy(in: textView.bounds, afterScreenUpdates: true) }
        let folder = ProcessInfo.processInfo.environment["EDITOR_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
        try? image.pngData()?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    func testSnapshotLight() {
        let (textView, _, window) = makeEditor(sample)
        snapshot(textView, name: "editor-light")
        _ = window
    }

    func testSnapshotDark() {
        let (textView, _, window) = makeEditor(sample, style: .dark)
        snapshot(textView, name: "editor-dark")
        _ = window
    }

    // MARK: Helpers

    /// Types like the keyboard: the editing rules first, then the text view's own insert.
    private func type(_ text: String, into textView: NotePlatformTextView, _ coordinator: NoteTextCoordinator) {
        for character in text {
            let range = textView.selectedRange
            let replacement = String(character)
            guard coordinator.shouldChange(in: range, replacement: replacement) else { continue }
            textView.textStorage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: textView.typingAttributes))
            textView.selectedRange = NSRange(location: range.location + (replacement as NSString).length, length: 0)
            coordinator.didChange()
        }
    }

    private func fragments(of textView: UITextView) -> [(String, NSTextLayoutFragment)] {
        let layout = textView.textLayoutManager!
        layout.ensureLayout(for: layout.documentRange)
        var result: [(String, NSTextLayoutFragment)] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            let text = (fragment.textElement as? NSTextParagraph)?.attributedString.string ?? ""
            result.append((text.trimmingCharacters(in: .newlines), fragment))
            return true
        }
        return result
    }

    private func decoration(_ fragments: [(String, NSTextLayoutFragment)], startingWith prefix: String) -> NoteLayoutFragment.Decoration? {
        (fragments.first { $0.0.hasPrefix(prefix) }?.1 as? NoteLayoutFragment)?.decoration
    }

    // MARK: Quotes and code

    func testQuoteAndCodeParagraphsAreDecoratedOverTheirWholeHeightAndWidth() throws {
        let (textView, _, window) = makeEditor(sample)
        defer { _ = window }
        let all = fragments(of: textView)
        XCTAssertEqual(decoration(all, startingWith: "A quote"), .quote)
        XCTAssertEqual(decoration(all, startingWith: "Second quote"), .quote)
        XCTAssertEqual(decoration(all, startingWith: "let x"), .code)
        XCTAssertEqual(decoration(all, startingWith: "```"), .code)
        XCTAssertEqual(all.filter { $0.0.isEmpty }.compactMap { ($0.1 as? NoteLayoutFragment)?.decoration }, [.code], "the empty code line is tinted too")
        for plain in ["Title", "Some text", "After the quote", "The end"] {
            XCTAssertNil(decoration(all, startingWith: plain), plain)
        }
        // The bar runs along every wrapped line of the quote.
        let quote = try XCTUnwrap(all.first { $0.0.hasPrefix("A quote") }?.1 as? NoteLayoutFragment)
        XCTAssertGreaterThan(quote.textLineFragments.count, 1, "the quote wraps in a 320 pt view")
        let lastLine = try XCTUnwrap(quote.textLineFragments.last)
        XCTAssertGreaterThanOrEqual(quote.decorationRect.maxY, lastLine.typographicBounds.maxY)
        let headIndent = NoteMarkdown.paragraphStyle(kind: .quote, indent: 0).headIndent
        XCTAssertLessThan(quote.layoutFragmentFrame.minX + quote.decorationRect.maxX, headIndent, "the bar stays left of the text")
        XCTAssertGreaterThanOrEqual(quote.layoutFragmentFrame.minX + quote.decorationRect.minX, 0, "inside the container")
        for line in quote.textLineFragments {
            XCTAssertGreaterThan(line.typographicBounds.minX + quote.layoutFragmentFrame.minX + 0.5, quote.layoutFragmentFrame.minX + quote.decorationRect.maxX, "no line starts on the bar")
        }
        XCTAssertTrue(quote.renderingSurfaceBounds.contains(quote.decorationRect))
        // Consecutive quote lines: one bar without a gap.
        let second = try XCTUnwrap(all.first { $0.0.hasPrefix("Second quote") }?.1 as? NoteLayoutFragment)
        XCTAssertEqual(quote.layoutFragmentFrame.minY + quote.decorationRect.maxY, second.layoutFragmentFrame.minY, accuracy: 0.5)
        // Code: the tint spans the text container, not just the letters.
        let code = try XCTUnwrap(all.first { $0.0.hasPrefix("let x") }?.1 as? NoteLayoutFragment)
        XCTAssertEqual(code.decorationRect.width, textView.textContainer.size.width, accuracy: 0.5)
        XCTAssertEqual(code.layoutFragmentFrame.minX + code.decorationRect.minX, 0, accuracy: 0.5)
    }

    func testCodeRunsCarryNoGlyphBackgroundAndFencesAreDimmed() {
        let attributed = NoteMarkdown.attributed(from: "```\nlet x = 1\n```")
        attributed.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            XCTAssertNil(value, "a background on the runs tints only the letters, line by line")
        }
        XCTAssertEqual(attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor, NoteMarkdown.secondaryColor)
        XCTAssertEqual(attributed.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? UIColor, NoteMarkdown.primaryColor)

        let (textView, coordinator, window) = makeEditor("Text")
        defer { _ = window }
        textView.selectedRange = NSRange(location: 4, length: 0)
        coordinator.perform(.insertCodeBlock)
        textView.textStorage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: textView.textStorage.length)) { value, _, _ in
            XCTAssertNil(value)
        }
        XCTAssertNil(textView.typingAttributes[.backgroundColor])
        type("\tx", into: textView, coordinator)
        coordinator.flush()
        XCTAssertEqual(NoteMarkdown.markdown(from: textView.textStorage), "Text\n```\n\tx\n```\n", "a tab is text in code")
    }

    func testQuoteInsertedFromTheMenuLooksLikeAReloadedQuote() {
        let (textView, coordinator, window) = makeEditor("Some words")
        defer { _ = window }
        textView.selectedRange = NSRange(location: 3, length: 0)
        coordinator.controller.insert(.quote)
        let inserted = textView.textStorage.attributes(at: 0, effectiveRange: nil)
        let loaded = NoteMarkdown.attributed(from: "> Some words").attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(inserted[.noteBlock] as? String, "quote")
        XCTAssertEqual(inserted[.font] as? UIFont, loaded[.font] as? UIFont)
        XCTAssertEqual(inserted[.foregroundColor] as? UIColor, loaded[.foregroundColor] as? UIColor)
        XCTAssertEqual(inserted[.paragraphStyle] as? NSParagraphStyle, loaded[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(decoration(fragments(of: textView), startingWith: "Some"), .quote)
        coordinator.flush()
        XCTAssertEqual(NoteMarkdown.markdown(from: textView.textStorage), "> Some words")
    }

    func testReturnContinuesAQuoteAndAnEmptyQuoteLineEndsIt() {
        let (textView, coordinator, window) = makeEditor("> first")
        defer { _ = window }
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        type("\nsecond\n\nafter", into: textView, coordinator)
        XCTAssertEqual(NoteMarkdown.markdown(from: textView.textStorage), "> first\n> second\nafter")
        XCTAssertNil(decoration(fragments(of: textView), startingWith: "after"), "the quote does not bleed into the next line")
        XCTAssertEqual(textView.typingAttributes[.foregroundColor] as? UIColor, NoteMarkdown.primaryColor)

        // Return in the middle splits the quote into two quote lines.
        let (split, splitCoordinator, splitWindow) = makeEditor("> onetwo")
        defer { _ = splitWindow }
        split.selectedRange = NSRange(location: 3, length: 0)
        type("\n", into: split, splitCoordinator)
        XCTAssertEqual(NoteMarkdown.markdown(from: split.textStorage), "> one\n> two")
    }

    func testTextAfterABlockInsertedBelowAQuoteIsPlain() {
        let (textView, coordinator, window) = makeEditor("> quoted")
        defer { _ = window }
        textView.selectedRange = NSRange(location: textView.textStorage.length, length: 0)
        coordinator.perform(.insertBlock(.divider))
        type("plain", into: textView, coordinator)
        XCTAssertEqual(NoteMarkdown.markdown(from: textView.textStorage), "> quoted\n---\nplain")
    }

    // MARK: Placeholder

    func testPlaceholderFollowsTheText() {
        let (textView, coordinator, window) = makeEditor("")
        defer { _ = window }
        XCTAssertTrue(textView.isShowingPlaceholder, "empty note: the placeholder shows")
        coordinator.load("Loaded text")
        XCTAssertFalse(textView.isShowingPlaceholder, "a loaded note hides it")
        coordinator.load("")
        XCTAssertTrue(textView.isShowingPlaceholder)
        type("a", into: textView, coordinator)
        XCTAssertFalse(textView.isShowingPlaceholder, "typing hides it at once")
        coordinator.load("")
        coordinator.perform(.insertBlock(.divider))
        XCTAssertFalse(textView.isShowingPlaceholder, "a block from the + menu hides it")
        coordinator.load("")
        coordinator.perform(.setKind(.checklist(checked: false)))
        XCTAssertFalse(textView.isShowingPlaceholder, "a checkbox hides it")
        XCTAssertFalse(coordinator.controller.isEmpty)
    }
}
