import Foundation

/// The to-dos of the shared code (`Todos`), as the AppKit views ask for them. Until the to-dos land in the shared
/// code every note is a plain note here.
@MainActor
enum TodoBridge {
    struct Progress {
        var done = 0
        var total = 0
        var label: String { total == 0 ? "" : "\(done)/\(total)" }
    }

    static func isTodo(_ note: Note) -> Bool { false }
    static func isDone(_ note: Note) -> Bool { false }
    static func progress(of note: Note) -> Progress { Progress() }
    static func setDone(_ done: Bool, _ note: Note) {}
}

extension TodoBridge {
    /// Makes a new note a to-do.
    static func makeTodo(_ note: Note) {}
}
