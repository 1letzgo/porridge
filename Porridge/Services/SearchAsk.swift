import Foundation

/// Search & Ask: one field for searching, asking the chat and going somewhere (on the Mac also for commands). What
/// iPhone and Mac show for a query, in this order: "Ask Porridge: …" first (asking is a choice, never automatic), then
/// the places, smart filters and bowls that fit ("Go To"), then the entries that fit, the newest first. "Ask Porridge"
/// hands the question over to the chat (its own tab on the iPhone, its own place on the Mac). An empty field
/// shows the recent searches and the tags. Pure: the views hand in what they have.
@MainActor
enum SearchAsk {
    // MARK: Scope

    /// Where a search looks and what a chat is about: everything, the Inbox, or one bowl (`Projects.key`).
    nonisolated enum Scope: Hashable, Sendable {
        case everywhere
        case inbox
        case bowl(String)

        /// As a chat keeps it (`ChatThread.projectID`, local only): nil is everything, `inboxKey` the Inbox, else the
        /// bowl's key.
        var chatKey: String? {
            switch self {
            case .everywhere: nil
            case .inbox: SearchAsk.inboxKey
            case .bowl(let key): key
            }
        }

        init(chatKey: String?) {
            switch chatKey {
            case nil: self = .everywhere
            case SearchAsk.inboxKey?: self = .inbox
            case let key?: self = .bowl(key)
            }
        }

        func contains(_ note: Note) -> Bool {
            switch self {
            case .everywhere: true
            case .inbox: note.isInInbox
            case .bowl(let key): note.projectIDs.contains(key)
            }
        }
    }

    /// `ChatThread.projectID` of a chat about the Inbox (bowl keys are UUIDs, so it cannot clash).
    static let inboxKey = "inbox"

    /// The scope's name in the search's chip: "Everywhere", "Inbox" or the bowl.
    static func searchName(_ scope: Scope, bowls: [NoteFolder]) -> String {
        scope == .everywhere ? String(localized: "Everywhere") : chatName(scope.chatKey, bowls: bowls)
    }

    /// What a chat is about, in its pill and in the lists of chats: "All Bowls", "Inbox" or the bowl.
    static func chatName(_ key: String?, bowls: [NoteFolder]) -> String {
        switch Scope(chatKey: key) {
        case .everywhere: String(localized: "All Bowls")
        case .inbox: String(localized: "Inbox")
        case .bowl(let key): bowls.first { Projects.key($0) == key }?.name ?? String(localized: "Deleted Bowl")
        }
    }

    // MARK: Ask

    /// The question of the "Ask Porridge: …" row: what is typed, trimmed; nil while nothing is typed.
    static func question(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// "Ask Porridge: “…”".
    static func askTitle(_ question: String) -> String {
        String(localized: "Ask Porridge: “\(question)”")
    }

    /// The line under it: "Answers with sources · All Bowls".
    static func askSubtitle(_ scope: Scope, bowls: [NoteFolder]) -> String {
        String(localized: "Answers with sources") + " · " + chatName(scope.chatKey, bowls: bowls)
    }

    // MARK: Go To

    /// Somewhere to go: a place or fixed view, a smart filter or a bowl.
    struct Target: Hashable, Identifiable, Sendable {
        enum Destination: Hashable, Sendable {
            case today, inbox, bowls, openTodos, weeklyReview, triage, archive, trash, settings, allChats
            case smartFilter(UUID)
            case bowl(UUID)
        }

        /// The order among equally good matches: places first, then smart filters, then bowls.
        enum Kind: Int, Comparable, Sendable {
            case place, smartFilter, bowl
            static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
        }

        var destination: Destination
        var title: String
        var subtitle: String
        var symbol: String
        /// More words it is found by ("preferences" for Settings).
        var keywords = ""
        /// An archived bowl: found, but after the others.
        var isArchived = false

        var id: Destination { destination }

        var kind: Kind {
            switch destination {
            case .smartFilter: .smartFilter
            case .bowl: .bowl
            default: .place
            }
        }
    }

    /// The places and fixed views (iPhone: Go To rows; the Mac has them as commands): Today, Inbox, Bowls, Open
    /// To-dos, Weekly Review, Triage Inbox (a command), Archive, Recently Deleted, Settings, All Chats.
    static func places() -> [Target] {
        let place = String(localized: "Place"), view = String(localized: "View")
        return [
            Target(destination: .today, title: String(localized: "Today"), subtitle: place, symbol: "calendar", keywords: "day due appointments"),
            Target(destination: .inbox, title: String(localized: "Inbox"), subtitle: place, symbol: "tray.fill", keywords: "new later"),
            Target(destination: .bowls, title: String(localized: "Bowls"), subtitle: place, symbol: Places.bowlsSymbol, keywords: "all"),
            Target(destination: .openTodos, title: String(localized: "Open To-dos"), subtitle: view, symbol: "checklist", keywords: "tasks todo"),
            Target(destination: .weeklyReview, title: String(localized: "Weekly Review"), subtitle: view, symbol: "calendar.badge.checkmark", keywords: "week summary"),
            Target(destination: .triage, title: String(localized: "Triage Inbox"), subtitle: String(localized: "Command"), symbol: "bolt.fill", keywords: "file sort one by one"),
            Target(destination: .archive, title: String(localized: "Archive"), subtitle: view, symbol: "archivebox.fill", keywords: "archived bowls"),
            Target(destination: .trash, title: String(localized: "Recently Deleted"), subtitle: view, symbol: "trash.fill", keywords: "trash bin"),
            Target(destination: .settings, title: String(localized: "Settings"), subtitle: String(localized: "General · Recording · AI"), symbol: "gearshape.fill", keywords: "preferences options models name sync"),
            Target(destination: .allChats, title: String(localized: "All Chats"), subtitle: view, symbol: "bubble.left.and.bubble.right.fill", keywords: "chat questions"),
        ]
    }

    /// The smart filters and bowls as targets, each with how many entries it holds ("Smart Filter · 3 entries",
    /// "Bowl · 24 entries"). `places` puts the places in front (iPhone).
    static func targets(bowls: [NoteFolder], filters: [SmartFilter], notes: [Note], places includesPlaces: Bool = true) -> [Target] {
        let living = notes.filter { !$0.isDeleted }
        var counts: [String: Int] = [:]
        for note in living { for key in note.projectIDs { counts[key, default: 0] += 1 } }
        var result = includesPlaces ? places() : []
        for filter in filters {
            let count = living.filter { filter.criteria.matches($0) }.count
            result.append(Target(
                destination: .smartFilter(filter.id), title: filter.name,
                subtitle: String(localized: "Smart Filter") + " · " + entriesText(count), symbol: "line.3.horizontal.decrease"
            ))
        }
        for bowl in bowls {
            let count = counts[Projects.key(bowl)] ?? 0
            let what = bowl.isArchived ? String(localized: "Archived Bowl") : String(localized: "Bowl")
            result.append(Target(
                destination: .bowl(bowl.id), title: bowl.name, subtitle: what + " · " + entriesText(count),
                symbol: bowl.isArchived ? "archivebox" : "folder.fill", isArchived: bowl.isArchived
            ))
        }
        return result
    }

    static func entriesText(_ count: Int) -> String {
        count == 1 ? String(localized: "1 entry") : String(localized: "\(count) entries")
    }

    /// The targets that fit the query, best first: by how well the name fits (`FuzzyMatch`; a match in the name beats
    /// one in the keywords), among equals places before smart filters before bowls, archived bowls last. Nothing
    /// for an empty query.
    static func goTo(_ query: String, in targets: [Target], limit: Int = 5) -> [Target] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        let scored: [(target: Target, score: Int, order: Int)] = targets.enumerated().compactMap { index, target in
            guard let score = score(query, title: target.title, keywords: target.keywords) else { return nil }
            return (target, score - (target.isArchived ? 40 : 0), index)
        }
        return scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.target.kind != $1.target.kind { return $0.target.kind < $1.target.kind }
                return $0.order < $1.order
            }
            .prefix(limit)
            .map(\.target)
    }

    /// How well a query finds something to go to or run (a place, bowl, smart filter or a Mac command): by its name
    /// (`FuzzyMatch.strictScore`: word starts, longer runs inside a word, first letters), or 60 less by its extra
    /// words, there only at word starts and from three letters on. Nil when it does not fit: letters scattered
    /// through a name are no reason to go there ("cha" is not "Kitchen Renovation").
    static func score(_ query: String, title: String, keywords: String = "") -> Int? {
        let byName = FuzzyMatch.strictScore(query, in: title)
        var byKeyword: Int?
        if !keywords.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 3 {
            byKeyword = FuzzyMatch.strictScore(query, in: title + " " + keywords, wordStartsOnly: true).map { $0 - 60 }
        }
        guard let best = [byName, byKeyword].compactMap({ $0 }).max(), best > 0 else { return nil }
        return best
    }

    // MARK: The best row

    /// How closely a row's name fits what was typed, for choosing the row Return runs.
    enum Fit: Int, Comparable, Sendable {
        /// Found otherwise: inside the text of an entry, by first letters or extra words.
        case loose
        /// Every typed word starts a word of the name ("review" → "Design Review").
        case words
        /// The name starts with what was typed ("design" → "Design Review").
        case start
        /// The name is what was typed.
        case exact

        static func < (a: Fit, b: Fit) -> Bool { a.rawValue < b.rawValue }
    }

    static func fit(_ query: String, name: String) -> Fit {
        let typed = FuzzyMatch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let folded = FuzzyMatch.fold(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !typed.isEmpty else { return .loose }
        if folded == typed { return .exact }
        if folded.hasPrefix(typed) { return .start }
        let nameWords = folded.split { !$0.isLetter && !$0.isNumber }
        let typedWords = typed.split { !$0.isLetter && !$0.isNumber }
        if !typedWords.isEmpty, typedWords.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) { return .words }
        return .loose
    }

    /// What a row is, for choosing the row Return runs: going somewhere (a bowl or smart filter, an entry, a place)
    /// changes nothing; an action (New Note, Record Meeting, Export…) does something.
    enum Pick: Int, Comparable, Sendable {
        case bowl, entry, place, action
        static func < (a: Pick, b: Pick) -> Bool { a.rawValue < b.rawValue }
    }

    /// The row Return runs among the candidates (in the order shown): the closest fit, among equals a bowl or smart
    /// filter before an entry before a place before an action. An action is never chosen by a loose fit, and never
    /// over a bowl or entry that fits as well (so "design" opens "Design Review", never Record Meeting). Nil when
    /// nothing qualifies (then "Show All Results" is the safe choice).
    static func best(_ candidates: [(fit: Fit, pick: Pick)]) -> Int? {
        candidates.indices
            .filter { candidates[$0].pick != .action || candidates[$0].fit > .loose }
            .min { a, b in
                let x = candidates[a], y = candidates[b]
                if x.fit != y.fit { return x.fit > y.fit }
                if x.pick != y.pick { return x.pick < y.pick }
                return a < b
            }
    }

    // MARK: Entries

    /// The entries that fit, the newest change first: not deleted, of the kind (when one is chosen), with every tag,
    /// in the scope, and holding the text — by the search index (`indexMatches`, every passage and transcript), the
    /// title, the link or the document's details; without an index, by the note's own text.
    static func entries(
        _ notes: [Note], query: String, tags: [String] = [], kind: ((Note) -> Bool)? = nil, scope: Scope = .everywhere,
        indexMatches: Set<UUID>?
    ) -> [Note] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = Set(tags.map { $0.lowercased() })
        let found = notes.filter { note in
            guard !note.isDeleted, scope.contains(note) else { return false }
            if let kind, !kind(note) { return false }
            if !wanted.isEmpty, !wanted.isSubset(of: Set(note.tags.map { $0.lowercased() })) { return false }
            guard !text.isEmpty else { return true }
            if let indexMatches {
                return indexMatches.contains(note.id) || note.title.localizedCaseInsensitiveContains(text)
                    || (note.url?.localizedCaseInsensitiveContains(text) ?? false) || Documents.matches(note, query: text)
            }
            return note.matches(text)
        }
        return found.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Entries under headings by their last change: Today, Yesterday, Previous 7 Days, Previous 30 Days, the months of
    /// this year, earlier years. `label` is the short form for an index along the edge.
    static func dateGroups(_ notes: [Note], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, label: String, notes: [Note])] {
        var result: [(title: String, label: String, notes: [Note])] = []
        for note in notes {
            let date = note.updatedAt
            let title: String
            let label: String
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
            // A date ahead (another device's clock) counts as today, so no heading comes twice.
            if calendar.isDate(date, inSameDayAs: now) || days < 0 {
                title = String(localized: "Today"); label = "T"
            } else if days == 1 {
                title = String(localized: "Yesterday"); label = "Y"
            } else if days <= 7 {
                title = String(localized: "Previous 7 Days"); label = "7"
            } else if days <= 30 {
                title = String(localized: "Previous 30 Days"); label = "30"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                title = date.formatted(.dateTime.month(.wide)); label = String(title.prefix(1)).uppercased()
            } else {
                title = date.formatted(.dateTime.year()); label = String(title.suffix(2))
            }
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].notes.append(note)
            } else {
                result.append((title, label, [note]))
            }
        }
        return result
    }

    // MARK: The rows, in order

    /// One row of the results.
    enum Row: Hashable {
        case ask(String)
        case goTo(Target)
        case entry(UUID)
    }

    /// The rows for a query: "Ask Porridge" first, then where to go, then the entries (already in their order).
    static func rows(query: String, targets: [Target], entries: [Note], goToLimit: Int = 5) -> [Row] {
        guard let question = question(query) else { return entries.map { .entry($0.id) } }
        return [.ask(question)] + goTo(question, in: targets, limit: goToLimit).map { .goTo($0) } + entries.map { .entry($0.id) }
    }

    // MARK: Empty field

    /// The chats to take up again, the latest first.
    static func recentChats(_ threads: [ChatThread], limit: Int = 3) -> [ChatThread] {
        Array(threads.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// What was searched for lately, on this device (the last ten, the latest first, each once).
    enum RecentSearches {
        static let key = "searchAskRecentSearches"
        static let limit = 10

        static func all(in defaults: UserDefaults = .standard) -> [String] {
            defaults.stringArray(forKey: key) ?? []
        }

        /// Keeps a search: what was typed with its tags ("#bills telekom"). Blank ones are not kept.
        static func add(_ text: String, tags: [String] = [], in defaults: UserDefaults = .standard) {
            let line = (tags.map { "#" + $0 } + [text.trimmingCharacters(in: .whitespacesAndNewlines)])
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !line.isEmpty else { return }
            var list = all(in: defaults).filter { $0.compare(line, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame }
            list.insert(line, at: 0)
            defaults.set(Array(list.prefix(limit)), forKey: key)
        }

        static func remove(_ line: String, in defaults: UserDefaults = .standard) {
            defaults.set(all(in: defaults).filter { $0 != line }, forKey: key)
        }

        static func clear(in defaults: UserDefaults = .standard) {
            defaults.removeObject(forKey: key)
        }

        /// A kept search taken apart again: the tags that still exist (by `known`, any case) and the text.
        static func parse(_ line: String, known: [String]) -> (tags: [String], text: String) {
            var tags: [String] = []
            var words: [String] = []
            for word in line.split(separator: " ").map(String.init) {
                if word.hasPrefix("#"), word.count > 1, let tag = known.first(where: { $0.caseInsensitiveCompare(String(word.dropFirst())) == .orderedSame }) {
                    tags.append(tag)
                } else {
                    words.append(word)
                }
            }
            return (tags, words.joined(separator: " "))
        }
    }
}
