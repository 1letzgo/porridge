import Foundation

/// One line of a note. The note itself stays Markdown text (so sync, search, tags and summaries keep working);
/// the editor shows it as lines and turns it back into Markdown after every change.
struct NoteBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        /// 1 = Title, 2 = Heading, 3 = Subheading.
        case heading(Int)
        case bullet
        case numbered
        case checklist(checked: Bool)
        case quote
    }

    var id = UUID()
    var kind: Kind = .paragraph
    /// Nesting level of list items.
    var indent = 0
    var text = ""

    var isList: Bool {
        switch kind {
        case .bullet, .numbered, .checklist: true
        default: false
        }
    }

    static let maxIndent = 4

    private static func re(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }
    private static let headingMark = re(#"^(#{1,3})[ \t]+(.*)$"#)
    private static let checklistMark = re(#"^([ \t]*)[-*+][ \t]+\[([ xX])\](?:[ \t]+(.*))?$"#)
    private static let bulletMark = re(#"^([ \t]*)[-*+][ \t]+(.*)$"#)
    private static let numberMark = re(#"^([ \t]*)\d{1,3}[.)][ \t]+(.*)$"#)
    private static let quoteMark = re(#"^>[ \t]?(.*)$"#)

    /// One Markdown line as a block. Anything that is no list, heading or quote stays a plain line.
    static func parse(line: String) -> NoteBlock {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
        func level(_ space: String) -> Int {
            min(maxIndent, space.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2)
        }
        if let m = headingMark.firstMatch(in: line, range: whole) {
            return NoteBlock(kind: .heading(group(m, 1).count), text: group(m, 2))
        }
        if let m = checklistMark.firstMatch(in: line, range: whole) {
            return NoteBlock(kind: .checklist(checked: group(m, 2) != " "), indent: level(group(m, 1)), text: group(m, 3))
        }
        if let m = bulletMark.firstMatch(in: line, range: whole) {
            return NoteBlock(kind: .bullet, indent: level(group(m, 1)), text: group(m, 2))
        }
        if let m = numberMark.firstMatch(in: line, range: whole) {
            return NoteBlock(kind: .numbered, indent: level(group(m, 1)), text: group(m, 2))
        }
        if let m = quoteMark.firstMatch(in: line, range: whole) {
            return NoteBlock(kind: .quote, text: group(m, 1))
        }
        return NoteBlock(text: line)
    }

    static func parse(_ markdown: String) -> [NoteBlock] {
        markdown.components(separatedBy: "\n").map { parse(line: $0) }
    }

    /// The number shown for every numbered block (0 for the others); numbering restarts after any other block.
    static func numbers(for blocks: [NoteBlock]) -> [Int] {
        var counters: [Int: Int] = [:]
        return blocks.map { block in
            counters = counters.filter { $0.key < block.indent }
            guard block.kind == .numbered else { return 0 }
            counters[block.indent, default: 0] += 1
            return counters[block.indent]!
        }
    }

    /// The Markdown mark in front of the text, including the indentation.
    func mark(number: Int) -> String {
        let space = String(repeating: "  ", count: indent)
        switch kind {
        case .paragraph: return ""
        case .heading(let level): return String(repeating: "#", count: level) + " "
        case .bullet: return space + "- "
        case .numbered: return space + "\(number). "
        case .checklist(let checked): return space + (checked ? "- [x] " : "- [ ] ")
        case .quote: return "> "
        }
    }

    static func markdown(_ blocks: [NoteBlock]) -> String {
        let numbers = numbers(for: blocks)
        return blocks.enumerated().map { $1.mark(number: numbers[$0]) + $1.text }.joined(separator: "\n")
    }

    /// Character offset in the Markdown of the start of a block's text.
    static func textOffset(of index: Int, in blocks: [NoteBlock]) -> Int {
        let numbers = numbers(for: blocks)
        var offset = 0
        for (i, block) in blocks.enumerated() {
            let mark = block.mark(number: numbers[i])
            if i == index { return offset + mark.count }
            offset += mark.count + block.text.count + 1
        }
        return offset
    }
}
