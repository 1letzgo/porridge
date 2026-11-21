import Foundation

/// One entry as the chat sees it: its kind, dates, bowls, link and to-do state, and a short snippet. Kept next to
/// the entry's passages in the index (`NoteIndex`); derived from the note, never synced, rebuilt at any time.
/// The bowl names are not stored (a bowl may be renamed): they are looked up when a question is asked.
/// DESIGN.md "Chat data" describes the format.
struct ChatDocument: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case note, meeting, link, todo, image, file

        /// The name in the context the model reads.
        var label: String {
            switch self {
            case .note: "Note"
            case .meeting: "Meeting"
            case .link: "Link"
            case .todo: "To-do"
            case .image: "Image"
            case .file: "File"
            }
        }
    }

    let noteID: UUID
    let kind: Kind
    let title: String
    let createdAt: Date
    /// `Note.projectIDs`: empty is the Inbox.
    let bucketIDs: [String]
    let url: String?
    let domain: String?
    /// "open" or "done"; nil for everything that is not a to-do.
    let todoState: String?
    /// "yyyy-MM-dd" (`Todos.dueKey`); nil without a due day.
    let dueDay: String?
    let doneAt: Date?
    let subtasksDone: Int
    let subtasksTotal: Int
    let tags: [String]
    /// The start of the entry: its summary, else its text, its page or its transcript; at most 200 characters.
    let snippet: String
    // A document (`Note.isDocument`): what it is. Nil for everything else, and in index files from before.
    /// `DocumentKind` raw value.
    var documentKind: String?
    /// The date on the document, "yyyy-MM-dd".
    var documentDay: String?
    var correspondent: String?
    /// "119.00 EUR" (`DocumentInfo.amount`).
    var amount: String?

    static let snippetLength = 200

    init(note: Note) {
        noteID = note.id
        kind = note.isTodo ? .todo : note.isLink ? .link : note.isImage ? .image : note.isFile ? .file : note.isRecording ? .meeting : .note
        title = note.displayTitle
        createdAt = note.createdAt
        bucketIDs = note.projectIDs
        url = note.url
        domain = note.domain
        todoState = note.isTodo ? (note.isDone ? "done" : "open") : nil
        dueDay = note.todoDue
        doneAt = note.isDone ? note.todoDoneAt : nil
        let progress = note.todoProgress
        subtasksDone = progress.done
        subtasksTotal = progress.total
        tags = note.tags
        let sources = [note.summary ?? "", note.text, note.pageText ?? "", note.segments.prefix(20).map(\.text).joined(separator: " ")]
        var lines: [String] = []
        for source in sources where lines.isEmpty {
            // Headings ("## Summary") are left out before the marks are taken off.
            let withoutHeadings = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            lines = NoteText.plainLines(withoutHeadings.joined(separator: "\n"))
            // The first line of an untitled note is its title already.
            if note.title.trimmingCharacters(in: .whitespaces).isEmpty, source == note.text, lines.first == title { lines.removeFirst() }
        }
        let joined = lines.joined(separator: " ")
        snippet = joined.count > Self.snippetLength ? String(joined.prefix(Self.snippetLength - 1)) + "…" : joined
        if note.isDocument, let info = note.documentInfo {
            documentKind = (info.kind ?? .other).rawValue
            documentDay = info.day
            correspondent = info.correspondent
            amount = info.amount
        }
    }

    var documentInfo: DocumentInfo? {
        guard let documentKind else { return nil }
        return DocumentInfo(kind: DocumentKind(rawValue: documentKind), day: documentDay, correspondent: correspondent, amount: amount)
    }

    /// The date a question's time is about for an entry that is not a to-do: the date on a document, else when it came in.
    var date: Date { DocumentInfo.date(fromDay: documentDay) ?? createdAt }

    var isOpenTodo: Bool { todoState == "open" }
    var isDoneTodo: Bool { todoState == "done" }

    /// "17 Nov 2026 (Tue)": the same in every language, so the model reads it the same way.
    static func dayText(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM yyyy"
        return formatter.string(from: date)
    }

    /// The line that introduces the entry to the model:
    /// `«Title» — To-do, open, due 12 December 2026, overdue, 1 of 3 subtasks done · created Tue 17 Nov 2026 · Bowl: Travel`
    /// and for a link `«Title» — Link (example.com) · created … · Inbox · https://example.com/a`.
    func header(bucketNames: [String: String], now: Date = Date(), calendar: Calendar = .current) -> String {
        var kindText = kind.label
        if kind == .link, let domain { kindText += " (\(domain))" }
        if let todoState {
            kindText += ", " + todoState
            if todoState == "done", let doneAt { kindText += " on " + Self.dayText(doneAt, calendar: calendar) }
            if let dueDay {
                kindText += ", due " + Todos.dueText(dueDay)
                if todoState == "open", Todos.dueStatus(dueDay, now: now, calendar: calendar) == .overdue { kindText += ", overdue" }
            }
            if subtasksTotal > 0 { kindText += ", \(subtasksDone) of \(subtasksTotal) subtasks done" }
        }
        var parts = [kindText]
        // "Document: Invoice from Telekom, dated 2 Mar 2026, amount 119,00 €".
        if let info = documentInfo { parts.append("Document: " + info.sentence) }
        parts.append("created " + Self.dayText(createdAt, calendar: calendar))
        let names = bucketIDs.compactMap { bucketNames[$0] }
        parts.append(names.isEmpty ? "Inbox" : (names.count == 1 ? "Bowl: " : "Bowls: ") + names.joined(separator: ", "))
        if !tags.isEmpty { parts.append(tags.map { "#" + $0 }.joined(separator: " ")) }
        if let url { parts.append(url) }
        return "«\(title)» — " + parts.joined(separator: " · ")
    }
}

// MARK: - The question as filters

/// What a question asks for beyond its words: a kind of entry, a bowl, the state of a to-do, a time. Read from the
/// question by fixed word lists (German and English); the words it was read from are not searched for.
struct ChatQuery: Equatable {
    enum TodoFilter: String { case open, done, overdue }
    /// Which date of an entry the time is about.
    enum DateField: String { case created, due, done, auto }

    var kinds: Set<ChatDocument.Kind> = []
    var bucketIDs: Set<String> = []
    /// "Inbox": entries in no bowl.
    var inbox = false
    var todo: TodoFilter?
    var range: DateInterval?
    var dateField: DateField = .auto
    /// The words left to search for.
    var words: [String] = []
    /// Documents of these kinds only ("Rechnungen", "contracts").
    var documentKinds: Set<DocumentKind> = []
    /// Documents from these senders only, by `DocumentExtractor.correspondentKey`.
    var senders: Set<String> = []
    /// Documents with an amount of at least / at most this much ("über 100 Euro", "under $50").
    var minAmount: Decimal?
    var maxAmount: Decimal?

    var isStructured: Bool {
        !kinds.isEmpty || !bucketIDs.isEmpty || inbox || todo != nil || range != nil || isAboutDocuments
    }

    var isAboutDocuments: Bool { !documentKinds.isEmpty || !senders.isEmpty || minAmount != nil || maxAmount != nil }

    // Word lists. A word counts as a whole word of the question, hyphens kept ("to-dos").
    static let kindWords: [ChatDocument.Kind: Set<String>] = [
        .todo: ["todo", "todos", "to-do", "to-dos", "aufgabe", "aufgaben", "task", "tasks", "todo-liste", "to-do-liste", "todo-list", "to-do-list"],
        .link: ["link", "links", "lesezeichen", "bookmark", "bookmarks", "artikel", "article", "articles", "webseite", "webseiten", "website", "websites"],
        .meeting: ["meeting", "meetings", "besprechung", "besprechungen", "aufnahme", "aufnahmen", "recording", "recordings", "transkript", "transkripte", "transcript", "transcripts", "call", "calls", "telefonat", "telefonate"],
        .image: ["bild", "bilder", "foto", "fotos", "image", "images", "photo", "photos", "screenshot", "screenshots"],
        .file: ["datei", "dateien", "file", "files", "pdf", "pdfs", "dokument", "dokumente", "document", "documents"],
    ]
    static let openWords: Set<String> = ["offen", "offene", "offenen", "offener", "open", "unerledigt", "unerledigte", "unerledigten", "ausstehend", "ausstehende", "pending", "anstehend", "anstehende"]
    static let doneWords: Set<String> = ["erledigt", "erledigte", "erledigten", "done", "completed", "finished", "abgehakt", "abgehakte", "abgeschlossen", "abgeschlossene", "geschafft"]
    static let overdueWords: Set<String> = ["überfällig", "überfällige", "überfälligen", "overdue", "verspätet", "late"]
    static let dueWords: Set<String> = ["fällig", "fällige", "fälligen", "due", "deadline", "deadlines", "frist", "fristen"]
    static let bucketWords: Set<String> = ["bowl", "bowls", "bucket", "buckets"]
    /// Kind words that mean something else in a question: "a brief answer", "notice", "a statement", "quote".
    static let ambiguousDocumentWords: Set<String> = ["brief", "notice", "statement", "quote", "bill", "police", "policy", "schreiben", "bescheid", "bon", "auszug", "other", "andere", "anderes"]
    static let senderWords: Set<String> = ["von", "vom", "from", "absender", "sender"]
    static let moreWords = ["über", "mehr als", "ab", "over", "more than", "above", "at least", "mindestens"]
    static let lessWords = ["unter", "weniger als", "höchstens", "under", "less than", "below", "at most"]
    static let currencyWords: Set<String> = ["€", "euro", "eur", "$", "dollar", "usd", "chf", "franken", "£", "pfund", "gbp"]
    static let weekdays: [String: Int] = [
        "sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonnabend": 7,
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]

    /// The words of a question with hyphens kept, lowercased.
    static func words(_ question: String) -> [String] {
        question.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
            .filter { !$0.isEmpty }
    }

    /// Reads the filters of `question`. `bowls` are the names a question may name (`Projects.key` → name).
    /// `senders` are the senders of the documents a question may name ("Telekom").
    static func parse(_ question: String, buckets: [String: String] = [:], senders: [String] = [], now: Date = Date(), calendar: Calendar = .current) -> ChatQuery {
        var query = ChatQuery()
        let all = words(question)
        var used = Set<Int>()
        func take(_ index: Int) { used.insert(index) }

        for (index, word) in all.enumerated() {
            for (kind, list) in kindWords where list.contains(word) {
                query.kinds.insert(kind)
                take(index)
            }
            if openWords.contains(word) { query.todo = query.todo ?? .open; take(index) }
            if doneWords.contains(word) { query.todo = .done; take(index) }
            if overdueWords.contains(word) { query.todo = .overdue; take(index) }
            if dueWords.contains(word) { query.dateField = .due; take(index) }
            if bucketWords.contains(word) { take(index) }
            if word == "inbox" { query.inbox = true; take(index) }
            if !ambiguousDocumentWords.contains(word), let kind = DocumentKind.named(word), kind != .other {
                query.documentKinds.insert(kind)
                take(index)
            }
        }

        // A sender named in the question: its whole name ("Telekom Deutschland"), or its first word when that is
        // distinctive ("Telekom" for "Telekom Deutschland GmbH").
        for name in senders {
            let key = DocumentExtractor.correspondentKey(name).split(separator: " ").map(String.init)
            guard let head = key.first else { continue }
            let foldedWords = all.map { DocumentExtractor.correspondentKey($0) }
            var found: [Int]?
            if key.count <= foldedWords.count {
                for start in 0...(foldedWords.count - key.count) where Array(foldedWords[start..<start + key.count]) == key {
                    found = Array(start..<start + key.count)
                    break
                }
            }
            if found == nil, head.count >= 4, !genericSenderWords.contains(head), let index = foldedWords.firstIndex(of: head) {
                found = [index]
            }
            guard let found else { continue }
            query.senders.insert(key.joined(separator: " "))
            found.forEach(take)
            if let first = found.first, first > 0, senderWords.contains(all[first - 1]) { take(first - 1) }
        }

        // An amount: "über 100 Euro", "mehr als 50 €", "under $20".
        for (i, word) in all.enumerated() {
            guard let value = Decimal(string: word.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX")),
                  word.allSatisfy({ $0.isNumber || $0 == "," || $0 == "." }) else { continue }
            let hasCurrency = (i + 1 < all.count && currencyWords.contains(all[i + 1])) || question.contains("€\(word)") || question.contains("$\(word)")
                || question.contains("\(word) €") || question.contains("\(word)€") || question.contains("\(word) $")
            guard hasCurrency else { continue }
            func before(_ phrases: [String]) -> Int? {
                for phrase in phrases {
                    let parts = phrase.split(separator: " ").map(String.init)
                    guard i >= parts.count, Array(all[(i - parts.count)..<i]) == parts else { continue }
                    return parts.count
                }
                return nil
            }
            if let length = before(moreWords) {
                query.minAmount = value
                ((i - length)...i).forEach(take)
            } else if let length = before(lessWords) {
                query.maxAmount = value
                ((i - length)...i).forEach(take)
            } else {
                continue
            }
            if i + 1 < all.count, currencyWords.contains(all[i + 1]) { take(i + 1) }
        }

        // A bowl named in the question, by its whole name ("Reisen", "Haus und Garten").
        for (id, name) in buckets {
            let nameWords = words(name)
            guard !nameWords.isEmpty, nameWords.count <= all.count else { continue }
            for start in 0...(all.count - nameWords.count) where Array(all[start..<start + nameWords.count]) == nameWords {
                query.bucketIDs.insert(id)
                (start..<start + nameWords.count).forEach(take)
            }
        }

        if let (range, consumed) = timeRange(all, question: question, future: query.dateField == .due || query.todo == .open, now: now, calendar: calendar) {
            query.range = range
            consumed.forEach(take)
        }

        // A due day or a to-do state is about to-dos.
        if query.dateField == .due || query.todo == .overdue { query.kinds.insert(.todo) }
        if query.todo != nil, query.kinds.isEmpty { query.kinds.insert(.todo) }
        // A list of to-dos is a list of what is still open, unless done ones are asked for.
        if query.kinds == [.todo], query.todo == nil { query.todo = .open }
        if query.todo == .done, query.range != nil, query.dateField == .auto { query.dateField = .done }
        // A question about documents names a year as the time of the documents ("Rechnungen 2026").
        if query.range == nil, query.isAboutDocuments, let (range, consumed) = yearRange(all, calendar: calendar) {
            query.range = range
            consumed.forEach(take)
        }

        let rest = all.enumerated().filter { !used.contains($0.offset) }.map(\.element).joined(separator: " ")
        var seen = Set<String>()
        query.words = ChatRetrieval.queryWords(rest).filter { seen.insert($0).inserted }
        return query
    }

    /// Senders' first words that name no one in particular.
    static let genericSenderWords: Set<String> = ["deutsche", "deutscher", "german", "stadt", "bank", "first", "erste", "allgemeine", "volks"]

    /// A year named in a question ("2026", "aus 2025") as the span of that year, and the index of its word.
    static func yearRange(_ words: [String], calendar: Calendar) -> (DateInterval, [Int])? {
        for (i, word) in words.enumerated() where word.count == 4 {
            guard let year = Int(word), (1950...2200).contains(year),
                  let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { continue }
            return (DateInterval(start: start, end: end), [i])
        }
        return nil
    }

    /// The time a question names, as a span of days, and the indices of the words it was read from. `future` reads a
    /// weekday as the next one (a due day), otherwise as the last one ("the meeting on Tuesday").
    static func timeRange(_ words: [String], question: String, future: Bool, now: Date, calendar: Calendar) -> (DateInterval, [Int])? {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        func days(_ from: Int, _ to: Int) -> DateInterval { DateInterval(start: day(from), end: day(to)) }
        let weekday = calendar.component(.weekday, from: today)
        let monday = -((weekday + 5) % 7)
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        func month(_ offset: Int) -> DateInterval {
            let start = calendar.date(byAdding: .month, value: offset, to: thisMonth) ?? thisMonth
            return DateInterval(start: start, end: calendar.date(byAdding: .month, value: 1, to: start) ?? start)
        }
        func index(of phrase: String) -> [Int]? {
            let parts = phrase.split(separator: " ").map(String.init)
            guard parts.count <= words.count else { return nil }
            for start in 0...(words.count - parts.count) where Array(words[start..<start + parts.count]) == parts {
                return Array(start..<start + parts.count)
            }
            return nil
        }
        func first(_ phrases: [String]) -> [Int]? {
            for phrase in phrases { if let found = index(of: phrase) { return found } }
            return nil
        }

        // A date written out: "17.11.", "17.11.2026", "2026-11-17".
        let text = question as NSString
        let patterns = [#"\b(\d{4})-(\d{2})-(\d{2})\b"#, #"\b(\d{1,2})\.(\d{1,2})\.(\d{2,4})?"#]
        for (number, pattern) in patterns.enumerated() {
            guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: question, range: NSRange(location: 0, length: text.length)) else { continue }
            func value(_ group: Int) -> Int? {
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : Int(text.substring(with: range))
            }
            var parts = number == 0 ? (value(1), value(2), value(3)) : (value(3), value(2), value(1))
            if let year = parts.0, year < 100 { parts.0 = 2000 + year }
            let year = parts.0 ?? calendar.component(.year, from: today)
            if let month = parts.1, let dayOfMonth = parts.2,
               let start = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) {
                let consumed = words.indices.filter { words[$0].allSatisfy { $0.isNumber } }
                return (DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start), consumed)
            }
        }

        // "der letzten 3 Tage", "last two weeks", "next 5 days"
        let numbers: [String: Int] = [
            "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10,
            "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        ]
        let ahead: Set<String> = ["nächsten", "nächste", "kommenden", "kommende", "next", "coming"]
        for (i, word) in words.enumerated() where i + 1 < words.count {
            guard let count = Int(word) ?? numbers[word], count > 0, count < 1000 else { continue }
            let unit = words[i + 1]
            let forward = i > 0 && ahead.contains(words[i - 1])
            let length: Int
            if ["tag", "tage", "tagen", "day", "days"].contains(unit) { length = count }
            else if ["woche", "wochen", "week", "weeks"].contains(unit) { length = 7 * count }
            else if ["monat", "monate", "monaten", "month", "months"].contains(unit) { length = 30 * count }
            else { continue }
            let lead: Set<String> = ahead.union(["letzten", "letzte", "vergangenen", "last", "past"])
            let consumed = (i > 0 && lead.contains(words[i - 1]) ? [i - 1] : []) + [i, i + 1]
            return (forward ? days(0, length + 1) : days(-length, 1), consumed)
        }

        let table: [([String], DateInterval)] = [
            (["übermorgen", "day after tomorrow"], days(2, 3)),
            (["vorgestern", "day before yesterday"], days(-2, -1)),
            (["heute", "today", "tonight"], days(0, 1)),
            (["gestern", "yesterday"], days(-1, 0)),
            (["morgen", "tomorrow"], days(1, 2)),
            (["nächste woche", "nächsten woche", "kommende woche", "kommenden woche", "next week", "coming week"], days(monday + 7, monday + 14)),
            (["letzte woche", "letzten woche", "letzter woche", "vergangene woche", "vergangenen woche", "last week", "past week"], days(monday - 7, monday)),
            (["diese woche", "dieser woche", "diesen woche", "this week"], days(monday, monday + 7)),
            (["nächsten monat", "nächster monat", "kommenden monat", "next month"], month(1)),
            (["letzten monat", "letzter monat", "letzte monat", "vergangenen monat", "last month", "past month"], month(-1)),
            (["diesen monat", "diesem monat", "dieser monat", "this month"], month(0)),
            ([
                "letzten tage", "letzte tage", "letzten tagen", "vergangenen tage", "vergangenen tagen", "paar tage", "paar tagen",
                "letzter zeit", "letzten zeit", "kürzlich", "neulich", "zuletzt",
                "last days", "last few days", "past days", "past few days", "recent", "recently", "lately",
            ], days(-7, 1)),
        ]
        for (phrases, range) in table {
            if let consumed = first(phrases) { return (range, consumed) }
        }

        // "am Dienstag", "on Friday": the last such day, or the next one for a due day.
        for (i, word) in words.enumerated() {
            guard let target = weekdays[word] else { continue }
            let back = (weekday - target + 7) % 7
            let offset = future ? (target - weekday + 7) % 7 : -back
            var consumed = [i]
            if i > 0, ["am", "on", "letzten", "last", "nächsten", "next", "diesen", "this"].contains(words[i - 1]) { consumed.insert(i - 1, at: 0) }
            return (days(offset, offset + 1), consumed)
        }
        return nil
    }

    /// Whether an entry is one the question asks for.
    func matches(_ document: ChatDocument, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if !kinds.isEmpty, !kinds.contains(document.kind) { return false }
        if isAboutDocuments {
            guard let info = document.documentInfo else { return false }
            if !documentKinds.isEmpty, !documentKinds.contains(info.kind ?? .other) { return false }
            if !senders.isEmpty {
                guard let sender = info.correspondent else { return false }
                let key = DocumentExtractor.correspondentKey(sender)
                // "Telekom" asks for "Telekom Deutschland" too.
                guard senders.contains(where: { key == $0 || key.hasPrefix($0 + " ") }) else { return false }
            }
            if minAmount != nil || maxAmount != nil {
                guard let value = DocumentInfo.parts(ofAmount: info.amount)?.value else { return false }
                if let minAmount, value < minAmount { return false }
                if let maxAmount, value > maxAmount { return false }
            }
        }
        if !bucketIDs.isEmpty || inbox {
            let inBucket = !bucketIDs.isDisjoint(with: document.bucketIDs)
            let inInbox = inbox && document.bucketIDs.isEmpty
            if !inBucket, !inInbox { return false }
        }
        if document.kind == .todo, let todo {
            switch todo {
            case .open: if !document.isOpenTodo { return false }
            case .done: if !document.isDoneTodo { return false }
            case .overdue:
                guard document.isOpenTodo, let due = document.dueDay, Todos.dueStatus(due, now: now, calendar: calendar) == .overdue else { return false }
            }
        }
        if let range {
            let due = document.dueDay.flatMap { Todos.dueDate($0, calendar: calendar) }
            let date: Date?
            switch dateField {
            case .due: date = due
            case .done: date = document.doneAt
            case .created: date = document.createdAt
            // A document by the date on it.
            case .auto: date = document.kind == .todo ? (due ?? document.createdAt) : document.date
            }
            guard let date, date >= range.start, date < range.end else { return false }
        }
        return true
    }

    /// The filters in words, for the model: "kind: to-do; state: open; due between Mon 16 Nov 2026 and Sun 22 Nov 2026".
    func describe(bucketNames: [String: String], calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if !kinds.isEmpty { parts.append("kind: " + ChatDocument.Kind.allCases.filter(kinds.contains).map { $0.label.lowercased() }.joined(separator: " or ")) }
        if let todo { parts.append("to-do state: " + todo.rawValue) }
        if !documentKinds.isEmpty {
            parts.append("document kind: " + DocumentKind.allCases.filter(documentKinds.contains).map { $0.title.lowercased() }.joined(separator: " or "))
        }
        if !senders.isEmpty { parts.append("from: " + senders.sorted().joined(separator: " or ")) }
        if let minAmount { parts.append("amount at least \(minAmount)") }
        if let maxAmount { parts.append("amount at most \(maxAmount)") }
        let names = bucketIDs.compactMap { bucketNames[$0] }.sorted() + (inbox ? ["Inbox"] : [])
        if !names.isEmpty { parts.append("in " + names.joined(separator: " or ")) }
        if let range {
            let last = calendar.date(byAdding: .day, value: -1, to: range.end) ?? range.end
            let field = switch dateField {
            case .due: "due"
            case .done: "done"
            case .created: "created"
            case .auto: kinds == [.todo] ? "due (or created, without a due day)" : isAboutDocuments ? "dated (the date on the document)" : "created"
            }
            let from = ChatDocument.dayText(range.start, calendar: calendar), to = ChatDocument.dayText(last, calendar: calendar)
            parts.append(field + (from == to ? " on " + from : " between " + from + " and " + to))
        }
        return parts.joined(separator: "; ")
    }
}

// MARK: - The context of a question

/// One numbered item the model reads: an entry of the list of matches (`isListing`), or a passage of an entry.
struct ChatContextItem {
    let noteID: UUID
    let title: String
    let date: Date
    let header: String
    let text: String
    let isListing: Bool
    /// A passage of an entry outside the filters, offered because nothing inside them had the words.
    let isOutside: Bool
}

struct ChatContext {
    var items: [ChatContextItem] = []
    /// How many entries match the filters; nil for a question without filters.
    var matched: Int?
    /// The filters in words (`ChatQuery.describe`).
    var filter = ""
    /// The question had words to search for, but no passage had them: the newest entries stand in, and an answer
    /// that cites none of them gets no sources (`ChatService.sources`).
    var wordsNotFound = false
    var query = ChatQuery()

    var isEmpty: Bool { items.isEmpty }
}

/// How much context a model gets. The Apple model has little room; a cloud model has a lot.
struct ChatBudget: Equatable {
    /// At most this many entries are listed for a question with filters; the model is told when there are more.
    var listLimit: Int
    /// Passages of the matching entries fill the context up to this many characters.
    var fillBudget: Int
    /// Passages of entries outside the filters, when no match has the question's words.
    var outsideBudget: Int
    /// Passages for a question without filters: this many characters, at most `maxPassages`.
    var searchBudget: Int
    var maxPassages: Int
    /// The whole prompt is cut at this many characters (`ChatService.prompt`).
    var promptLimit: Int

    /// On-device models other than Apple's.
    static let standard = ChatBudget(listLimit: 40, fillBudget: 6500, outsideBudget: 3000, searchBudget: 6500, maxPassages: 10, promptLimit: .max)
    /// The Apple model: the same passages, the prompt cut at 7000 characters.
    static let small = ChatBudget(listLimit: 40, fillBudget: 6500, outsideBudget: 3000, searchBudget: 6500, maxPassages: 10, promptLimit: 7000)
    /// Cloud models: about three times the room (well within their context windows, and a few cents per question).
    static let large = ChatBudget(listLimit: 100, fillBudget: 20000, outsideBudget: 8000, searchBudget: 20000, maxPassages: 30, promptLimit: 100_000)

    static func `for`(_ model: SummaryModel) -> ChatBudget {
        switch model {
        case .local(let local): local == .apple ? .small : .standard
        case .cloud: .large
        }
    }
}

extension ChatRetrieval {
    /// The context a question is answered from. With filters (a kind, a bowl, a to-do state, a time), every
    /// matching entry is listed (up to `listLimit`), then the passages of the matches that have the question's
    /// words, then further passages of the first matches; when no match has the words, the best passages of all
    /// entries follow, marked as outside. Without filters, the best passages of all entries (`select`).
    static func context(
        _ question: String, documents: [UUID: ChatDocument], chunks: [ChatChunk], bucketNames: [String: String],
        queryVector: [Float]? = nil, now: Date = Date(), calendar: Calendar = .current, budget: ChatBudget = .standard
    ) -> ChatContext {
        let senders = Array(Set(documents.values.compactMap(\.correspondent)))
        let query = ChatQuery.parse(question, buckets: bucketNames, senders: senders, now: now, calendar: calendar)
        var context = ChatContext(query: query)
        func item(_ chunk: ChatChunk, outside: Bool = false) -> ChatContextItem? {
            guard let document = documents[chunk.noteID] else { return nil }
            return ChatContextItem(
                noteID: chunk.noteID, title: document.title, date: document.createdAt,
                header: document.header(bucketNames: bucketNames, now: now, calendar: calendar),
                text: chunk.text, isListing: false, isOutside: outside
            )
        }

        guard query.isStructured else {
            let picked = selection(question, in: chunks, queryVector: queryVector, now: now, calendar: calendar, budget: budget.searchBudget, limit: budget.maxPassages)
            context.items = picked.chunks.compactMap { item($0) }
            context.wordsNotFound = picked.isNewest && !queryWords(question).isEmpty
            return context
        }

        context.filter = query.describe(bucketNames: bucketNames, calendar: calendar)
        var matches = order(documents.values.filter { query.matches($0, now: now, calendar: calendar) }, todosFirst: query.kinds.contains(.todo) || query.todo != nil)
        context.matched = matches.count
        // With words to search for as well ("links about Swift"), the list stays complete, but the entries that
        // have the words come first (most words first) and say which.
        var mentions: [UUID: [String]] = [:]
        if !query.words.isEmpty {
            let byNote = Dictionary(grouping: chunks, by: \.noteID)
            for document in matches {
                let hits = query.words.filter { word in byNote[document.noteID]?.contains { frequency(word, $0) > 0 } ?? false }
                if !hits.isEmpty { mentions[document.noteID] = hits }
            }
            let rank = Dictionary(uniqueKeysWithValues: matches.enumerated().map { ($1.noteID, $0) })
            matches.sort { a, b in
                let x = mentions[a.noteID]?.count ?? 0, y = mentions[b.noteID]?.count ?? 0
                return x != y ? x > y : rank[a.noteID]! < rank[b.noteID]!
            }
        }
        guard !matches.isEmpty else {
            // Nothing is what the filters ask: the best passages of all entries, marked so.
            let picked = search(words: query.words, in: chunks, queryVector: queryVector, budget: budget.searchBudget, limit: budget.maxPassages)
            context.items = picked.compactMap { item($0, outside: true) }
            return context
        }

        for document in matches.prefix(budget.listLimit) {
            context.items.append(ChatContextItem(
                noteID: document.noteID, title: document.title, date: document.createdAt,
                header: document.header(bucketNames: bucketNames, now: now, calendar: calendar),
                text: document.snippet + (mentions[document.noteID].map { (document.snippet.isEmpty ? "" : " — ") + "mentions: " + $0.joined(separator: ", ") } ?? ""),
                isListing: true, isOutside: false
            ))
        }

        let ids = Set(matches.map(\.noteID))
        let inside = chunks.filter { ids.contains($0.noteID) }
        var used = 0
        var taken = Set<String>()
        func add(_ chunk: ChatChunk) {
            guard taken.insert(chunk.noteID.uuidString + chunk.text).inserted, let next = item(chunk) else { return }
            context.items.append(next)
            used += chunk.text.count
        }
        // The list lines carry title, link, files and to-do state: only passages with content take places here.
        let found = query.words.isEmpty ? [] : search(words: query.words, in: inside.filter(\.part.fillsContext), queryVector: queryVector, budget: budget.searchBudget, limit: budget.maxPassages)
        found.forEach(add)
        // The first matches with more of what they hold: a few entries get many passages, many entries a few.
        let perEntry = matches.count <= 2 ? 12 : matches.count <= 5 ? 4 : 2
        let byNote = Dictionary(grouping: inside, by: \.noteID)
        fill: for document in matches.prefix(8) {
            var count = 0
            for chunk in byNote[document.noteID] ?? [] where chunk.part.fillsContext {
                if count >= perEntry { break }
                if used + chunk.text.count > budget.fillBudget { break fill }
                add(chunk)
                count += 1
            }
        }
        if !query.words.isEmpty, found.isEmpty {
            let outside = search(words: query.words, in: chunks.filter { !ids.contains($0.noteID) }, queryVector: queryVector, budget: budget.outsideBudget, limit: budget.maxPassages)
            context.items += outside.compactMap { item($0, outside: true) }
        }
        return context
    }

    /// Open to-dos by due day (undated last), then done ones by when they were done, the rest newest first;
    /// to-dos first when the question is about them.
    static func order(_ documents: [ChatDocument], todosFirst: Bool) -> [ChatDocument] {
        let todos = documents.filter { $0.kind == .todo }.sorted { a, b in
            if a.isOpenTodo != b.isOpenTodo { return a.isOpenTodo }
            if a.isOpenTodo {
                switch (a.dueDay, b.dueDay) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.createdAt > b.createdAt
                }
            }
            return (a.doneAt ?? a.createdAt) > (b.doneAt ?? b.createdAt)
        }
        let others = documents.filter { $0.kind != .todo }.sorted { $0.createdAt > $1.createdAt }
        return todosFirst ? todos + others : others + todos
    }
}
