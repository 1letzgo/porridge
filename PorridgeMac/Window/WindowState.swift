import Foundation
import Observation

/// What the sidebar of a window shows; the Mac form of the list pages of iOS (`ListPage`). The places Today, Inbox,
/// Bowls and Chat come first in the sidebar (⌘1–4), Archive and Recently Deleted last (⌘5, ⌘6).
enum SidebarPage: Hashable, Codable {
    /// The day's appointments with what is linked to them, and the to-dos due (`TodayCalendar`, `TodayTodos`).
    case today
    /// What is new or in no bowl.
    case inbox
    /// Every bowl like the iPhone's Bowls place, the smart filters, Archive and Recently Deleted (`NoteListContent`).
    case bowls
    /// Bowls on the To-dos side of its segment Bowls · To-dos (owner revision 10; before, the Inbox's To-dos side):
    /// every open to-do by due day, wherever it is filed (`Todos.folder`). View › Open To-dos, the command bar, the
    /// hint and the widgets lead here. Not a sidebar row of its own: the Bowls row stays selected.
    case todos
    /// The chat with the bowls, the fourth place (⌘4): the chats in the list column, the open one in the detail. Also
    /// AI › New Chat, Ask About This Bowl and "Ask Porridge: …" of Search or Ask.
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
    var page: SidebarPage = .today {
        didSet {
            guard page != oldValue else { return }
            if oldValue == .search, page != .search { clearSearch() }
            kindFilter = nil
            if page != .inbox { isTriaging = false }
            // Today opens on today.
            todayDay = nil
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

    /// The day Today shows; nil is today. Not kept: a window starts on today, and goes back to it when the day turns.
    var todayDay: Date?
    /// The day Today shows, today as its start.
    var todayShownDay: Date { todayDay ?? TodayCalendar.shared.today }

    /// Pages Today a day on or back (`TodayDay.step`); today is kept as nil.
    func stepToday(by days: Int) {
        let next = TodayDay.step(todayShownDay, by: days)
        todayDay = TodayDay.isToday(next) ? nil : next
    }

    /// The Inbox in triage: J/K go through it, F files the entry (into its suggested bowl, else the bowl menu), D ticks
    /// a to-do, ⌫ deletes it.
    var isTriaging = false

    /// Which chat shows; nil is a new one that is not kept until its first question.
    var chatID: UUID?
    /// What a new chat is about (`Projects.key`); nil is all bowls.
    var chatScope: String?
    /// A question handed over by Search or Ask ("Ask Porridge: …"): the chat asks it in a new chat once it shows.
    var pendingQuestion: String?

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
        }
        selection = [note.id]
    }

    /// Opening the chat from a bowl or the inbox: the last chat about it is taken up again, otherwise a new one starts.
    func openChat(threads: [ChatThread]) {
        openChat(about: projectForNew, threads: threads)
    }

    /// The chat about a bowl (`Projects.key`; nil: all bowls): the last one about it, else a new one (AI › Ask About
    /// This Bowl).
    func openChat(about project: String?, threads: [ChatThread]) {
        chatScope = project
        chatID = threads.first { $0.projectID == project }?.id
        page = .chat
    }
}
