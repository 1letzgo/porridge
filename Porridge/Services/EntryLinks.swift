import Foundation

/// Links between entries, kept in the note's Markdown: no field of their own, so they sync with the text.
///
/// The format is a plain Markdown link to the app's URL of the entry:
///
///     [Title of the entry](porridge://entry/0F8F…-UUID)
///
/// The UUID finds the entry; the label is only a copy of its title at the time of writing. The editor shows the
/// entry's current title (a renamed entry keeps its links) and writes that title back the next time the note is
/// edited (only showing a note never writes it). A link whose entry is gone (deleted, in the trash, or in a shared bowl the reader does not have) shows its
/// label dimmed and struck through. `]`, `[` and `\` in a label are escaped with `\`. Everything else that reads
/// Markdown (previews, chat, exports, other apps) sees an ordinary link with the title as its text.
enum EntryLinks {
    /// One link in a text: the entry, its label as written, and where it is (UTF-16, as `NSString` counts).
    struct Link: Equatable {
        let id: UUID
        let label: String
        let range: NSRange
    }

    private static let uuid = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<!!)\[((?:\\.|[^\]\\\n])*)\]\(porridge://entry/("# + uuid + #")\)"#, options: [.caseInsensitive]
    )

    /// The links in `text`, in order. Fast for texts without any.
    static func links(in text: String) -> [Link] {
        guard text.range(of: "porridge://entry/", options: .caseInsensitive) != nil else { return [] }
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let id = UUID(uuidString: ns.substring(with: match.range(at: 2))) else { return nil }
            return Link(id: id, label: unescape(ns.substring(with: match.range(at: 1))), range: match.range)
        }
    }

    /// The entries `text` links to.
    static func linkedIDs(in text: String) -> Set<UUID> {
        Set(links(in: text).map(\.id))
    }

    /// Whether `text` links to `id` (a quick look at the text first).
    static func text(_ text: String, linksTo id: UUID) -> Bool {
        guard text.range(of: id.uuidString, options: [.caseInsensitive, .literal]) != nil else { return false }
        return links(in: text).contains { $0.id == id }
    }

    /// The Markdown of a link to `id` with `title` as its label.
    static func markdown(id: UUID, title: String) -> String {
        "[\(escape(title))](\(PorridgeURL.entry(id).absoluteString))"
    }

    static func escape(_ label: String) -> String {
        var out = ""
        for char in label.replacingOccurrences(of: "\n", with: " ") {
            if char == "\\" || char == "[" || char == "]" { out.append("\\") }
            out.append(char)
        }
        return out
    }

    /// Undoes `escape`: only `\[`, `\]` and `\\` lose their backslash; any other backslash stays as written.
    static func unescape(_ label: String) -> String {
        var out = ""
        var escaped = false
        for char in label {
            if escaped {
                if char != "\\", char != "[", char != "]" { out.append("\\") }
                out.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else {
                out.append(char)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    /// `text` with every link replaced by what `transform` makes of it.
    static func rewrite(_ text: String, _ transform: (Link) -> String) -> String {
        let found = links(in: text)
        guard !found.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for link in found.reversed() { result.replaceCharacters(in: link.range, with: transform(link)) }
        return result as String
    }

    /// A line as text to read: each link as its label (list previews, titles taken from the first line).
    static func plain(_ line: String) -> String {
        rewrite(line) { $0.label }
    }

    // MARK: - Titles of the entries linked to

    /// What a link shows of its entry. Nil from `lookup` means the entry is missing.
    struct Target: Equatable {
        var title: String
        var symbol: String
    }

    /// Finds an entry for a link by its id: set by each app at launch (the store of the app), by tests as they like.
    /// Entries in the trash count as missing. Called on the main thread.
    nonisolated(unsafe) static var lookup: (UUID) -> Target? = { _ in nil }

    /// Makes `lookup` find entries with `fetch` (the app's store). Off the main thread nothing is found.
    @MainActor
    static func install(fetch: @escaping @MainActor (UUID) -> Note?) {
        lookup = { id in
            guard Thread.isMainThread else { return nil }
            return MainActor.assumeIsolated { target(of: fetch(id)) }
        }
    }

    /// What a link shows of `note`; nil when it is missing or in the trash.
    @MainActor
    static func target(of note: Note?) -> Target? {
        guard let note, !note.isDeleted, note.modelContext != nil else { return nil }
        return Target(title: note.displayTitle, symbol: note.kindSymbol)
    }

    /// `text` with each link as its entry's current title, or its label when the entry is missing.
    static func shownText(_ text: String) -> String {
        rewrite(text) { link in lookup(link.id)?.title ?? link.label }
    }

    // MARK: - In the app

    /// An entry offered after `[[`.
    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let title: String
        let symbol: String
    }

    /// The entries to offer for `query` typed after `[[`: by fuzzy match on the title (`FuzzyMatch`), the more
    /// recently changed first among equal ones; with no query the most recently changed. Never the entry itself
    /// or entries in the trash.
    @MainActor
    static func candidates(for query: String, among notes: [Note], excluding: UUID?, limit: Int = 8) -> [Candidate] {
        let living = notes.filter { !$0.isDeleted && $0.id != excluding }
            .sorted { $0.updatedAt > $1.updatedAt }
        let query = query.trimmingCharacters(in: .whitespaces)
        let ranked = query.isEmpty ? living : FuzzyMatch.rank(living, query: query) { $0.displayTitle }
        return ranked.prefix(limit).map { Candidate(id: $0.id, title: $0.displayTitle, symbol: $0.kindSymbol) }
    }

    /// The entries whose text links to `id` ("Linked From"), most recently changed first. Entries in the trash
    /// are left out.
    @MainActor
    static func backlinks(to id: UUID, among notes: [Note]) -> [Note] {
        notes.filter { !$0.isDeleted && $0.id != id && text($0.text, linksTo: id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Linked From and Mentions, off the main thread

    /// What the search for "Linked From" and "Mentions" reads of another entry: a copy, so it runs off the main thread.
    struct ScanItem: Sendable {
        let id: UUID
        let text: String
        let updatedAt: Date
    }

    /// The other entries of `notes` (not in the trash) as `ScanItem`s.
    @MainActor
    static func scanItems(for note: Note, among notes: [Note]) -> [ScanItem] {
        notes.compactMap { other in
            guard !other.isDeleted, other.id != note.id else { return nil }
            return ScanItem(id: other.id, text: other.text, updatedAt: other.updatedAt)
        }
    }

    /// Changes whenever the result of `scan` for `note` may: its title, another entry changed, came or went. Typing
    /// in `note` itself does not change it.
    @MainActor
    static func scanSignature(for note: Note, among notes: [Note]) -> Int {
        var hasher = Hasher()
        hasher.combine(note.id)
        hasher.combine(mentionTitle(of: note))
        var count = 0
        var latest = Date.distantPast
        for other in notes where !other.isDeleted && other.id != note.id {
            count += 1
            if other.updatedAt > latest { latest = other.updatedAt }
        }
        hasher.combine(count)
        hasher.combine(latest)
        return hasher.finalize()
    }

    /// The entries linking to `id` (all) and those naming `title` without a link (at most `mentionLimit`), each
    /// most recently changed first. Pure: safe off the main thread.
    static func scan(target id: UUID, title: String?, items: [ScanItem], mentionLimit: Int = 8) -> (linkedFrom: [UUID], mentions: [UUID]) {
        var linked: [UUID] = []
        var mentioned: [UUID] = []
        for item in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if text(item.text, linksTo: id) {
                linked.append(item.id)
            } else if let title, mentioned.count < mentionLimit, mentionRange(of: title, in: item.text) != nil {
                mentioned.append(item.id)
            }
        }
        return (linked, mentioned)
    }

    /// `scan` for `note` off the main thread; the entries back on it, in order (those gone meanwhile left out).
    @MainActor
    static func linkedFromAndMentions(of note: Note, among notes: [Note]) async -> (linkedFrom: [Note], mentions: [Note]) {
        let items = scanItems(for: note, among: notes)
        let id = note.id
        let title = mentionTitle(of: note)
        let result = await Task.detached(priority: .utility) { scan(target: id, title: title, items: items) }.value
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let alive = { (id: UUID) -> Note? in byID[id].flatMap { $0.modelContext != nil && !$0.isDeleted ? $0 : nil } }
        return (result.linkedFrom.compactMap(alive), result.mentions.compactMap(alive))
    }

    // MARK: - Mentions

    /// The title by which `note` is mentioned in other texts, or nil when it is too short or too plain to say
    /// anything (one short word, a number, a title the app made up).
    @MainActor
    static func mentionTitle(of note: Note) -> String? {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("\n"), title.count <= 80 else { return nil }
        guard title.contains(where: \.isLetter) else { return nil }
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        // One word must be long enough not to turn up by chance ("Plan", "Ideas").
        if words.count < 2, title.count < 6 { return nil }
        if note.isRecording, title.hasPrefix("Meeting · ") { return nil }
        return title
    }

    /// Where `title` appears in `text` as words of their own (case and accents do not matter), outside links,
    /// code blocks and images. Nil when it does not.
    static func mentionRange(of title: String, in text: String) -> NSRange? {
        let ns = text as NSString
        guard ns.length > 0, !title.isEmpty else { return nil }
        // Most texts do not name it at all: looked for first, before the links and code blocks are worked out.
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard ns.range(of: title, options: options).location != NSNotFound else { return nil }
        let excluded = linkRanges(in: text) + codeRanges(in: text)
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let found = ns.range(of: title, options: [.caseInsensitive, .diacriticInsensitive], range: search)
            guard found.location != NSNotFound else { return nil }
            let before = found.location > 0 ? ns.character(at: found.location - 1) : nil
            let afterIndex = found.location + found.length
            let after = afterIndex < ns.length ? ns.character(at: afterIndex) : nil
            let bounded = !isWordCharacter(before) && !isWordCharacter(after)
            let free = !excluded.contains { NSIntersectionRange($0, found).length > 0 }
            if bounded, free { return found }
            search = NSRange(location: found.location + 1, length: ns.length - found.location - 1)
        }
        return nil
    }

    /// `text` with the first mention of `title` made a link to `id`; nil when there is none.
    static func linkingMention(of title: String, to id: UUID, in text: String) -> String? {
        guard let range = mentionRange(of: title, in: text) else { return nil }
        let ns = text as NSString
        let shown = ns.substring(with: range)
        return ns.replacingCharacters(in: range, with: markdown(id: id, title: shown))
    }

    /// Entries that name `note` by its title without linking to it ("Mentions"), most recently changed first.
    @MainActor
    static func mentions(of note: Note, among notes: [Note], limit: Int = 8) -> [Note] {
        guard let title = mentionTitle(of: note) else { return [] }
        var result: [Note] = []
        for other in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) where !other.isDeleted && other.id != note.id {
            guard !text(other.text, linksTo: note.id), mentionRange(of: title, in: other.text) != nil else { continue }
            result.append(other)
            if result.count == limit { break }
        }
        return result
    }

    /// Makes the first mention of `target` in `source` a link ("Link" under Mentions), with an undo toast. Nothing
    /// is written in a view-only bowl. Returns whether the text changed.
    @MainActor
    @discardableResult
    static func linkMention(in source: Note, to target: Note) -> Bool {
        guard let context = source.modelContext, !source.isDeleted, !BowlSharing.shared.isReadOnly(source),
              // Not while it is being transcribed or summarized: that writes its text too.
              source.status == .ready || source.status == .failed, source.pendingAudioFileName == nil,
              let title = mentionTitle(of: target),
              let linked = linkingMention(of: title, to: target.id, in: source.text) else { return false }
        let old = source.text
        let oldDate = source.updatedAt
        source.text = linked
        source.updatedAt = Date()
        try? context.save()
        // Undo brings the text back only while nothing else changed it meanwhile.
        UndoToast.shared.offer(String(localized: "Linked from “\(source.displayTitle)”"), systemImage: "link") {
            guard source.modelContext != nil, source.text == linked else { return }
            source.text = old
            source.updatedAt = oldDate
            try? context.save()
        }
        return true
    }

    private static func isWordCharacter(_ unit: unichar?) -> Bool {
        guard let unit, let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 0x5F
    }

    /// Every Markdown link and image (`[…](…)`, `![…](…)`), not only those to entries: a title inside one is no mention.
    private static let anyLink = try! NSRegularExpression(pattern: #"!?\[(?:\\.|[^\]\\\n])*\]\([^)\n]*\)|<[a-z]+://[^>\n]*>|[a-z]+://\S+"#, options: [.caseInsensitive])

    private static func linkRanges(in text: String) -> [NSRange] {
        anyLink.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    /// Lines of fenced code blocks, fences included.
    private static func codeRanges(in text: String) -> [NSRange] {
        guard text.contains("```") else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var location = 0
        var open: Int?
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                if let start = open {
                    ranges.append(NSRange(location: start, length: line.location + line.length - start))
                    open = nil
                } else {
                    open = line.location
                }
            }
            location = line.location + max(line.length, 1)
        }
        if let open { ranges.append(NSRange(location: open, length: ns.length - open)) }
        return ranges
    }
}
