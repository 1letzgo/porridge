import XCTest
@testable import Porridge

/// Tables, inline images, dividers and code blocks in the note editor: read from Markdown, drawn as blocks,
/// written back as the same Markdown.
@MainActor
final class EditorBlocksTests: XCTestCase {
    private let table = """
    | Name | Amount | Note |
    |:-----|-------:|:----:|
    | Rent | 900 | due \\| monthly |
    | Food | 320 |
    """

    // MARK: Table model

    func testParsesHeaderAlignmentsAndRows() throws {
        let parsed = try XCTUnwrap(MarkdownTable(lines: table.components(separatedBy: "\n")))
        XCTAssertEqual(parsed.header, ["Name", "Amount", "Note"])
        XCTAssertEqual(parsed.alignments, [.left, .right, .center])
        XCTAssertEqual(parsed.rows, [["Rent", "900", "due | monthly"], ["Food", "320", ""]], "escaped pipes stay text, short rows are filled")
    }

    func testRowsWithoutOuterPipesAndLongRows() throws {
        let parsed = try XCTUnwrap(MarkdownTable(lines: ["a | b", "--- | ---", "1 | 2 | 3"]))
        XCTAssertEqual(parsed.header, ["a", "b"])
        XCTAssertEqual(parsed.alignments, [.none, .none])
        XCTAssertEqual(parsed.rows, [["1", "2"]], "a longer row is cut to the header")
        XCTAssertNil(MarkdownTable(lines: ["| a | b |", "| --- |"]), "header and delimiter row must agree")
        XCTAssertNil(MarkdownTable(lines: ["| a | b |", "| x | y |"]), "no delimiter row")
        XCTAssertFalse(MarkdownTable.isDelimiterRow("---"), "a divider, not a one-column table")
        XCTAssertTrue(MarkdownTable.isDelimiterRow("|---|"))
        XCTAssertEqual(MarkdownTable.splitRow("| `a|b` | c |"), ["`a|b`", "c"], "a pipe in code is no separator")
    }

    func testWritesTidyMarkdownThatReadsBackTheSame() throws {
        let parsed = try XCTUnwrap(MarkdownTable(lines: table.components(separatedBy: "\n")))
        let markdown = parsed.markdown
        XCTAssertEqual(markdown, """
        | Name | Amount |      Note      |
        | :--- | -----: | :------------: |
        | Rent |    900 | due \\| monthly |
        | Food |    320 |                |
        """)
        XCTAssertEqual(MarkdownTable(lines: markdown.components(separatedBy: "\n")), parsed)
        let empty = MarkdownTable.empty()
        XCTAssertEqual(MarkdownTable(lines: empty.markdown.components(separatedBy: "\n")), empty)
    }

    func testEditingRowsAndColumns() {
        var t = MarkdownTable(header: ["a", "b"], rows: [["1", "2"]])
        t.addColumn(at: 1)
        XCTAssertEqual(t.header.count, 3)
        XCTAssertEqual(t.rows, [["1", "", "2"]])
        XCTAssertEqual(t.alignments.count, 3)
        t.addRow()
        t.addRow(at: 0)
        XCTAssertEqual(t.rows, [["", "", ""], ["1", "", "2"], ["", "", ""]])
        t.removeRow(at: 0)
        t.removeColumn(at: 1)
        XCTAssertEqual(t.header, ["a", "b"])
        XCTAssertEqual(t.rows, [["1", "2"], ["", ""]])
        t.removeColumn(at: 0)
        t.removeColumn(at: 0)
        XCTAssertEqual(t.columnCount, 1, "a table keeps one column")
        t.rows[0][0] = "a|b\nc"
        XCTAssertTrue(t.markdown.contains("a\\|b c"), "pipes escaped, line breaks become spaces")
    }

    // MARK: Scanning the note

    func testScanFindsBlocksAndKeepsEverySourceLine() {
        let markdown = """
        # Budget
        \(table)
        Text after
        ---
        ![Receipt](attachment:ABC-123.jpg)
        ```
        | not | a |
        |-----|---|
        ---
        ```
        a | b without delimiter
        """
        let segments = NoteRichText.scan(markdown)
        XCTAssertEqual(segments.map(\.source).joined(separator: "\n"), markdown, "nothing lost or changed")
        let blocks = segments.compactMap { segment -> RichBlock? in
            if case .block(let block, _) = segment { return block }
            return nil
        }
        XCTAssertEqual(blocks.count, 3)
        if case .table(let t) = blocks[0] { XCTAssertEqual(t.rows.count, 2) } else { XCTFail("table first") }
        XCTAssertEqual(blocks[1], .divider)
        XCTAssertEqual(blocks[2], .image(NoteImageRef(fileName: "ABC-123.jpg", alt: "Receipt")))
        let code = segments.filter { if case .line(_, true) = $0 { true } else { false } }
        XCTAssertEqual(code.count, 5, "fences and the lines between them are code")
        XCTAssertEqual(segments.last, .line("a | b without delimiter", code: false))
    }

    func testDividersAndImages() {
        XCTAssertTrue(NoteRichText.isDivider("---"))
        XCTAssertTrue(NoteRichText.isDivider("* * *"))
        XCTAssertTrue(NoteRichText.isDivider("___"))
        XCTAssertFalse(NoteRichText.isDivider("--"))
        XCTAssertFalse(NoteRichText.isDivider("- - item"))
        XCTAssertFalse(NoteRichText.isDivider("--- text"))
        XCTAssertNil(NoteImageRef(line: "![x](https://example.com/a.png)"), "only the note's own files")
        XCTAssertNil(NoteImageRef(line: "See ![x](attachment:a.png) here"), "an image is a line of its own")
        XCTAssertEqual(NoteImageRef(fileName: "a.png", alt: "My [photo]").markdown, "![My (photo)](attachment:a.png)")
        XCTAssertEqual(NoteImageRef.fileNames(in: "x ![a](attachment:1.png)\n![b](attachment:2.jpg)"), ["1.png", "2.jpg"])
    }

    func testInlineImagesAreNotListedAgainAsFiles() {
        let note = Note()
        note.attachments = [
            Attachment(fileName: "1.png", name: "Photo.png", kindRaw: "image"),
            Attachment(fileName: "2.pdf", name: "Letter.pdf", kindRaw: "pdf"),
        ]
        note.text = "Look:\n![Photo](attachment:1.png)"
        XCTAssertEqual(note.stripAttachments.map(\.fileName), ["2.pdf"])
        XCTAssertEqual(note.attachments.count, 2, "the image stays an attachment (it syncs as one)")
    }

    // MARK: Editor round trip

    func testEditorRoundTripKeepsBlocksAndCode() {
        let markdown = """
        # Trip
        - [ ] Pack
        \(table)
        ---
        ![Map](attachment:MAP.png)
        ```swift
        let x = **not bold**
        - not a list
        #notatag
        ```
        1. one
        2. two
        """
        let attributed = NoteMarkdown.attributed(from: markdown)
        XCTAssertEqual(NoteMarkdown.markdown(from: attributed), markdown)
        // A table is one character of the editor, kept as its source.
        var blocks = 0
        attributed.enumerateAttribute(.noteRawBlock, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if value != nil { blocks += range.length }
        }
        XCTAssertEqual(blocks, 3)
        // Code is shown as typed: no bold, no tag color.
        let codeLine = (attributed.string as NSString).range(of: "let x = **not bold**")
        XCTAssertNotEqual(codeLine.location, NSNotFound)
        XCTAssertEqual(attributed.attribute(.noteBlock, at: codeLine.location, effectiveRange: nil) as? String, "code")
    }

    func testTextTypedBesideABlockGetsItsOwnLine() {
        let attributed = NSMutableAttributedString(attributedString: NoteMarkdown.attributed(from: "---"))
        attributed.append(NSAttributedString(string: "after", attributes: NoteMarkdown.inlineAttributes(kind: .paragraph, bold: false, italic: false)))
        attributed.insert(NSAttributedString(string: "before", attributes: NoteMarkdown.inlineAttributes(kind: .paragraph, bold: false, italic: false)), at: 0)
        XCTAssertEqual(NoteMarkdown.markdown(from: attributed), "before\n---\nafter")
    }

    func testEditedTableIsWrittenTidy() throws {
        var parsed = try XCTUnwrap(MarkdownTable(lines: ["| a | b |", "|---|---|", "| 1 | 2 |"]))
        parsed.rows[0][1] = "22"
        let attributed = NoteMarkdown.attributed(from: "Intro\n" + RichBlock.table(parsed).markdown + "\nOutro")
        XCTAssertEqual(NoteMarkdown.markdown(from: attributed), "Intro\n| a   | b   |\n| --- | --- |\n| 1   | 22  |\nOutro")
    }

    // MARK: Drawing

    func testTableLayoutFitsTheWidth() {
        let wide = MarkdownTable(header: (1...6).map { "A long column title \($0)" }, rows: [(1...6).map { "Some longer text in cell \($0) that wraps" }])
        let layout = TableLayout(wide, maxWidth: 360)
        XCTAssertEqual(layout.columnWidths.count, 6)
        XCTAssertLessThanOrEqual(layout.size.width, 360 + 1)
        XCTAssertTrue(layout.columnWidths.allSatisfy { $0 >= TableLayout.minimumColumn })
        XCTAssertGreaterThan(layout.rowHeights[1], layout.rowHeights[0] / 2, "wrapped cells make the row taller")
        let small = TableLayout(MarkdownTable(header: ["a", "b"], rows: [["1", "2"]]), maxWidth: 360)
        XCTAssertLessThan(small.size.width, 200, "a small table is as wide as its text")
        XCTAssertNotNil(NoteBlockRenderer.image(of: .table(wide), size: layout.size))
        XCTAssertEqual(NoteBlockRenderer.size(of: .divider, width: 300).width, 300)
    }
}
