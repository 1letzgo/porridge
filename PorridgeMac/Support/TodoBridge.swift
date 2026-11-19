import Foundation

/// The to-dos of the shared code (`Todos`), as the AppKit views ask for them. Until the to-dos land in the shared
/// code every note is a plain note here and nothing is offered.
@MainActor
enum TodoBridge {
    struct Progress {
        var done = 0
        var total = 0
        var label: String { total == 0 ? "" : "\(done)/\(total)" }
    }

    /// The shared code knows to-dos.
    static var available: Bool { false }

    static func isTodo(_ note: Note) -> Bool { false }
    static func isDone(_ note: Note) -> Bool { false }
    static func doneAt(_ note: Note) -> Date? { nil }
    static func canBeTodo(_ note: Note) -> Bool { false }
    static func progress(of note: Note) -> Progress { Progress() }
    static func setDone(_ done: Bool, _ note: Note) {}
    static func setTodo(_ isTodo: Bool, _ note: Note) {}
    /// Makes a new, unsaved note a to-do.
    static func makeTodo(_ note: Note) {}
    /// The text was edited: the done state follows the subtasks.
    static func follow(_ note: Note, from old: String) {}
    static func create(fromTask task: String, of source: Note) {}
    static func madeFrom(_ source: Note) -> [Note] { [] }
    static func source(of note: Note) -> Note? { nil }
}

/// Editor commands that arrive with the to-dos.
@MainActor
enum EditorCommands {
    static func moveLine(up: Bool, _ controller: NoteEditorController) {}
    static func appendChecklistItem(_ controller: NoteEditorController) {}
    static var available: Bool { false }
}
