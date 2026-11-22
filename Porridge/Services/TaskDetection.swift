import Foundation
import SwiftData

/// A line of a note that reads like something to do ("Anna anrufen", "TODO: send the offer", "I need to book the
/// flight"), found while the note is written.
struct DetectedTask: Equatable, Identifiable {
    /// Index of the line in the text (lines split at "\n").
    var line: Int
    /// The task's words, without list marks and markers such as "TODO:".
    var text: String
    /// `TodoSuggestions.key` of the text: what "the same task" means when it is dismissed.
    var key: String
    /// "yyyy-MM-dd" when the line names a date that resolves to one day.
    var dueDay: String?

    var id: String { "\(line)|\(key)" }
}

/// Finds actionable lines in a plain note, cheaply and on the device: rules on the words of each line, no model.
/// The note page asks a moment after typing stopped (`debounce`) and offers what it found under the editor. Nothing
/// changes without a tap. Never for saved links, shared files or meetings (`applies`).
enum TaskDetection {
    /// How long typing has to rest before the note is looked at again.
    static let debounce: Duration = .milliseconds(1200)
    /// Lines longer than this are prose, not a task.
    static let maxLineLength = 140

    /// Whether the note is looked at: the user's own words only. Links and other saved things never produce tasks.
    static func applies(to note: Note) -> Bool {
        !note.isSaved && !note.isLink && !note.isStored && !note.isRecording && !note.isDeleted && !note.isEmptyLeftover
    }

    // MARK: Reading the text

    /// The lines that read like tasks, in their order, each task once. Checklist lines (already tasks), headings,
    /// quotes, code and questions are left alone.
    static func detect(in text: String, now: Date = Date(), calendar: Calendar = .current) -> [DetectedTask] {
        guard !text.isEmpty else { return [] }
        var result: [DetectedTask] = []
        var seen = Set<String>()
        var inFence = false
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, !trimmed.isEmpty, trimmed.count <= maxLineLength else { continue }
            guard let body = taskText(of: trimmed) else { continue }
            let key = TodoSuggestions.key(body)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let due = TodoSuggestions.dueDay(from: body, meetingDate: now, calendar: calendar, strict: true)
            result.append(DetectedTask(line: index, text: body, key: key, dueDay: due))
        }
        return result
    }

    /// The task in a line, or nil when the line does not read like one.
    static func taskText(of line: String) -> String? {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("|") { return nil }
        if isChecklist(line) { return nil }
        let (isListItem, rest) = withoutListMark(line)
        var body = rest.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        if body.contains("://") && body.split(separator: " ").count <= 2 { return nil }

        // "TODO: …", "Aufgabe: …": said outright.
        if let marked = withoutMarker(body) {
            return marked.isEmpty ? nil : clean(marked)
        }
        guard !body.hasSuffix("?") else { return nil }
        body = clean(body)
        let words = wordList(body)
        guard words.count >= 2 else { return nil }
        let lower = " " + words.joined(separator: " ") + " "

        // "I need to …", "ich muss …", "nicht vergessen: …".
        if modalPhrases.contains(where: { lower.contains($0) }) { return body }
        // "Call Anna about the offer": an English imperative at the start.
        if let first = words.first, englishVerbs.contains(first), words.count <= 14 { return body }
        // "Anna anrufen", "- Milch kaufen": a German infinitive at the end of a short line without a subject.
        // A deadline after the verb ("Rechnung bezahlen bis 28.11.") does not hide it.
        let cut = words.lastIndex { deadlineWords.contains($0) }.flatMap { $0 > 0 ? $0 : nil } ?? words.count
        let core = words[..<cut]
        if let last = core.last, germanVerbs.contains(last) || germanSeparable(last),
           words.count <= (isListItem ? 10 : 7), !words.contains(where: { germanSubjects.contains($0) }) {
            return body
        }
        return nil
    }

    private static let checklist = try! NSRegularExpression(pattern: #"^[-*+][ \t]+\[[ xX]\]"#)
    private static let listMark = try! NSRegularExpression(pattern: #"^([-*+•]|\d{1,3}[.)])[ \t]+"#)
    private static let marker = try! NSRegularExpression(
        pattern: #"^(?:\[ \]\s*|(?:todo|to-do|to do|task|action|action item|ai|aufgabe|erledigen|offen)\s*[:!-]\s*|todo\s+)"#,
        options: .caseInsensitive
    )

    private static func isChecklist(_ line: String) -> Bool {
        checklist.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func withoutListMark(_ line: String) -> (Bool, String) {
        let ns = line as NSString
        guard let m = listMark.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return (false, line) }
        return (true, ns.substring(from: m.range.upperBound))
    }

    private static func withoutMarker(_ text: String) -> String? {
        let ns = text as NSString
        guard let m = marker.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(from: m.range.upperBound).trimmingCharacters(in: .whitespaces)
    }

    /// Bold marks and a final full stop or exclamation mark go; the words stay.
    private static func clean(_ text: String) -> String {
        var body = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        body = body.trimmingCharacters(in: .whitespaces)
        // "bis 28.11." keeps the dot of its date.
        while let last = body.last, ".!;".contains(last), !(last == "." && body.dropLast().last?.isNumber == true) { body.removeLast() }
        return body.trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased words without punctuation.
    private static func wordList(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'-")).inverted)
            .filter { !$0.isEmpty }
    }

    private static let modalPhrases = [
        // English
        " need to ", " needs to ", " have to ", " has to ", " i must ", " we must ", " i should ", " we should ", " don't forget ", " dont forget ",
        " remember to ", " remind me ", " todo ", " to-do ", " follow up ", " deadline ",
        // German
        " muss ", " müssen ", " muß ", " ich sollte ", " wir sollten ", " sollte ich ", " sollten wir ", " nicht vergessen ", " denk an ", " denke an ", " daran denken ",
        " dran denken ", " erinnern an ", " erledigen ", " noch machen ", " bis morgen ", " bis montag ", " bis dienstag ",
        " bis mittwoch ", " bis donnerstag ", " bis freitag ", " bis spätestens ",
    ]

    private static let deadlineWords: Set<String> = ["bis", "spätestens", "am", "vor", "until", "by", "before"]

    private static let englishVerbs: Set<String> = [
        "call", "buy", "send", "email", "e-mail", "mail", "write", "pay", "book", "order", "pick", "fix", "check", "ask",
        "schedule", "prepare", "finish", "submit", "reply", "answer", "review", "update", "contact", "cancel", "renew",
        "clean", "remind", "print", "sign", "organize", "organise", "plan", "return", "get", "text", "message", "invite",
        "draft", "share", "upload", "download", "install", "test", "confirm", "reserve", "register", "apply", "file",
        "post", "bring", "collect", "deliver", "visit", "discuss", "clarify", "research", "move", "repair", "replace", "wash", "feed", "water", "pack", "ship", "refund", "transfer",
    ]

    private static let germanVerbs: Set<String> = [
        "kaufen", "einkaufen", "anrufen", "zurückrufen", "schicken", "abschicken", "verschicken", "senden", "schreiben",
        "bezahlen", "zahlen", "überweisen", "buchen", "bestellen", "abholen", "erledigen", "machen", "prüfen", "überprüfen",
        "klären", "abklären", "vorbereiten", "fragen", "nachfragen", "reservieren", "kündigen", "einreichen", "antworten",
        "beantworten", "besorgen", "mailen", "melden", "abgeben", "organisieren", "planen", "aufräumen", "reparieren",
        "putzen", "waschen", "vereinbaren", "ausdrucken", "drucken", "unterschreiben", "aktualisieren", "fertigstellen",
        "besprechen", "checken", "kontaktieren", "einladen", "erinnern", "abstimmen", "eintragen", "anmelden", "abmelden",
        "verlängern", "zurückgeben", "abschließen", "beantragen", "hochladen", "installieren", "testen", "bestätigen",
        "lesen", "recherchieren", "suchen", "finden", "mitbringen", "packen", "einpacken", "gießen", "füttern", "holen",
        "bringen", "vorbeibringen", "erstellen", "entwerfen", "teilen", "korrigieren", "ändern", "tauschen", "austauschen",
    ]

    /// "anzurufen", "abzuholen": the infinitive with "zu" in it counts the same.
    private static func germanSeparable(_ word: String) -> Bool {
        guard word.count > 6, let range = word.range(of: "zu") else { return false }
        let joined = word.replacingCharacters(in: range, with: "")
        return germanVerbs.contains(joined)
    }

    /// A sentence with one of these is a statement ("wir haben das gemacht"), not a task.
    private static let germanSubjects: Set<String> = ["ich", "wir", "du", "er", "man", "ihr", "hat", "haben", "habe", "wurde", "wurden", "ist", "sind", "war", "waren"]

    // MARK: Changing the text

    /// The task lines as unticked checklist lines ("- [ ] <task>"), each at its indentation; other lines stay.
    static func checklisted(_ tasks: [DetectedTask], in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        for task in tasks where lines.indices.contains(task.line) {
            let line = lines[task.line]
            // The line changed since it was read: it is left alone.
            guard taskText(of: line.trimmingCharacters(in: .whitespaces)).map(TodoSuggestions.key) == task.key else { continue }
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            lines[task.line] = indent + "- [ ] " + task.text
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Dismissed (on this device only)

    private static func dismissedKey(_ note: Note) -> String { "taskDetection.dismissed.\(note.id.uuidString)" }

    static func dismissed(for note: Note, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: dismissedKey(note)) ?? [])
    }

    /// The tasks still to offer for the note: found in its text, not dismissed before.
    static func pending(for note: Note, defaults: UserDefaults = .standard) -> [DetectedTask] {
        guard applies(to: note) else { return [] }
        let dismissed = dismissed(for: note, defaults: defaults)
        return detect(in: note.text).filter { !dismissed.contains($0.key) }
    }

    /// The tasks are not offered again for this note.
    static func dismiss(_ tasks: [DetectedTask], for note: Note, defaults: UserDefaults = .standard) {
        let all = dismissed(for: note, defaults: defaults).union(tasks.map(\.key))
        defaults.set(Array(all).sorted(), forKey: dismissedKey(note))
    }

    /// "2 possible to-dos".
    static func label(count: Int) -> String {
        count == 1 ? "1 possible to-do" : "\(count) possible to-dos"
    }
}

@MainActor
extension TaskDetection {
    /// The note becomes an open to-do; the task lines become its subtasks (checklist lines in place). Its due day is
    /// the earliest date the tasks name, when it has none yet.
    static func makeTodo(_ note: Note, with tasks: [DetectedTask], in context: ModelContext) {
        guard applies(to: note), note.canBeTodo else { return }
        note.text = checklisted(tasks, in: note.text)
        if !note.isTodo {
            note.todoState = .open
            note.todoDoneAt = nil
        }
        if !Todos.isDueKey(note.todoDueDay), let due = tasks.compactMap(\.dueDay).min() { note.todoDueDay = due }
        note.updatedAt = Date()
        if note.modelContext != nil { try? context.save() }
    }

    /// The task lines become checklist lines (subtasks of a to-do); the note stays what it is.
    static func addAsSubtasks(_ note: Note, _ tasks: [DetectedTask], in context: ModelContext) {
        guard applies(to: note) else { return }
        let old = note.text
        note.text = checklisted(tasks, in: old)
        // A done to-do that gets open subtasks is open again.
        Todos.follow(note, from: old)
        note.updatedAt = Date()
        if note.modelContext != nil { try? context.save() }
    }
}
