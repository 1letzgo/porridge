import SwiftUI

/// What the menu bar and the keyboard shortcuts of an iPad (and a hardware keyboard on a phone) reach in the window in
/// front: the existing actions of `NotesView`, handed over as a focused scene value. Modeled on the Mac's menus.
struct PlaceCommandActions {
    var newNote: () -> Void
    var newTodo: () -> Void
    var recordMeeting: () -> Void
    var search: () -> Void
    var showPlace: (Place) -> Void
    var weeklyReview: () -> Void
    var settings: () -> Void
    /// Moves the open entry to Recently Deleted; nil while none is open (or it is there already).
    var deleteEntry: (() -> Void)?
}

extension FocusedValues {
    @Entry var placeCommands: PlaceCommandActions?
}

/// The menus of the iPad's menu bar: File (New Note ⌘N, New To-do ⇧⌘N, Record Meeting ⌘R), the app's Settings… ⌘,,
/// View (Show/Hide Sidebar ⌃⌘S from the system, the places ⌘1–⌘4, Search ⌘F, Weekly Review) and Entry (Delete, without
/// a shortcut: ⌘⌫ belongs to the text being typed, it deletes to the line's start in a title, a text or the search field;
/// a menu shortcut took that key from the text field and could cost an entry).
struct PlaceCommands: Commands {
    @FocusedValue(\.placeCommands) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { actions?.newNote() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("New To-do") { actions?.newTodo() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Record Meeting") { actions?.recordMeeting() }
                .keyboardShortcut("r")
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { actions?.settings() }
                .keyboardShortcut(",")
                .disabled(actions == nil)
        }
        SidebarCommands()
        CommandGroup(before: .sidebar) {
            Button("Today") { actions?.showPlace(.today) }
                .keyboardShortcut("1")
            Button("Inbox") { actions?.showPlace(.inbox) }
                .keyboardShortcut("2")
            Button("Bowls") { actions?.showPlace(.bowls) }
                .keyboardShortcut("3")
            Button("Search") { actions?.showPlace(.search) }
                .keyboardShortcut("4")
            Divider()
            Button("Search or Ask…") { actions?.search() }
                .keyboardShortcut("f")
            Button("Weekly Review") { actions?.weeklyReview() }
            Divider()
        }
        CommandMenu("Entry") {
            Button("Delete") { actions?.deleteEntry?() }
                .disabled(actions?.deleteEntry == nil)
        }
    }
}
