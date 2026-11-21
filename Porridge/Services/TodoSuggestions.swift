import Foundation
import SwiftData

/// One task of a summary offered as a to-do: "Send the offer – Anna – 2026-11-28" becomes the title, the person
/// responsible and the due day.
struct TaskSuggestion: Equatable, Identifiable {
    /// The task's words, normalized (`TodoSuggestions.key`): what "the same task" means across summaries.
    var key: String
    var title: String
    var owner: String?
    /// "yyyy-MM-dd" when the summary names a date that resolves to one day; nil otherwise (nothing is guessed).
    var dueDay: String?
    /// Index of the line in the summary.
    var line: Int
    /// The task is the user's (its owner is one of the user's names) or nobody's.
    var isMine: Bool

    var id: String { key }
}

/// To-dos suggested from the tasks of a summary (a meeting's or a note's). Nothing becomes a to-do without a tap:
/// the meeting's page offers them, the user picks and takes them on, or dismisses them. What happened to each task
/// is kept on the meeting (`Note.todoSuggestionsRaw`) so it is the same on every device.
enum TodoSuggestions {
    static let taken = "taken"
    static let dismissed = "dismissed"

    // MARK: Reading the tasks

    /// The open tasks of a summary as suggestions, in their order, each task once.
    static func parse(_ summary: String, meetingDate: Date, calendar: Calendar = .current, myNames: [String] = AppSettings.myNames) -> [TaskSuggestion] {
        var seen = Set<String>()
        return SummaryTasks.parse(summary).compactMap { task in
            guard !task.done else { return nil }
            let parts = split(task.text, meetingDate: meetingDate, calendar: calendar)
            let key = key(parts.title)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            // Nobody's task counts as the user's; "Anna and Ben" is the user's when one of them is.
            let mine = parts.owner.map { owner in
                owner.replacingOccurrences(of: #"\s+(and|und|et|y|e|en|i)\s+"#, with: ",", options: [.regularExpression, .caseInsensitive])
                    .split(whereSeparator: { ",&/".contains($0) })
                    .contains { AppSettings.isMe(String($0), names: myNames) }
            } ?? true
            return TaskSuggestion(key: key, title: parts.title, owner: parts.owner, dueDay: parts.dueDay, line: task.line, isMine: mine)
        }
    }

    /// "Send the offer – Anna – 2026-11-28": the task, then the owner and the due date in any order, each optional.
    /// Parts are split at a dash with spaces around it (–, — or -). Placeholders ("n/a", "–", "unknown") are no owner.
    static func split(_ text: String, meetingDate: Date, calendar: Calendar = .current) -> (title: String, owner: String?, dueDay: String?) {
        var parts = text.components(separatedBy: " – ").flatMap { $0.components(separatedBy: " — ") }
        if parts.count == 1 { parts = text.components(separatedBy: " - ") }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }
        let title = cleanTitle(parts.first ?? text)
        var owner: String?
        var due: String?
        for part in parts.dropFirst() {
            let cleaned = part.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]*_.,;–—-"))
            guard !cleaned.isEmpty, !isPlaceholder(cleaned) else { continue }
            // The date read before the dots are trimmed: "28.11." keeps its last one.
            let dateText = part.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]*_,;–—-"))
            if due == nil, let day = dueDay(from: dateText, meetingDate: meetingDate, calendar: calendar) {
                due = day
            } else if owner == nil, !containsDigit(cleaned) {
                owner = cleaned.replacingOccurrences(of: #"^(owner|verantwortlich|zuständig|wer)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            }
        }
        // Small models copy the meeting's own date into every task: that day counts only for a task due "today".
        let meetingDay = Todos.dueKey(meetingDate, calendar: calendar)
        if due == meetingDay, !saysToday(title) { due = nil }
        // A deadline in the task's own words ("… bis zum 3. Dezember"). Read strictly: "Pick 2 out of 5" is no October.
        if due == nil, let inTitle = dueDay(from: title, meetingDate: meetingDate, calendar: calendar, strict: true),
           inTitle != meetingDay || saysToday(title) {
            due = inTitle
        }
        return (title, owner, due)
    }

    private static let todayWords = ["today", "heute", "aujourd", "hoy", "oggi", "vandaag", "hoje", "dzisiaj", "dziś"]

    private static func saysToday(_ text: String) -> Bool {
        let lower = text.lowercased()
        return todayWords.contains { lower.contains($0) }
    }

    private static func cleanTitle(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "–—-:")))
    }

    private static func containsDigit(_ text: String) -> Bool { text.contains(where: \.isNumber) }

    private static let placeholders: Set<String> = [
        "-", "–", "—", "?", "n/a", "na", "none", "unknown", "tbd", "tba", "not named", "not specified", "unassigned", "nobody",
        "keine", "keiner", "niemand", "unbekannt", "offen", "nicht genannt", "nicht festgelegt", "k.a.", "ka", "ohne",
        "aucun", "inconnu", "ninguno", "nessuno", "geen", "nenhum", "brak",
    ]

    private static func isPlaceholder(_ text: String) -> Bool {
        let lower = text.lowercased()
        return placeholders.contains(lower) || lower.hasPrefix("<") || lower.hasPrefix("owner") && lower.count <= 6
            || lower.contains("if known") || lower.contains("if named") || lower.contains("falls")
    }

    // MARK: Dates

    /// The day a due date names, as "yyyy-MM-dd", only when it is a date: "2026-11-28", "28.11.2026", "28.11.",
    /// "28 November", "November 28, 2026", "28. Nov". A day without a year is the first such day on or after the
    /// meeting. Words like "next Friday" or "end of the month" give nothing: the summary is asked to write them as
    /// dates, and nothing is guessed. `strict` is for free text (a task's own words): a month that is also a common
    /// word ("out", "set", "may", "mar") counts only with a marked day ("2.", "2nd") or a year next to it.
    static func dueDay(from text: String, meetingDate: Date, calendar: Calendar = .current, strict: Bool = false) -> String? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        func int(_ m: NSTextCheckingResult, _ i: Int) -> Int? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
        }
        if let m = iso.firstMatch(in: text, range: whole), let y = int(m, 1), let mo = int(m, 2), let d = int(m, 3) {
            return day(y, mo, d, calendar: calendar)
        }
        if let m = dotted.firstMatch(in: text, range: whole), let d = int(m, 1), let mo = int(m, 2) {
            let y = int(m, 3).map { $0 < 100 ? 2000 + $0 : $0 }
            return resolve(year: y, month: mo, day: d, meetingDate: meetingDate, calendar: calendar)
        }
        func marked(_ m: NSTextCheckingResult, _ i: Int) -> Bool { m.range(at: i).length > 0 }
        for m in dayMonth.matches(in: text, range: whole) {
            let word = ns.substring(with: m.range(at: 3))
            if strict, isAmbiguousMonth(word), !marked(m, 2), !marked(m, 4) { continue }
            if let d = int(m, 1), let mo = month(word) {
                return resolve(year: int(m, 4), month: mo, day: d, meetingDate: meetingDate, calendar: calendar)
            }
        }
        for m in monthDay.matches(in: text, range: whole) {
            let word = ns.substring(with: m.range(at: 1))
            if strict, isAmbiguousMonth(word), !marked(m, 2), !marked(m, 4), !marked(m, 5) { continue }
            if let d = int(m, 3), let mo = month(word) {
                return resolve(year: int(m, 5), month: mo, day: d, meetingDate: meetingDate, calendar: calendar)
            }
        }
        return nil
    }

    private static func re(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: .caseInsensitive) }
    private static let iso = re(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#)
    private static let dotted = re(#"(?<![\d.])(\d{1,2})\.(\d{1,2})\.(\d{4}|\d{2})?(?![\d])"#)
    /// Day, its mark ("2nd", "2."), month, year.
    private static let dayMonth = re(#"(?<!\d)(\d{1,2})((?:st|nd|rd|th|er|º)?\.?)\s+(?:de\s+)?(\p{L}{3,})\.?(?:\s+(?:de\s+)?(\d{4}))?"#)
    /// Month, its dot, day, the day's mark, year.
    private static let monthDay = re(#"(\p{L}{3,})(\.?)\s+(\d{1,2})(st|nd|rd|th)?\b,?(?:\s+(\d{4}))?"#)

    /// Month names and their usual short forms in the languages of the summaries.
    private static let months: [(Int, [String])] = [
        (1, ["january", "jan", "januar", "jänner", "janvier", "janv", "enero", "ene", "gennaio", "gen", "januari", "janeiro", "stycznia", "styczeń"]),
        (2, ["february", "feb", "februar", "février", "févr", "fevrier", "febrero", "febbraio", "februari", "fevereiro", "fev", "lutego", "luty"]),
        (3, ["march", "mar", "märz", "maerz", "mrz", "mars", "marzo", "maart", "mrt", "março", "marca", "marzec"]),
        (4, ["april", "apr", "avril", "avr", "abril", "abr", "aprile", "kwietnia", "kwiecień"]),
        (5, ["may", "mai", "mayo", "maggio", "mag", "mei", "maio", "maja", "maj"]),
        (6, ["june", "jun", "juni", "juin", "junio", "giugno", "giu", "junho", "czerwca", "czerwiec"]),
        (7, ["july", "jul", "juli", "juillet", "juil", "julio", "luglio", "lug", "julho", "lipca", "lipiec"]),
        (8, ["august", "aug", "août", "aout", "agosto", "ago", "augustus", "sierpnia", "sierpień"]),
        (9, ["september", "sep", "sept", "septembre", "septiembre", "settembre", "set", "setembro", "września", "wrzesień"]),
        (10, ["october", "oct", "oktober", "okt", "octobre", "octubre", "ottobre", "ott", "outubro", "out", "października", "październik"]),
        (11, ["november", "nov", "novembre", "noviembre", "novembro", "listopada", "listopad"]),
        (12, ["december", "dec", "dezember", "dez", "décembre", "déc", "decembre", "diciembre", "dic", "dicembre", "dezembro", "grudnia", "grudzień"]),
    ]

    /// Month names and short forms that are also everyday words in the summaries' languages.
    private static let ambiguousMonths: Set<String> = ["out", "set", "sept", "ago", "gen", "mag", "may", "mai", "mar", "mars", "lug", "dez"]

    private static func isAmbiguousMonth(_ word: String) -> Bool { ambiguousMonths.contains(word.lowercased()) }

    private static func month(_ word: String) -> Int? {
        let lower = word.lowercased()
        return months.first { $0.1.contains(lower) }?.0
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> String? {
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }
        return Todos.dueKey(date, calendar: calendar)
    }

    private static func resolve(year: Int?, month: Int, day d: Int, meetingDate: Date, calendar: Calendar) -> String? {
        if let year { return day(year, month, d, calendar: calendar) }
        let meetingYear = calendar.component(.year, from: meetingDate)
        let meetingDay = Todos.dueKey(meetingDate, calendar: calendar)
        guard let thisYear = day(meetingYear, month, d, calendar: calendar) else { return day(meetingYear + 1, month, d, calendar: calendar) }
        return thisYear >= meetingDay ? thisYear : day(meetingYear + 1, month, d, calendar: calendar)
    }

    // MARK: The same task

    /// The words of a task, lowercased, without accents and punctuation: "Send the offer!" → "send the offer".
    static func key(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Two tasks are the same when their keys are equal, or, with three words or more each, when at least 60 % of
    /// all their words are shared (a summary written again words a task a little differently).
    static func isSame(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Set(a.split(separator: " ")), y = Set(b.split(separator: " "))
        guard x.count >= 3, y.count >= 3 else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }

    // MARK: What happened to them

    /// The stored states: task key → "taken" or "dismissed". Unknown values are kept as they are.
    static func states(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    /// The states as stored: a JSON object with sorted keys, "{}" when nothing was taken or dismissed yet.
    static func encode(_ states: [String: String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: states, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func state(of key: String, in states: [String: String]) -> String? {
        states[key] ?? states.first { isSame($0.key, key) }?.value
    }

    /// Suggestions still waiting: not taken (also not made into a to-do some other way) and not dismissed.
    static func pending(_ suggestions: [TaskSuggestion], states: [String: String], madeTitles: [String]) -> [TaskSuggestion] {
        let made = madeTitles.map(key)
        return suggestions.filter { s in
            state(of: s.key, in: states) == nil && !made.contains { isSame($0, s.key) }
        }
    }

    /// Whether a task of the summary has become a to-do (for the mark on its line).
    static func isTaken(_ taskText: String, states: [String: String], madeTitles: [String]) -> Bool {
        let key = key(split(taskText, meetingDate: Date()).title)
        return state(of: key, in: states) == taken || madeTitles.map(Self.key).contains { isSame($0, key) }
    }
}

// MARK: - On the note

extension Note {
    /// Whether suggestions are offered for this note: it has a summary that may have tasks (never a saved page or
    /// file), and it was summarized since there are suggestions or the user asked for them ("Suggest To-dos").
    var offersTodoSuggestions: Bool {
        todoSuggestionsRaw != nil && !isSaved && !isTodo && summary != nil && !isDeleted
    }

    /// The suggestions waiting on this note, given the to-dos made from it.
    func pendingTodoSuggestions(made: [Note]) -> [TaskSuggestion] {
        guard offersTodoSuggestions, let summary else { return [] }
        return TodoSuggestions.pending(
            TodoSuggestions.parse(summary, meetingDate: createdAt),
            states: TodoSuggestions.states(todoSuggestionsRaw),
            madeTitles: made.map(\.title)
        )
    }
}

@MainActor
extension TodoSuggestions {
    /// A summary was written: its tasks are offered. What was taken or dismissed before stays so.
    static func offer(_ note: Note) {
        guard !note.isSaved else { return }
        if note.todoSuggestionsRaw == nil { note.todoSuggestionsRaw = encode([:]) }
    }

    /// "Suggest To-dos": the dismissed tasks come back; taken ones stay taken.
    static func suggestAgain(_ note: Note, in context: ModelContext) {
        guard !note.isSaved else { return }
        note.todoSuggestionsRaw = encode(states(note.todoSuggestionsRaw).filter { $0.value != dismissed })
        note.updatedAt = Date()
        try? context.save()
    }

    /// Nothing of them now: the tasks are dismissed until "Suggest To-dos".
    static func dismiss(_ suggestions: [TaskSuggestion], from note: Note, in context: ModelContext) {
        var all = states(note.todoSuggestionsRaw)
        for s in suggestions where all[s.key] == nil { all[s.key] = dismissed }
        note.todoSuggestionsRaw = encode(all)
        note.updatedAt = Date()
        try? context.save()
    }

    /// Takes the chosen suggestions on: one to-do each, or one to-do "Follow-ups: <title>" with them as subtasks.
    /// The ones not chosen are dismissed. The to-dos are in the note's buckets and point back to it.
    @discardableResult
    static func take(_ chosen: [TaskSuggestion], dismissing rest: [TaskSuggestion], from note: Note, asOne: Bool, in context: ModelContext) -> [Note] {
        guard !note.isSaved, !chosen.isEmpty else { return [] }
        var made: [Note] = []
        if asOne {
            let todo = newTodo(title: String(localized: "Follow-ups: \(note.displayTitle)"), from: note)
            todo.text = chosen.map { "- [ ] " + $0.title + (ownerNote($0).map { " (\($0))" } ?? "") }.joined(separator: "\n")
            todo.todoDueDay = chosen.compactMap(\.dueDay).min()
            context.insert(todo)
            made.append(todo)
        } else {
            for s in chosen {
                let todo = newTodo(title: s.title, from: note)
                if let owner = ownerNote(s) { todo.text = String(localized: "Owner: \(owner)") }
                todo.todoDueDay = s.dueDay
                context.insert(todo)
                made.append(todo)
            }
        }
        var all = states(note.todoSuggestionsRaw)
        for s in chosen { all[s.key] = taken }
        for s in rest where all[s.key] == nil { all[s.key] = dismissed }
        note.todoSuggestionsRaw = encode(all)
        note.updatedAt = Date()
        try? context.save()
        return made
    }

    /// The owner worth writing down: somebody else's name (the user's own tasks need none).
    private static func ownerNote(_ s: TaskSuggestion) -> String? {
        guard let owner = s.owner, !s.isMine else { return nil }
        return owner
    }

    private static func newTodo(title: String, from note: Note) -> Note {
        let todo = Note()
        todo.title = title
        todo.titleIsCustom = true
        todo.source = .note
        todo.todoState = .open
        todo.todoSourceID = note.id.uuidString
        todo.projectIDs = note.projectIDs
        if !todo.projectIDs.isEmpty { todo.filedAt = Date() }
        return todo
    }
}
