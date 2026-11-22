import Foundation

/// The parts of a note's Markdown the editor shows as one piece instead of line by line: tables, inline images
/// and dividers. Their Markdown stays exactly as it is (sync, search, export, summaries read plain text); the
/// editor shows them drawn and writes their source back unchanged until they are edited. Fenced code blocks are
/// lines of their own kind (`NoteBlock.Kind.code`), not pieces.
enum RichBlock: Equatable {
    case table(MarkdownTable)
    case image(NoteImageRef)
    case divider

    /// The Markdown of a block made in the editor (a table in its tidy form).
    var markdown: String {
        switch self {
        case .table(let table): table.markdown
        case .image(let image): image.markdown
        case .divider: "---"
        }
    }
}

/// A Markdown line read for the editor: a line of its own, or a block over one or more lines.
enum NoteSegment: Equatable {
    /// One line; `code` when it is inside a fenced code block (the fences included).
    case line(String, code: Bool)
    /// A block and its source lines as they are in the note.
    case block(RichBlock, source: String)

    var source: String {
        switch self {
        case .line(let line, _): line
        case .block(_, let source): source
        }
    }
}

enum NoteRichText {
    /// The note's lines as lines and blocks. Joining the sources with "\n" gives the Markdown back unchanged.
    static func scan(_ markdown: String) -> [NoteSegment] {
        scan(lines: markdown.components(separatedBy: "\n"))
    }

    static func scan(lines: [String]) -> [NoteSegment] {
        var result: [NoteSegment] = []
        var inFence = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isFence(line) {
                result.append(.line(line, code: true))
                inFence.toggle()
                i += 1
                continue
            }
            if inFence {
                result.append(.line(line, code: true))
                i += 1
                continue
            }
            // A table: a row, then the row of dashes, then rows until a line without a pipe.
            if i + 1 < lines.count, MarkdownTable.isRow(line), MarkdownTable.isDelimiterRow(lines[i + 1]) {
                var end = i + 2
                while end < lines.count, MarkdownTable.isRow(lines[end]), !lines[end].trimmingCharacters(in: .whitespaces).isEmpty {
                    end += 1
                }
                let source = Array(lines[i..<end])
                if let table = MarkdownTable(lines: source) {
                    result.append(.block(.table(table), source: source.joined(separator: "\n")))
                    i = end
                    continue
                }
            }
            if let image = NoteImageRef(line: line) {
                result.append(.block(.image(image), source: line))
            } else if isDivider(line) {
                result.append(.block(.divider, source: line))
            } else {
                result.append(.line(line, code: false))
            }
            i += 1
        }
        return result
    }

    /// "```" or "```swift" (up to three spaces in front).
    static func isFence(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return line.count - trimmed.count <= 3 && trimmed.hasPrefix("```")
    }

    private static let dividerPattern = try! NSRegularExpression(pattern: #"^ {0,3}(?:(?:-[ \t]*){3,}|(?:\*[ \t]*){3,}|(?:_[ \t]*){3,})$"#)

    /// A thematic break: "---", "***", "___" (three or more, spaces allowed between).
    static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3, line.count <= 80 else { return false }
        return dividerPattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }
}

// MARK: - Images

/// An image of the note shown in its text: `![name](attachment:<file name>)`. The file is one of the note's
/// attachments (`Note.attachments`, synced through iCloud Drive like every attachment).
struct NoteImageRef: Equatable {
    static let scheme = "attachment:"

    var fileName: String
    var alt: String

    private static let pattern = try! NSRegularExpression(pattern: #"^[ \t]*!\[([^\]\n]*)\]\(attachment:([^\s()]+)\)[ \t]*$"#)
    private static let anywhere = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(attachment:([^\s()]+)\)"#)

    init(fileName: String, alt: String) {
        self.fileName = fileName
        self.alt = alt
    }

    /// A line that is only an image reference.
    init?(line: String) {
        guard line.contains("](attachment:") else { return nil }
        let ns = line as NSString
        guard let m = Self.pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        self.init(fileName: ns.substring(with: m.range(at: 2)), alt: ns.substring(with: m.range(at: 1)))
    }

    var markdown: String {
        let cleanAlt = alt.replacingOccurrences(of: "]", with: ")").replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "\n", with: " ")
        return "![\(cleanAlt)](\(Self.scheme)\(fileName))"
    }

    /// The file names of every image referenced in a text (inline or alone on a line).
    static func fileNames(in text: String) -> [String] {
        guard text.contains("](attachment:") else { return [] }
        let ns = text as NSString
        return anywhere.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
}

extension Note {
    /// The attachments shown in the text as images (`NoteImageRef`): they are not listed again in the strip of files.
    var inlineImageFileNames: Set<String> { Set(NoteImageRef.fileNames(in: text)) }

    /// The attachments for the strip of files: all but the images shown in the text.
    var stripAttachments: [Attachment] {
        let inline = inlineImageFileNames
        guard !inline.isEmpty else { return attachments }
        return attachments.filter { !inline.contains($0.fileName) }
    }
}

// MARK: - Tables

/// A GitHub-style Markdown table: a header row, a row of dashes (with colons for the alignment), body rows.
///
///     | Name | Amount |
///     | ---- | -----: |
///     | Rent |    900 |
struct MarkdownTable: Equatable {
    enum Alignment: Equatable {
        case none, left, center, right
    }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]

    var columnCount: Int { header.count }

    init(header: [String], alignments: [Alignment]? = nil, rows: [[String]]) {
        let columns = max(1, header.count)
        self.header = Self.fit(header, to: columns)
        self.alignments = (alignments ?? []).count == columns ? alignments! : Self.fit(alignments ?? [], to: columns, filler: .none)
        self.rows = rows.map { Self.fit($0, to: columns) }
    }

    /// A new table to fill in: two columns, two empty rows.
    static func empty(columns: Int = 2, rows: Int = 2) -> MarkdownTable {
        MarkdownTable(header: (1...max(1, columns)).map { String(localized: "Column \($0)") }, rows: Array(repeating: Array(repeating: "", count: max(1, columns)), count: max(0, rows)))
    }

    // MARK: Reading

    /// A line that can be a row: it has a pipe that is not escaped.
    static func isRow(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        return !splitRow(line).isEmpty && line.replacingOccurrences(of: "\\|", with: "").contains("|")
    }

    /// The row of dashes under the header: "|---|:--:|--:|" (pipes at the ends optional).
    static func isDelimiterRow(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        // One column needs a pipe somewhere, or "---" alone would be a divider.
        if cells.count == 1, !line.contains("|") { return false }
        return cells.allSatisfy { cell in
            var c = Substring(cell.trimmingCharacters(in: .whitespaces))
            if c.hasPrefix(":") { c = c.dropFirst() }
            if c.hasSuffix(":") { c = c.dropLast() }
            return !c.isEmpty && c.allSatisfy { $0 == "-" }
        }
    }

    /// The cells of a row: split at pipes that are not escaped, outer pipes dropped, spaces trimmed, `\|` kept as
    /// a pipe in the text.
    static func splitRow(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The table of these lines (header, delimiter row, body rows); nil when they are none.
    init?(lines: [String]) {
        guard lines.count >= 2, Self.isRow(lines[0]), Self.isDelimiterRow(lines[1]) else { return nil }
        let header = Self.splitRow(lines[0])
        let delimiter = Self.splitRow(lines[1])
        // GFM: the header and the delimiter row must have the same number of cells.
        guard header.count == delimiter.count else { return nil }
        let alignments: [Alignment] = delimiter.map { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return .none
            }
        }
        // Body rows are cut or filled to the header's width, as GFM does.
        let rows = lines.dropFirst(2).map { Self.splitRow($0) }
        self.init(header: header, alignments: alignments, rows: Array(rows))
    }


    // MARK: Writing

    /// The table as tidy Markdown: pipes at both ends, columns padded so the plain text lines up.
    var markdown: String {
        let escapedHeader = header.map(Self.escape)
        let escapedRows = rows.map { $0.map(Self.escape) }
        var widths = escapedHeader.map { max(3, Self.width($0)) }
        for row in escapedRows {
            for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], Self.width(cell)) }
        }
        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { i, cell in pad(cell, to: widths[i], alignment: alignments[i]) }.joined(separator: " | ") + " |"
        }
        let delimiter = "| " + alignments.enumerated().map { i, alignment in
            let dashes = String(repeating: "-", count: widths[i])
            switch alignment {
            case .none: return dashes
            case .left: return ":" + dashes.dropFirst()
            case .right: return dashes.dropLast() + ":"
            case .center: return ":" + dashes.dropFirst().dropLast() + ":"
            }
        }.joined(separator: " | ") + " |"
        return ([line(escapedHeader), delimiter] + escapedRows.map(line)).joined(separator: "\n")
    }

    private func pad(_ cell: String, to width: Int, alignment: Alignment) -> String {
        let space = max(0, width - Self.width(cell))
        switch alignment {
        case .right: return String(repeating: " ", count: space) + cell
        case .center:
            let left = space / 2
            return String(repeating: " ", count: left) + cell + String(repeating: " ", count: space - left)
        default: return cell + String(repeating: " ", count: space)
        }
    }

    /// Characters as they line up in a monospaced font (one per grapheme).
    private static func width(_ text: String) -> Int { text.count }

    /// A cell as Markdown: pipes escaped, line breaks as spaces.
    static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|").trimmingCharacters(in: .whitespaces)
    }

    private static func fit<T>(_ cells: [T], to count: Int, filler: T) -> [T] {
        if cells.count >= count { return Array(cells.prefix(count)) }
        return cells + Array(repeating: filler, count: count - cells.count)
    }

    private static func fit(_ cells: [String], to count: Int) -> [String] { fit(cells, to: count, filler: "") }

    // MARK: Editing

    mutating func addRow(at index: Int? = nil) {
        let row = Array(repeating: "", count: columnCount)
        rows.insert(row, at: min(max(0, index ?? rows.count), rows.count))
    }

    mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    mutating func addColumn(at index: Int? = nil) {
        let at = min(max(0, index ?? columnCount), columnCount)
        header.insert(String(localized: "Column \(columnCount + 1)"), at: at)
        alignments.insert(.none, at: at)
        for i in rows.indices { rows[i].insert("", at: at) }
    }

    /// A table keeps at least one column.
    mutating func removeColumn(at index: Int) {
        guard columnCount > 1, header.indices.contains(index) else { return }
        header.remove(at: index)
        alignments.remove(at: index)
        for i in rows.indices where rows[i].indices.contains(index) { rows[i].remove(at: index) }
    }

    /// Cell text as shown: inline marks kept for the renderer, escapes resolved.
    static func displayText(_ cell: String) -> String {
        cell.replacingOccurrences(of: "<br>", with: " ")
    }
}
