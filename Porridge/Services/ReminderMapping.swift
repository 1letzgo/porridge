import Foundation

/// What a reminder in Apple's Reminders carries of a to-do (the sync with Reminders, `ReminderSync`): its title, its
/// text with the subtasks as a checklist in the reminder's notes, whether it is done, and its due day. Priority,
/// alarms and tags are not mapped. A repeating to-do has no repeat rule in Reminders: Porridge moves it on
/// (`Todos.rollOver`) and the reminder follows to the next due day, open again.
struct ReminderFields: Codable, Equatable {
    var title: String
    /// The reminder's notes: the to-do's text with its checklist lines as "☐ " / "☑ " (`ReminderMapping.notes`).
    var notes: String
    var isDone: Bool
    /// "yyyy-MM-dd" (`Todos.dueKey`); nil without a due day.
    var dueDay: String?
}

/// How a to-do and a reminder map onto each other. Pure: no EventKit, no store.
enum ReminderMapping {
    /// The list key of the to-dos in no bowl: they go into the default list of Reminders (whichever it is now).
    static let inboxKey = "inbox"
    /// The key in `Note.todoSuggestionsRaw` (as `@repeat`) that holds the reminder's `calendarItemExternalIdentifier`.
    static let linkKey = "@reminder"

    // MARK: Links back

    /// The reminder's URL: the entry's link (`porridge://entry/<UUID>`), a second key to find it again.
    static func url(for id: UUID) -> URL {
        URL(string: "porridge://entry/" + id.uuidString)!
    }

    /// The entry a reminder's URL points to.
    static func noteID(from url: URL?) -> UUID? {
        guard let url, url.scheme?.lowercased() == "porridge", url.host?.lowercased() == "entry" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    // MARK: Fields

    /// The fields of a to-do as its reminder should carry them.
    static func fields(title: String, text: String, isDone: Bool, dueDay: String?) -> ReminderFields {
        let ownTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = text
        var shown = ownTitle
        if ownTitle.isEmpty {
            // The first line serves as title (as `Note.displayTitle`): it is not repeated in the notes, unless it is a
            // subtask.
            var lines = text.components(separatedBy: "\n")
            if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                if checklistLine(lines[first]) == nil {
                    shown = NoteText.plainLines(lines[first]).first ?? ""
                    lines.remove(at: first)
                    body = lines.joined(separator: "\n")
                } else {
                    shown = NoteText.plainLines(lines[first]).first ?? ""
                }
            }
        }
        return ReminderFields(
            title: shown.isEmpty ? "To-do" : shown,
            notes: notes(fromText: body),
            isDone: isDone,
            dueDay: Todos.isDueKey(dueDay) ? dueDay : nil
        )
    }

    static func fields(of note: Note) -> ReminderFields {
        fields(title: note.title, text: note.text, isDone: note.isDone, dueDay: note.todoDue)
    }

    /// The list a to-do belongs in: its bowl's (`Projects.key`), or the Inbox's.
    static func listKey(of note: Note) -> String {
        note.projectIDs.first ?? inboxKey
    }

    // MARK: Checklist in the notes

    private static let checklistMark = try! NSRegularExpression(pattern: #"^([ \t]*)[-*+][ \t]+\[([ xX])\](?:[ \t]+(.*))?$"#)
    private static let boxMark = try! NSRegularExpression(pattern: #"^([ \t]*)([☐☑✓✔])\x{FE0E}?[ \t]*(.*)$"#)

    private static func checklistLine(_ line: String) -> (indent: Int, done: Bool, text: String)? {
        let ns = line as NSString
        guard let m = checklistMark.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let space = ns.substring(with: m.range(at: 1))
        let text = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
        let indent = space.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
        return (indent, ns.substring(with: m.range(at: 2)) != " ", text)
    }

    /// The to-do's text as the reminder's notes: checklist lines become "☐ subtask" / "☑ subtask" (two spaces per
    /// level of indent), everything else stays as it is. Code blocks are left alone. Ends without blank lines.
    static func notes(fromText text: String) -> String {
        var inFence = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); return line }
            guard !inFence, let item = checklistLine(line) else { return line }
            return String(repeating: "  ", count: item.indent) + (item.done ? "☑ " : "☐ ") + item.text
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reminder's notes as a to-do's text: "☐ " / "☑ " (and "✓ ") lines become checklist lines again.
    static func text(fromNotes notes: String) -> String {
        var inFence = false
        return notes.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); return line }
            let ns = line as NSString
            guard !inFence, let m = boxMark.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
            let space = ns.substring(with: m.range(at: 1))
            let indent = space.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2
            let done = ns.substring(with: m.range(at: 2)) != "☐"
            return String(repeating: "  ", count: indent) + (done ? "- [x] " : "- [ ] ") + ns.substring(with: m.range(at: 3))
        }.joined(separator: "\n")
    }

    // MARK: Due day

    /// The due date components to write for a due day. A reminder that has a time on that same day keeps it: Porridge
    /// knows only the day and never takes a time away it did not set. nil: no due day.
    static func dueComponents(day: String?, keeping existing: DateComponents?) -> DateComponents? {
        guard let day, let d = TodoRepeat.Day(day) else { return nil }
        if let existing, existing.year == d.year, existing.month == d.month, existing.day == d.day { return existing }
        return DateComponents(year: d.year, month: d.month, day: d.day)
    }

    /// The due day of a reminder's due date components.
    static func dueDay(from components: DateComponents?) -> String? {
        guard let c = components, let year = c.year, let month = c.month, let day = c.day else { return nil }
        let key = TodoRepeat.Day(year: year, month: month, day: day).key
        return TodoRepeat.Day(key) == nil ? nil : key
    }

    // MARK: Names

    /// A list's or bowl's name compared: trimmed, without case and accents.
    static func normalized(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

// MARK: - The link on the note

extension Note {
    /// The reminder this to-do is linked to (`calendarItemExternalIdentifier`), kept without a field of its own in the
    /// JSON object of `todoSuggestionsRaw` under `@reminder` (as `@repeat`). Versions that do not know it keep it.
    /// A to-do that had no object gets `@unoffered` with it, so that no summary suggestions count as offered
    /// (`offersTodoSuggestions`); taking it away leaves the object as it was.
    var reminderLink: String? {
        get {
            guard let raw = todoSuggestionsRaw, raw.contains(ReminderMapping.linkKey) else { return nil }
            return TodoSuggestions.states(raw)[ReminderMapping.linkKey]
        }
        set {
            guard reminderLink != newValue else { return }
            let wasNil = todoSuggestionsRaw == nil
            var all = TodoSuggestions.states(todoSuggestionsRaw)
            all[ReminderMapping.linkKey] = newValue
            if newValue != nil, wasNil { all[InboxSnooze.unofferedKey] = "1" }
            if newValue == nil, all.isEmpty || all.keys.allSatisfy({ $0 == InboxSnooze.unofferedKey }),
               todoSuggestionsRaw?.contains(InboxSnooze.unofferedKey) == true {
                todoSuggestionsRaw = nil
            } else {
                todoSuggestionsRaw = TodoSuggestions.encode(all)
            }
        }
    }
}
