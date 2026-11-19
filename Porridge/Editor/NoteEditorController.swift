import Observation

/// Lets the note screen reach into the editor: cursor position, keyboard, formatting.
@MainActor
@Observable
final class NoteEditorController {
    @ObservationIgnored private weak var coordinator: NoteTextCoordinator?
    /// The body is being edited (the format bar is showing above the keyboard).
    var isEditing = false
    /// Nothing typed: follows every key press, while the note hears of the text only shortly after.
    var isEmpty = true

    /// Cursor as a character offset in the note's Markdown; the end of the text when nothing is being edited.
    var cursorOffset: Int { coordinator?.cursorOffset() ?? 0 }

    func blur() { coordinator?.blur() }

    func perform(_ command: NoteEditorCommand) { coordinator?.perform(command) }

    func bind(_ coordinator: NoteTextCoordinator) { self.coordinator = coordinator }
}
