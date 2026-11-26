import Foundation

/// The kinds of entries a smart filter can ask for: the kinds of the search (iOS `SearchKind`, Mac `KindFilter`)
/// and documents (`Note.isDocument`), which cut across images and files.
enum SmartFilterKind: String, CaseIterable, Codable, Sendable {
    case openTodos, todos, meetings, notes, links, images, files, documents

    var title: String {
        switch self {
        case .openTodos: String(localized: "Open To-dos")
        case .todos: String(localized: "To-dos")
        case .meetings: String(localized: "Meetings")
        case .notes: String(localized: "Notes")
        case .links: String(localized: "Links")
        case .images: String(localized: "Images")
        case .files: String(localized: "Files")
        case .documents: String(localized: "Documents")
        }
    }

    var symbol: String {
        switch self {
        case .openTodos, .todos: "checklist"
        case .meetings: "waveform"
        case .notes: "text.alignleft"
        case .links: "link"
        case .images: "photo"
        case .files: "doc"
        case .documents: "doc.text"
        }
    }

    /// The same rules as the search's kinds.
    func matches(_ note: Note) -> Bool {
        switch self {
        case .openTodos: note.isTodo && !note.isDone
        case .todos: note.isTodo
        case .meetings: note.isRecording && !note.isLink
        case .notes: !note.isRecording && !note.isLink && !note.isStored && !note.isTodo
        case .links: note.isLink
        case .images: note.isImage
        case .files: note.isFile
        case .documents: note.isDocument
        }
    }
}

/// What a smart filter asks for. Every criterion that is set must fit (AND); one not set lets everything through.
/// Stored with plain strings, so a newer app's values (a kind, a source) do not break the file for an older one:
/// an unknown value simply matches nothing.
struct SmartFilterCriteria: Codable, Equatable, Hashable, Sendable {
    /// Words of the search: every word must be in the entry (as in the search).
    var text: String = ""
    /// `SmartFilterKind` raw value.
    var kind: String?
    /// `NoteSource` raw value (the channel the entry came in through).
    var source: String?
    /// `DocumentKind` raw value: documents of this kind only.
    var documentKind: String?
    /// The sender of a document; a part of its name is enough ("Telekom" finds "Telekom Deutschland GmbH").
    var sender: String?
    /// First and last day, "yyyy-MM-dd", both included. The date of a document is the one on it, of everything
    /// else when it came in.
    var from: String?
    var to: String?
    /// `Projects.key` of a bowl, or `SmartFilterCriteria.inbox` for entries in no bowl.
    var bowl: String?
    /// Every tag must be on the entry (case does not matter).
    var tags: [String] = []

    static let inbox = "inbox"

    init(
        text: String = "", kind: SmartFilterKind? = nil, source: NoteSource? = nil, documentKind: DocumentKind? = nil, sender: String? = nil,
        from: String? = nil, to: String? = nil, bowl: String? = nil, tags: [String] = []
    ) {
        self.text = text
        self.kind = kind?.rawValue
        self.source = source?.rawValue
        self.documentKind = documentKind?.rawValue
        self.sender = sender
        self.from = from
        self.to = to
        self.bowl = bowl
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey { case text, kind, source, documentKind, sender, from, to, bowl, tags }

    /// Missing keys are left at their defaults: files of other versions read.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        documentKind = try c.decodeIfPresent(String.self, forKey: .documentKind)
        sender = try c.decodeIfPresent(String.self, forKey: .sender)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        bowl = try c.decodeIfPresent(String.self, forKey: .bowl)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
    }

    var entryKind: SmartFilterKind? { kind.flatMap(SmartFilterKind.init(rawValue:)) }
    var noteSource: NoteSource? { source.flatMap(NoteSource.init(rawValue:)) }
    var document: DocumentKind? { documentKind.flatMap(DocumentKind.init(rawValue:)) }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedSender: String? {
        let clean = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean?.isEmpty == false ? clean : nil
    }

    /// Nothing set: the filter would list every entry.
    var isEmpty: Bool {
        trimmedText.isEmpty && kind == nil && source == nil && documentKind == nil && trimmedSender == nil && from == nil && to == nil
            && bowl == nil && tags.isEmpty
    }

    /// The filter is about documents: their date and order count.
    var isAboutDocuments: Bool { documentKind != nil || trimmedSender != nil || entryKind == .documents }

    // MARK: Matching

    /// Whether the entry fits. `textIDs` are the entries the search index found for `text` (`NoteIndex.noteIDs`);
    /// nil while the index is not loaded: the words are then looked for in the entry itself.
    @MainActor
    func matches(_ note: Note, textIDs: Set<UUID>? = nil, calendar: Calendar = DocumentInfo.calendar) -> Bool {
        guard !note.isDeleted else { return false }
        if let kind {
            guard let entryKind = SmartFilterKind(rawValue: kind), entryKind.matches(note) else { return false }
        }
        if let source {
            // Entries from before there were channels have "" (`NoteSource.unknown`): they count as notes.
            let raw = note.sourceRaw.isEmpty ? NoteSource.note.rawValue : note.sourceRaw
            let wanted = source.isEmpty ? NoteSource.note.rawValue : source
            guard raw == wanted else { return false }
        }
        if let documentKind {
            guard note.isDocument, (note.documentInfo?.kind ?? .other).rawValue == documentKind else { return false }
        }
        if let sender = trimmedSender {
            let wanted = DocumentExtractor.correspondentKey(sender)
            guard note.isDocument, let name = note.documentInfo?.correspondent else { return false }
            let key = DocumentExtractor.correspondentKey(name)
            guard !wanted.isEmpty, key.contains(wanted) else { return false }
        }
        if let bowl {
            if bowl == Self.inbox {
                guard note.projectIDs.isEmpty else { return false }
            } else {
                guard note.projectIDs.contains(bowl) else { return false }
            }
        }
        if !tags.isEmpty {
            let have = Set(note.tags.map { $0.lowercased() })
            guard tags.allSatisfy({ have.contains(Note.cleanTag($0).lowercased()) }) else { return false }
        }
        if from != nil || to != nil {
            let day = DocumentInfo.dayKey(Self.date(of: note), calendar: calendar)
            if let from, day < from { return false }
            if let to, day > to { return false }
        }
        let words = trimmedText
        if !words.isEmpty {
            if let textIDs {
                // As the search: the index's words, the title and address as typed, and the kind of a document.
                let found = textIDs.contains(note.id) || note.title.localizedCaseInsensitiveContains(words)
                    || (note.url?.localizedCaseInsensitiveContains(words) ?? false) || Documents.matches(note, query: words)
                guard found else { return false }
            } else {
                guard note.matches(words) else { return false }
            }
        }
        return true
    }

    /// The date a date range is about: the date on a document, else when the entry came in.
    static func date(of note: Note) -> Date {
        note.isDocument ? note.documentDate : note.createdAt
    }

    // MARK: From a search

    /// What the search asked for as a smart filter. A word that names a document kind ("Rechnungen") becomes the kind,
    /// a year ("2026") the date range of that year; the other words stay the text.
    static func fromSearch(text: String, tags: [String], kind: SmartFilterKind?) -> SmartFilterCriteria {
        var criteria = SmartFilterCriteria(kind: kind, tags: tags)
        var rest: [String] = []
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            if criteria.documentKind == nil, !ChatQuery.ambiguousDocumentWords.contains(bare.lowercased()),
               let named = DocumentKind.named(bare), named != .other {
                criteria.documentKind = named.rawValue
                continue
            }
            if criteria.from == nil, bare.count == 4, let year = Int(bare), (1990...2100).contains(year) {
                criteria.from = String(format: "%04d-01-01", year)
                criteria.to = String(format: "%04d-12-31", year)
                continue
            }
            rest.append(word)
        }
        criteria.text = rest.joined(separator: " ")
        // A document kind asks for documents: the search's "Files" or "Images" chip says nothing more then.
        if criteria.documentKind != nil, criteria.entryKind == .files || criteria.entryKind == .images { criteria.kind = nil }
        return criteria
    }

    /// The year the date range covers exactly, if it is one whole year.
    var wholeYear: Int? {
        guard let from, let to, from.hasSuffix("-01-01"), to.hasSuffix("-12-31"), from.prefix(4) == to.prefix(4) else { return nil }
        return Int(from.prefix(4))
    }
}

/// A saved search: a name and what it asks for. Nothing is moved: it only lists the entries that fit, wherever
/// they are. Synced as a file, not in the database (`SmartFilterStore`).
struct SmartFilter: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id: UUID
    var name: String
    var criteria: SmartFilterCriteria
    var createdAt: Date
    /// The last change; the newer of two copies wins (`SmartFilterFile.merged`).
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, criteria: SmartFilterCriteria, createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.criteria = criteria
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

/// What the smart filters' file holds: the filters, and when deleted ones went (so a device that still has one does
/// not bring it back).
struct SmartFilterFile: Codable, Equatable, Sendable {
    var version = 1
    var filters: [SmartFilter] = []
    /// Deleted filters by id (uppercase UUID string) with the time they went.
    var deleted: [String: Date] = [:]

    init(filters: [SmartFilter] = [], deleted: [String: Date] = [:]) {
        self.filters = filters
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey { case version, filters, deleted }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // One filter that does not read does not take the others with it.
        filters = (try? c.decodeIfPresent([Lenient<SmartFilter>].self, forKey: .filters))?.compactMap(\.value) ?? []
        deleted = (try? c.decodeIfPresent([String: Date].self, forKey: .deleted)) ?? [:]
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// Deletions are remembered this long; a device away for longer may bring a deleted filter back.
    static let tombstoneLifetime: TimeInterval = 180 * 24 * 3600

    /// Two copies made one: each filter in its newest form, a deletion newer than a filter's last change removes it.
    static func merged(_ a: SmartFilterFile, _ b: SmartFilterFile, now: Date = Date()) -> SmartFilterFile {
        var deleted = a.deleted
        for (id, date) in b.deleted { deleted[id] = max(deleted[id] ?? date, date) }
        deleted = deleted.filter { now.timeIntervalSince($0.value) < tombstoneLifetime }
        var byID: [UUID: SmartFilter] = [:]
        for filter in a.filters + b.filters {
            if let known = byID[filter.id] {
                // The newer wins; at the same moment one fixed choice, so every device keeps the same.
                if known.updatedAt > filter.updatedAt { continue }
                if known.updatedAt == filter.updatedAt, String(describing: known) >= String(describing: filter) { continue }
            }
            byID[filter.id] = filter
        }
        let kept = byID.values.filter { filter in
            guard let gone = deleted[filter.id.uuidString] else { return true }
            return filter.updatedAt > gone
        }
        return SmartFilterFile(filters: SmartFilters.sorted(Array(kept)), deleted: deleted)
    }
}

@MainActor
enum SmartFilters {
    /// By name, as the lists show them.
    nonisolated static func sorted(_ filters: [SmartFilter]) -> [SmartFilter] {
        filters.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
        }
    }

    /// The entries that fit, those in archived bowls included: documents by the date on them, everything else by
    /// last change (newest first). The words are looked up in the search index when it is loaded.
    static func results(_ criteria: SmartFilterCriteria, in notes: [Note], index: NoteIndex? = NoteIndex.shared) -> [Note] {
        let text = criteria.trimmedText
        let ids = text.isEmpty ? nil : index?.noteIDs(matching: text)
        let found = notes.filter { criteria.matches($0, textIDs: ids) }
        if criteria.isAboutDocuments { return Documents.sorted(found) }
        return found.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A name for a filter made from a search: the words and tags, the kind, the year.
    static func suggestedName(for criteria: SmartFilterCriteria, bowlName: (String) -> String? = { _ in nil }) -> String {
        var parts: [String] = []
        if let kind = criteria.document {
            parts.append(kind.title)
        } else if let kind = criteria.entryKind {
            parts.append(kind.title)
        }
        if !criteria.trimmedText.isEmpty { parts.append(criteria.trimmedText) }
        parts += criteria.tags.map { "#" + $0 }
        if let sender = criteria.trimmedSender { parts.append(sender) }
        if let bowl = criteria.bowl {
            parts.append(bowl == SmartFilterCriteria.inbox ? String(localized: "Inbox") : bowlName(bowl) ?? "")
        }
        if let year = criteria.wholeYear { parts.append(String(year)) }
        let name = parts.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? String(localized: "Smart Filter") : name
    }

    /// A line that says what the filter asks for: "Invoice · 2026 · Inbox".
    static func summary(of criteria: SmartFilterCriteria, bowlName: (String) -> String?) -> String {
        var parts: [String] = []
        if let kind = criteria.entryKind { parts.append(kind.title) }
        if let kind = criteria.document { parts.append(kind.title) }
        if let source = criteria.noteSource { parts.append(String(localized: "from \(source.label)")) }
        if let sender = criteria.trimmedSender { parts.append(sender) }
        if !criteria.trimmedText.isEmpty { parts.append("“\(criteria.trimmedText)”") }
        parts += criteria.tags.map { "#" + $0 }
        if let year = criteria.wholeYear {
            parts.append(String(year))
        } else if criteria.from != nil || criteria.to != nil {
            let from = DocumentInfo.date(fromDay: criteria.from).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "…"
            let to = DocumentInfo.date(fromDay: criteria.to).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "…"
            parts.append("\(from) – \(to)")
        }
        if let bowl = criteria.bowl {
            parts.append(bowl == SmartFilterCriteria.inbox ? String(localized: "Inbox") : bowlName(bowl) ?? String(localized: "Deleted Bowl"))
        }
        return parts.isEmpty ? String(localized: "Everything") : parts.joined(separator: " · ")
    }

    /// The sources a filter can ask for, in the order the editors offer them.
    nonisolated static let sources: [NoteSource] = [.note, .meeting, .link, .share, .audioImport]
}
