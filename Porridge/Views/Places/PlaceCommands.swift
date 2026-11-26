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
    /// iPad of regular width: shows or hides the split view's sidebar through its column visibility, the one state the
    /// sidebar button and the edge swipe change too; nil where there is no sidebar (tabs).
    var toggleSidebar: (() -> Void)?
    /// Whether the sidebar shows (the menu says Hide Sidebar then).
    var sidebarShown = false
}

extension FocusedValues {
    @Entry var placeCommands: PlaceCommandActions?
}

/// The menus of the iPad's menu bar: File (New Note ⌘N, New To-do ⇧⌘N, Record Meeting ⌘R), the app's Settings… ⌘,,
/// View (Show/Hide Sidebar ⌃⌘S, through the split view's column visibility, the places ⌘1–⌘4, the last named Search or Chat after its side, Search ⌘F, Weekly Review) and Entry (Delete, without
/// a shortcut: ⌘⌫ belongs to the text being typed, it deletes to the line's start in a title, a text or the search field;
/// a menu shortcut took that key from the text field and could cost an entry).
struct PlaceCommands: Commands {
    @FocusedValue(\.placeCommands) private var actions
    /// The last place is named after its side: "Chat" while the Chat side is chosen.
    @AppStorage(SearchSide.key) private var searchSide = SearchSide.search

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
        // Not `SidebarCommands`: the system's toggle went past the split view's column visibility, so after the
        // sidebar had stepped aside for a chosen place the first ⌃⌘S did nothing.
        CommandGroup(replacing: .sidebar) {
            Button(actions?.sidebarShown == true ? "Hide Sidebar" : "Show Sidebar") { actions?.toggleSidebar?() }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(actions?.toggleSidebar == nil)
        }
        CommandGroup(before: .sidebar) {
            Button("Today") { actions?.showPlace(.today) }
                .keyboardShortcut("1")
            Button("Inbox") { actions?.showPlace(.inbox) }
                .keyboardShortcut("2")
            Button("Bowls") { actions?.showPlace(.bowls) }
                .keyboardShortcut("3")
            Button(Place.search.tabTitle(showsChat: searchSide == .chat)) { actions?.showPlace(.search) }
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
