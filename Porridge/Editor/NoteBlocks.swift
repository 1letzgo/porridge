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
        /// A line of a fenced code block, the fences ("```") included: kept exactly as typed, in a monospaced font.
        case code
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

    /// Every line as a block; lines of fenced code blocks (`NoteRichText.isFence`) are code, whatever they look like.
    static func parse(_ markdown: String) -> [NoteBlock] {
        var inFence = false
        return markdown.components(separatedBy: "\n").map { line in
            if NoteRichText.isFence(line) {
                inFence.toggle()
                return NoteBlock(kind: .code, text: line)
            }
            return inFence ? NoteBlock(kind: .code, text: line) : parse(line: line)
        }
    }

    /// The number shown for every numbered block (0 for the others); numbering restarts after any other block.
    static func numbers(for blocks: [NoteBlock]) -> [Int] {
        var counters: [Int: Int] = [:]
        return blocks.map { block in
            // The same counting as `NoteMarkdown.next`: items at a level count on, deeper levels start over,
            // and a paragraph that is no list ends every list.
            if block.kind == .numbered {
                counters = counters.filter { $0.key <= block.indent }
                counters[block.indent, default: 0] += 1
                return counters[block.indent]!
            }
            counters = block.isList ? counters.filter { $0.key < block.indent } : [:]
            return 0
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
        case .code: return ""
        }
    }

    static func markdown(_ blocks: [NoteBlock]) -> String {
        let numbers = numbers(for: blocks)
        return blocks.enumerated().map { $1.mark(number: numbers[$0]) + $1.text }.joined(separator: "\n")
    }

}

extension NoteBlock.Kind {
    var isList: Bool {
        switch self {
        case .bullet, .numbered, .checklist: true
        default: false
        }
    }

    var headingLevel: Int {
        if case .heading(let level) = self { return level }
        return 0
    }
}
