import Foundation

/// The to-dos of the shared code (`Todos`, `Note.isTodo`), as the AppKit views ask for them: one place that
/// names every rule the Mac interface uses.
@MainActor
enum TodoBridge {
    static var available: Bool { true }

    static func isTodo(_ note: Note) -> Bool { note.isTodo }
    static func isDone(_ note: Note) -> Bool { note.isDone }
    static func doneAt(_ note: Note) -> Date? { note.todoDoneAt }
    static func canBeTodo(_ note: Note) -> Bool { note.canBeTodo }
    static func progress(of note: Note) -> Todos.Progress { note.todoProgress }

    /// Ticks or unticks the to-do itself; done ticks every subtask.
    static func setDone(_ done: Bool, _ note: Note) {
        Todos.setDone(done, note, in: Library.shared.context)
    }

    /// Turns a note into a to-do or back; the text stays.
    static func setTodo(_ isTodo: Bool, _ note: Note) {
        Todos.setTodo(isTodo, note, in: Library.shared.context)
    }

    // MARK: Due day (the rules and labels are the shared ones of `Todos`)

    /// The due day ("yyyy-MM-dd") while it counts.
    static func due(of note: Note) -> String? { note.todoDue }

    /// Where an open to-do's due day stands; nil for a done one (never marked) or without a day.
    static func dueStatus(of note: Note) -> Todos.DueStatus? {
        guard let due = note.todoDue, !note.isDone else { return nil }
        return Todos.dueStatus(due)
    }

    static func dueLabel(_ key: String) -> String { Todos.dueLabel(key) }

    /// "Overdue, due Fri" / "Due Today", for VoiceOver.
    static func dueAccessibility(of note: Note) -> String {
        guard let due = note.todoDue else { return "" }
        let label = Todos.dueLabel(due)
        return note.isOverdue ? "Overdue, due \(label)" : "Due \(label)"
    }

    static func setDue(_ key: String?, _ notes: [Note]) {
        notes.forEach { Todos.setDue(key, $0, in: Library.shared.context) }
    }

    /// Makes a new, unsaved note a to-do.
    static func makeTodo(_ note: Note) {
        note.todoState = .open
    }

    /// The text was edited: the done state follows the subtasks.
    static func follow(_ note: Note, from old: String) {
        Todos.follow(note, from: old)
    }

    static func madeFrom(_ source: Note) -> [Note] {
        Todos.madeFrom(source, among: Library.shared.notes)
    }

    /// The note a to-do was taken from, while it is there.
    static func source(of note: Note) -> Note? {
        guard let id = note.todoSourceID else { return nil }
        return Library.shared.notes.first { $0.id.uuidString == id && !$0.isDeleted }
    }
}

/// Editor commands the to-dos brought (Move Line Up/Down, Add Subtask).
@MainActor
enum EditorCommands {
    static func moveLine(up: Bool, _ controller: NoteEditorController) {
        controller.perform(.moveLine(up: up))
    }

    static func appendChecklistItem(_ controller: NoteEditorController) {
        controller.perform(.appendChecklistItem)
    }

    static var available: Bool { true }
}
