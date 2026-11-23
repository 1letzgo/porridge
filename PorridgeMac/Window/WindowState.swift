import Foundation
import Observation

/// What the sidebar of a window shows; the Mac form of the list pages of iOS (`ListPage`).
enum SidebarPage: Hashable, Codable {
    /// The day's appointments with what is linked to them, and the to-dos due (`TodayCalendar`, `TodayTodos`).
    case today
    /// What is new or in no bowl.
    case inbox
    /// Every open to-do by due day, wherever it is filed: a view, not a place (`Todos.folder`).
    case todos
    /// The chat with the bowls.
    case chat
    /// One bowl with everything in it.
    case project(UUID)
    /// A saved search (`SmartFilter`): the entries that fit it, wherever they are.
    case smartFilter(UUID)
    case archive
    case trash
    /// The search through everything (from the toolbar's field).
    case search

    /// New things go into the open bowl; in the archive and the trash nothing is created.
    var allowsCreating: Bool { self != .archive && self != .trash }

    var projectID: UUID? {
        if case .project(let id) = self { id } else { nil }
    }

    var smartFilterID: UUID? {
        if case .smartFilter(let id) = self { id } else { nil }
    }
}

/// The kinds of elements a bowl's list or the search can be narrowed to.
enum KindFilter: String, CaseIterable, Codable {
    case todos, meetings, notes, links, images, files

    var title: String {
        switch self {
        case .todos: "To-dos"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        }
    }

    func matches(_ note: Note) -> Bool {
        switch self {
        case .todos: note.isTodo
        case .meetings: note.isRecording && !note.isLink
        case .notes: !note.isRecording && !note.isLink && !note.isStored && !note.isTodo
        case .links: note.isLink
        case .images: note.isImage
        case .files: note.isFile
        }
    }
}

/// The state of one main window: the page of the sidebar, the open note, the search. Every window and tab has
/// its own; the views follow it through Observation.
@MainActor
@Observable
final class WindowState {
    var page: SidebarPage = .inbox {
        didSet {
            guard page != oldValue else { return }
            if oldValue == .search, page != .search { clearSearch() }
            kindFilter = nil
            if page != .inbox {
                isTriaging = false
                showsLater = false
            }
            // What others added or changed in a shared bowl is seen as far as the bowl goes, on the way in and out.
            BowlSharing.shared.markVisited(oldValue.projectID)
            BowlSharing.shared.markVisited(page.projectID)
        }
    }
    /// The notes selected in the list; the detail shows one when it is exactly one.
    var selection: [UUID] = []
    /// A new note that is not saved yet; it is stored when it gets its first content.
    var draft: Note?
    /// A new note should start dictating once it shows (Settings: "Record new notes").
    var draftStartsRecording = false

    var searchText = ""
    /// Tags picked for the search; a note must have all of them.
    var searchTags: [String] = []
    /// Narrows a bowl's list or the search to one kind.
    var kindFilter: KindFilter?

    /// The Inbox in triage: J/K go through it, L puts the entry away for later, F files it, D ticks a to-do.
    var isTriaging = false
    /// The Inbox lists what was put away for later too, in a section at its end.
    var showsLater = false

    /// Which chat shows; nil is a new one that is not kept until its first question.
    var chatID: UUID?
    /// What a new chat is about (`Projects.key`); nil is all bowls.
    var chatScope: String?

    /// The note open in the detail, a new one not saved yet included.
    var openNoteID: UUID? { selection.count == 1 ? selection.first : nil }

    var hasSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || !searchTags.isEmpty || kindFilter != nil
    }

    func clearSearch() {
        searchText = ""
        searchTags = []
    }

    /// The bowl new things go into: the one that is open (not one shared with me to view only: then the inbox).
    var projectForNew: String? {
        guard let id = page.projectID, !BowlSharing.shared.isReadOnly(id) else { return nil }
        return id.uuidString
    }

    func open(_ id: UUID) {
        selection = [id]
    }

    /// Shows a note where it lives (its bowl, the inbox or the trash) and opens it; for notes reached
    /// from elsewhere, like the sources of a chat answer.
    func reveal(_ note: Note) {
        if note.isDeleted {
            page = .trash
        } else if let bucket = note.projectIDs.compactMap(UUID.init(uuidString:)).first {
            page = .project(bucket)
        } else {
            page = .inbox
            // Put away for later: its section is shown, so the entry is there.
            if note.isSnoozed() { showsLater = true }
        }
        selection = [note.id]
    }

    /// Opening the chat from a bowl or the inbox: the last chat about it is taken up again, otherwise a new one starts.
    func openChat(threads: [ChatThread]) {
        let project = projectForNew
        chatScope = project
        chatID = threads.first { $0.projectID == project }?.id
        page = .chat
    }
}
