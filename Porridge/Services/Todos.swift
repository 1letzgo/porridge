import Foundation
import SwiftData

/// Whether a note is a to-do. A to-do is an ordinary note (same lists, buckets, inbox, search, chat and
/// sync) with a done state; its subtasks are the checklist lines (`- [ ] ` / `- [x] `) of its text.
/// Stored as `Note.todoStateRaw`: nil = never was a to-do.
enum TodoState: String {
    case open
    case done
    /// Was a to-do and was turned back into a note. Written so the other devices learn of it.
    case none
}

/// The rules of to-dos, kept free of views.
enum Todos {
    /// One checklist line of a to-do's text.
    struct Subtask: Equatable {
        /// Index of the line in the text (lines split at "\n").
        var line: Int
        var indent: Int
        var text: String
        var done: Bool
    }

    struct Progress: Equatable {
        var done: Int
        var total: Int

        /// Every subtask is ticked (and there is at least one).
        var isComplete: Bool { total > 0 && done == total }
        var hasOpen: Bool { done < total }
        /// "2/5"; empty without subtasks.
        var label: String { total == 0 ? "" : "\(done)/\(total)" }
    }

    private static let checklistMark = try! NSRegularExpression(pattern: #"^([ \t]*)[-*+][ \t]+\[([ xX])\](?:[ \t]+(.*))?$"#)

    /// The subtasks: checklist lines with text, outside code blocks. Same syntax as the editor (`NoteBlock`).
    static func subtasks(in text: String) -> [Subtask] {
        guard text.contains("[") else { return [] }
        var result: [Subtask] = []
        var inFence = false
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, let item = checklistItem(line) else { continue }
            let body = item.text.trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }
            result.append(Subtask(line: index, indent: item.indent, text: body, done: item.done))
        }
        return result
    }

    private static func checklistItem(_ line: String) -> (indent: Int, done: Bool, text: String)? {
        let ns = line as NSString
        guard let m = checklistMark.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let space = ns.substring(with: m.range(at: 1))
        let text = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
        let indent = space.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        return (indent, ns.substring(with: m.range(at: 2)) != " ", text)
    }

    static func progress(_ text: String) -> Progress {
        let items = subtasks(in: text)
        return Progress(done: items.filter(\.done).count, total: items.count)
    }

    /// The line with its box ticked or not; other lines stay as they are.
    static func setLine(_ line: Int, done: Bool, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line), checklistItem(lines[line]) != nil,
              let range = lines[line].range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return text }
        lines[line].replaceSubrange(range, with: done ? "[x]" : "[ ]")
        return lines.joined(separator: "\n")
    }

    static func toggleLine(_ line: Int, in text: String) -> String {
        guard let item = subtasks(in: text).first(where: { $0.line == line }) else { return text }
        return setLine(line, done: !item.done, in: text)
    }

    /// Every subtask ticked (or unticked).
    static func setAll(_ done: Bool, in text: String) -> String {
        subtasks(in: text).reduce(text) { setLine($1.line, done: done, in: $0) }
    }

    /// A new unticked subtask at the end; an empty checklist line already there is reused.
    static func appendingSubtask(_ title: String = "", to text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if let last = lines.last, let item = checklistItem(last), item.text.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        lines.append("- [ ] " + title)
        return lines.joined(separator: "\n")
    }

    /// Moves a line one place up (`offset` -1) or down (+1). Used to reorder subtasks (any line, in fact).
    static func moveLine(_ line: Int, by offset: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let target = line + offset
        guard lines.indices.contains(line), lines.indices.contains(target) else { return text }
        lines.swapAt(line, target)
        return lines.joined(separator: "\n")
    }

    static func removeLine(_ line: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return text }
        lines.remove(at: line)
        return lines.joined(separator: "\n")
    }

    // MARK: Done rules

    /// What the done state becomes after the subtasks changed from `old` to `new` (nil: it stays).
    /// - The last open subtask ticked: the to-do is done.
    /// - A done to-do that gets an open subtask (one unticked or a new one): it is open again.
    /// Only changes count: a to-do reopened by hand with every subtask ticked stays open.
    static func stateAfterEdit(old: String, new: String, state: TodoState) -> TodoState? {
        let before = progress(old), after = progress(new)
        guard before != after else { return nil }
        if state == .open, after.isComplete, !before.isComplete { return .done }
        if state == .done, after.hasOpen, !before.hasOpen || after.done < before.done { return .open }
        return nil
    }

    // MARK: Merging ticks

    /// Key of a subtask across versions of the text: its words and how many lines with the same words came before.
    private static func keyed(_ text: String) -> [String: Subtask] {
        var seen: [String: Int] = [:]
        var result: [String: Subtask] = [:]
        for item in subtasks(in: text) {
            let words = item.text.lowercased()
            let n = seen[words, default: 0]
            seen[words] = n + 1
            result["\(n)|\(words)"] = item
        }
        return result
    }

    /// Three-way merge of the ticks when two sides changed a to-do (the editor and a change from outside): the text
    /// of `winner` with the subtasks the other side ticked or unticked since `base`, as long as the winner left them alone.
    static func mergeTicks(base: String, winner: String, loser: String) -> String {
        let baseItems = keyed(base), winnerItems = keyed(winner)
        var text = winner
        for (key, theirs) in keyed(loser) {
            guard let was = baseItems[key], theirs.done != was.done,
                  let mine = winnerItems[key], mine.done == was.done else { continue }
            text = setLine(mine.line, done: theirs.done, in: text)
        }
        return text
    }

    // MARK: Lists

    /// Done before today. Only the to-dos folder's "Done Today" section uses this; in buckets and the inbox a done
    /// to-do stays like every note (notes are never archived).
    static func isPutAway(doneAt: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let doneAt else { return false }
        return doneAt < calendar.startOfDay(for: now)
    }

    // MARK: Due day

    /// `Note.todoDueDay` of a due date that was taken away: written so the other devices learn of it.
    static let clearedDue = "none"

    /// A due day as stored: "yyyy-MM-dd", a day of the calendar without time and time zone. It is the same day on
    /// every device, wherever it is.
    static func dueKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A stored due day, if it is one ("none" and anything else malformed are not).
    static func isDueKey(_ key: String?) -> Bool {
        guard let key, key.count == 10 else { return false }
        let parts = key.split(separator: "-")
        return parts.count == 3 && parts.allSatisfy { Int($0) != nil }
    }

    /// The start of the due day in `calendar`'s time zone.
    static func dueDate(_ key: String, calendar: Calendar = .current) -> Date? {
        guard isDueKey(key) else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    enum DueStatus: Equatable {
        /// Before today: an open to-do that is late.
        case overdue
        case today
        case later
    }

    /// Where a due day stands against today. Overdue starts at midnight after the due day.
    static func dueStatus(_ key: String, now: Date = Date(), calendar: Calendar = .current) -> DueStatus? {
        guard isDueKey(key) else { return nil }
        let today = dueKey(now, calendar: calendar)
        // Keys are zero-padded, so they compare like the days they name.
        return key < today ? .overdue : key == today ? .today : .later
    }

    /// The due day as the list shows it: "Today", "Tomorrow", "Yesterday", a weekday for the next six days
    /// ("Fri"), otherwise day and month ("12 Dec"), with the year when it is not this year ("12 Dec 2027").
    static func dueLabel(_ key: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let due = dueDate(key, calendar: calendar) else { return "" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: due).day ?? 0
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        case -1: return String(localized: "Yesterday")
        default: break
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        if (2...6).contains(days) {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        } else if calendar.component(.year, from: due) == calendar.component(.year, from: now) {
            formatter.setLocalizedDateFormatFromTemplate("dMMM")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("dMMMy")
        }
        return formatter.string(from: due)
    }

    /// "12 December 2026": the due day for the chat and the export, the same in every language.
    static func dueText(_ key: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let due = dueDate(key, calendar: calendar) else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: due)
    }

    /// The quick choices: today, tomorrow, and the first day of next week (as the calendar counts weeks).
    enum DueChoice: CaseIterable {
        case today, tomorrow, nextWeek

        var title: String {
            switch self {
            case .today: String(localized: "Today")
            case .tomorrow: String(localized: "Tomorrow")
            case .nextWeek: String(localized: "Next Week")
            }
        }

        var systemImage: String {
            switch self {
            case .today: "star"
            case .tomorrow: "sunrise"
            case .nextWeek: "calendar.badge.clock"
            }
        }
    }

    static func dueKey(for choice: DueChoice, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let day: Date
        switch choice {
        case .today: day = today
        case .tomorrow: day = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        case .nextWeek: day = calendar.dateInterval(of: .weekOfYear, for: today)?.end ?? calendar.date(byAdding: .day, value: 7, to: today) ?? today
        }
        return dueKey(day, calendar: calendar)
    }

    /// Open to-dos by due day (earliest first, undated last); done ones after them. Otherwise the order stays.
    static func byDue(_ todos: [Note]) -> [Note] {
        let open = todos.filter { !$0.isDone }.enumerated().sorted { a, b in
            switch (a.element.todoDue, b.element.todoDue) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
        return open + todos.filter(\.isDone)
    }

    /// The virtual folder "To-dos" in the "Up Next" section of the home list: every open to-do, wherever it is filed,
    /// in the groups of `dueGroups`, then those done today. Only a view: nothing is moved or stored.
    struct Folder {
        var groups: [(title: String, notes: [Note])]
        var doneToday: [Note]
        /// Open to-dos (not done, not deleted).
        var open: Int
        /// Of them, those due before today.
        var overdue: Int

        var isEmpty: Bool { open == 0 && doneToday.isEmpty }
    }

    static func folder(_ notes: [Note], now: Date = Date(), calendar: Calendar = .current) -> Folder {
        let living = notes.filter { $0.isTodo && !$0.isDeleted }
        let open = living.filter { !$0.isDone }
        // Done ones stay for the rest of the day they were done on, as in every list.
        let done = living.filter { $0.isDone && !isPutAway(doneAt: $0.todoDoneAt, now: now, calendar: calendar) }
            .sorted { ($0.todoDoneAt ?? .distantPast) > ($1.todoDoneAt ?? .distantPast) }
        let overdue = open.filter { $0.todoDue.flatMap { dueStatus($0, now: now, calendar: calendar) } == .overdue }.count
        return Folder(groups: dueGroups(open, now: now, calendar: calendar), doneToday: done, open: open.count, overdue: overdue)
    }

    /// Open to-dos in groups by their due day: Overdue, Today, Upcoming, No Due Date (empty groups left out),
    /// each sorted by due day.
    static func dueGroups(_ todos: [Note], now: Date = Date(), calendar: Calendar = .current) -> [(title: String, notes: [Note])] {
        var overdue: [Note] = [], today: [Note] = [], later: [Note] = [], none: [Note] = []
        for note in byDue(todos) {
            switch note.todoDue.flatMap({ dueStatus($0, now: now, calendar: calendar) }) {
            case .overdue?: overdue.append(note)
            case .today?: today.append(note)
            case .later?: later.append(note)
            case nil: none.append(note)
            }
        }
        return [
            (String(localized: "Overdue"), overdue), (String(localized: "Today"), today),
            (String(localized: "Upcoming"), later), (String(localized: "No Due Date"), none),
        ].filter { !$0.1.isEmpty }
    }
}

// MARK: - The note as a to-do

extension Note {
    /// nil: a note that never was a to-do.
    var todoState: TodoState? {
        get { todoStateRaw.flatMap(TodoState.init(rawValue:)) }
        set { todoStateRaw = newValue?.rawValue }
    }

    var isTodo: Bool { todoState == .open || todoState == .done }

    var isDone: Bool { todoState == .done }

    var todoProgress: Todos.Progress { isTodo ? Todos.progress(text) : Todos.Progress(done: 0, total: 0) }

    /// A to-do done before today: no longer in the to-dos folder's "Done Today". It stays in its bucket or the inbox.
    var isPutAway: Bool { isDone && Todos.isPutAway(doneAt: todoDoneAt) }

    /// Any note but a saved one (link, shared file) and a meeting can be a to-do.
    var canBeTodo: Bool { !isSaved && !isRecording }

    /// The due day ("yyyy-MM-dd") while it counts: set, and the note is a to-do. A note turned back from a
    /// to-do keeps it stored without showing it.
    var todoDue: String? { isTodo && Todos.isDueKey(todoDueDay) ? todoDueDay : nil }

    /// Open and due before today.
    var isOverdue: Bool {
        !isDone && todoDue.flatMap { Todos.dueStatus($0) } == .overdue
    }
}

@MainActor
extension Todos {
    /// Turns a note into a to-do (open) or back into a note. The text stays as it is.
    static func setTodo(_ isTodo: Bool, _ note: Note, in context: ModelContext) {
        guard isTodo != note.isTodo else { return }
        note.todoState = isTodo ? .open : TodoState.none
        note.todoDoneAt = nil
        note.updatedAt = Date()
        save(note, in: context)
    }

    /// Ticks or unticks the to-do itself. Done ticks every subtask; open leaves them as they are.
    static func setDone(_ done: Bool, _ note: Note, in context: ModelContext) {
        guard note.isTodo, done != note.isDone else { return }
        note.todoState = done ? .done : .open
        note.todoDoneAt = done ? Date() : nil
        if done { note.text = setAll(true, in: note.text) }
        note.updatedAt = Date()
        save(note, in: context)
    }

    /// Ticks or unticks one subtask; the to-do follows (see `stateAfterEdit`).
    static func toggleSubtask(line: Int, of note: Note, in context: ModelContext) {
        let old = note.text
        note.text = toggleLine(line, in: old)
        follow(note, from: old)
        note.updatedAt = Date()
        save(note, in: context)
    }

    /// The text of a to-do was edited (a box tapped in the editor, a subtask added): the done state follows.
    static func follow(_ note: Note, from old: String) {
        guard let state = note.todoState, note.isTodo,
              let next = stateAfterEdit(old: old, new: note.text, state: state) else { return }
        note.todoState = next
        note.todoDoneAt = next == .done ? Date() : nil
    }

    /// A task line of a summary as a to-do of its own, in the buckets of its note, pointing back to it.
    /// Never from a saved link or file.
    @discardableResult
    static func create(fromTask task: String, of source: Note, in context: ModelContext) -> Note? {
        guard !source.isSaved else { return nil }
        let note = Note()
        note.title = task
        note.titleIsCustom = true
        note.source = .note
        note.todoState = .open
        note.todoSourceID = source.id.uuidString
        note.projectIDs = source.projectIDs
        if !note.projectIDs.isEmpty { note.filedAt = Date() }
        context.insert(note)
        try? context.save()
        return note
    }

    /// The to-dos made from the task lines of a note's summary.
    static func madeFrom(_ source: Note, among notes: [Note]) -> [Note] {
        let id = source.id.uuidString
        return notes.filter { $0.todoSourceID == id && !$0.isDeleted }
    }

    /// Sets the due day, or takes it away (nil): then "none" is stored, so that devices which had it drop it too.
    static func setDue(_ key: String?, _ note: Note, in context: ModelContext) {
        let value = key ?? (note.todoDueDay == nil ? nil : clearedDue)
        guard value != note.todoDueDay else { return }
        note.todoDueDay = value
        note.updatedAt = Date()
        save(note, in: context)
    }

    private static func save(_ note: Note, in context: ModelContext) {
        // A new note that was never saved is stored with its first content (`NoteDetailView.saveIfFilled`).
        guard note.modelContext != nil else { return }
        try? context.save()
    }
}
