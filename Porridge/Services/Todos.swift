import Foundation
import SwiftData

/// Whether a note is a to-do. A to-do is an ordinary note (same lists, buckets, inbox, archive, search, chat and
/// sync) with a done state; its subtasks are the checklist lines (`- [ ] ` / `- [x] `) of its text.
/// Stored as `Note.todoStateRaw`: nil = never was a to-do, so its sync record stays as it was.
enum TodoState: String {
    case open
    case done
    /// Was a to-do and was turned back into a note. Written so the other devices learn of it.
    case none
}

/// The rules of to-dos, kept free of views so Android can follow them (`Todos.kt`).
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

    // MARK: Sync

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

    /// Three-way merge of the ticks when both devices changed a to-do: the text of `winner` (the newer one) with
    /// the subtasks the other device ticked or unticked since `base`, as long as the winner left them alone.
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

    /// The record of a to-do changed on both devices: the newer one with the other one's ticks (see
    /// `mergeTicks`), its done state following the merged subtasks. Nil when there is nothing to merge
    /// (not a to-do, no base text, or the result is the newer record as it is).
    static func mergeRecords(base: String?, winner: SyncRecord, loser: SyncRecord, now: Int64) -> SyncRecord? {
        guard let base, isTodoRecord(winner), isTodoRecord(loser),
              let winnerText = winner["text"] as? String, let loserText = loser["text"] as? String else { return nil }
        let text = mergeTicks(base: base, winner: winnerText, loser: loserText)
        guard text != winnerText else { return nil }
        var merged = winner
        merged["text"] = text
        let state = TodoState(rawValue: winner["todoStateRaw"] as? String ?? "") ?? .open
        switch stateAfterEdit(old: winnerText, new: text, state: state) {
        case .done:
            merged["todoStateRaw"] = TodoState.done.rawValue
            merged["todoDoneAt"] = NSNumber(value: now)
        case .open:
            merged["todoStateRaw"] = TodoState.open.rawValue
            merged["todoDoneAt"] = nil
        default:
            break
        }
        return merged
    }

    /// The record is of a to-do (open or done).
    static func isTodoRecord(_ record: SyncRecord) -> Bool {
        let raw = record["todoStateRaw"] as? String
        return raw == TodoState.open.rawValue || raw == TodoState.done.rawValue
    }

    // MARK: Lists

    /// A done to-do stays in its list, ticked, for the rest of the day; from the next day it counts as archived.
    static func isPutAway(doneAt: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let doneAt else { return false }
        return doneAt < calendar.startOfDay(for: now)
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

    /// A to-do done before today: out of the lists like an archived note.
    var isPutAway: Bool { isDone && Todos.isPutAway(doneAt: todoDoneAt) }

    /// Any note but a saved one (link, shared file) and a meeting can be a to-do.
    var canBeTodo: Bool { !isSaved && !isRecording }
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

    private static func save(_ note: Note, in context: ModelContext) {
        // A new note that was never saved is stored with its first content (`NoteDetailView.saveIfFilled`).
        guard note.modelContext != nil else { return }
        try? context.save()
    }
}
