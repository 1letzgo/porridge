import Foundation

/// An entry of the middle column: a note, or a bucket (in the archive).
enum ListItem: Hashable {
    case note(UUID)
    case project(UUID)
}

/// A section of the middle column: its header and color.
struct ListSection: Hashable {
    enum Tint: Hashable { case sky, navy, project, link, red, task }
    let id: String
    let title: String
    let tint: Tint
    /// A line under the header (the trash says when notes go).
    var footnote: String?
    /// How many entries the section holds, beside its title (the to-dos folder's groups).
    var count: Int?
}

/// What the middle column shows for a page of the sidebar: sections of notes (and archived buckets), built from
/// the library the same way the iOS lists build them.
@MainActor
enum NoteListContent {
    struct Built {
        var sections: [(ListSection, [ListItem])]
        var emptyTitle: String
        var emptyMessage: String
        var emptySymbol: String
        /// The kinds a bucket holds, for its filter; empty elsewhere.
        var kindCounts: [KindFilter: Int] = [:]
    }

    static func build(for state: WindowState, library: Library) -> Built {
        let notes = library.notes
        switch state.page {
        case .inbox:
            let waiting = Inbox.notes(notes)
            return Built(
                sections: waiting.isEmpty ? [] : [(ListSection(id: "inbox", title: "", tint: .sky), waiting.map { .note($0.id) })],
                emptyTitle: "Inbox Empty", emptyMessage: "What is new or in no bucket waits here.", emptySymbol: "tray"
            )
        case .todos:
            // Exactly the groups of the search's "Open To-dos", then those done today (`Todos.folder`).
            let folder = Todos.folder(notes)
            var sections = folder.groups.enumerated().map { index, group -> (ListSection, [ListItem]) in
                let late = group.notes.first.flatMap { TodoBridge.dueStatus(of: $0) } == .overdue
                return (ListSection(id: "folder-\(index)-" + group.title, title: group.title, tint: late ? .red : .task, count: group.notes.count),
                        group.notes.map { .note($0.id) })
            }
            if !folder.doneToday.isEmpty {
                sections.append((ListSection(id: "folder-done", title: String(localized: "Done Today"), tint: .navy, count: folder.doneToday.count),
                                 folder.doneToday.map { .note($0.id) }))
            }
            return Built(
                sections: sections, emptyTitle: "Nothing to Do",
                emptyMessage: "Open to-dos from the inbox and every bucket show up here.", emptySymbol: "checklist"
            )
        case .project(let id):
            guard let project = library.project(id) else {
                return Built(sections: [], emptyTitle: "Bucket Deleted", emptyMessage: "This bucket is gone.", emptySymbol: "folder")
            }
            let key = Projects.key(project)
            let content = notes.filter { !$0.isDeleted && $0.projectIDs.contains(key) }
            var counts: [KindFilter: Int] = [:]
            var shown: [Note] = []
            for note in content {
                guard let kind = KindFilter.allCases.first(where: { $0.matches(note) }) else { continue }
                counts[kind, default: 0] += 1
                if state.kindFilter == nil || state.kindFilter == kind { shown.append(note) }
            }
            // One flat list without headers: pinned first, then by last change; the To-dos filter by due day.
            let sorted = Projects.ordered(shown, byDue: state.kindFilter == .todos)
            let sections: [(ListSection, [ListItem])] = sorted.isEmpty ? [] : [(ListSection(id: "bucket", title: "", tint: .sky), sorted.map { .note($0.id) })]
            return Built(
                sections: sections, emptyTitle: "Nothing Here Yet",
                emptyMessage: "Add meetings, notes and links to the bucket, or drop them on it in the sidebar.",
                emptySymbol: "folder", kindCounts: counts
            )
        case .archive:
            // Archived buckets only: notes are never archived.
            let buckets = HomeList.archivedProjects(library.projects)
            let sections: [(ListSection, [ListItem])] = buckets.isEmpty ? [] : [
                (ListSection(id: "buckets", title: "Buckets", tint: .project), buckets.map { .project($0.id) })
            ]
            return Built(
                sections: sections, emptyTitle: "Nothing Archived",
                emptyMessage: "Archive a bucket from its context menu.", emptySymbol: "archivebox"
            )
        case .trash:
            let deleted = notes.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
            return Built(
                sections: deleted.isEmpty ? [] : [(
                    ListSection(id: "trash", title: "Recently Deleted", tint: .red, footnote: "Notes are deleted after \(NoteStore.trashDays) days."),
                    deleted.map { .note($0.id) }
                )],
                emptyTitle: "Nothing Deleted", emptyMessage: "Deleted notes stay here for \(NoteStore.trashDays) days.", emptySymbol: "trash"
            )
        case .search:
            let found = search(notes, state: state)
            let query = state.searchText.isEmpty ? state.searchTags.map { "#" + $0 }.joined(separator: " ") : state.searchText
            return Built(
                // The open to-dos by when they are due; everything else by when it changed.
                sections: !state.hasSearch ? [] : state.kindFilter == .todos ? dueSections(found) : dateSections(found),
                emptyTitle: state.hasSearch ? "No Results for “\(query)”" : "Search",
                emptyMessage: state.hasSearch ? "Check the spelling or try a new search." : "Type a word to search your notes, meetings and links, or pick a tag.",
                emptySymbol: "magnifyingglass"
            )
        case .chat:
            return Built(sections: [], emptyTitle: "", emptyMessage: "", emptySymbol: "bubble.left.and.bubble.right")
        }
    }

    /// What the search finds among the notes, those in archived buckets included; strictly a timeline.
    static func search(_ notes: [Note], state: WindowState) -> [Note] {
        var result = notes.filter { !$0.isDeleted }
        if let kind = state.kindFilter {
            // In the search the chip is "Open To-dos": not done.
            result = result.filter { kind == .todos ? $0.isTodo && !$0.isDone : kind.matches($0) }
        }
        if !state.searchTags.isEmpty {
            let wanted = state.searchTags.map { $0.lowercased() }
            result = result.filter { note in
                let tags = Set(note.tags.map { $0.lowercased() })
                return wanted.allSatisfy(tags.contains)
            }
        }
        let text = state.searchText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            // The index knows the words of every passage (transcripts included) without decoding anything.
            if let ids = NoteIndex.shared.noteIDs(matching: text) {
                result = result.filter { ids.contains($0.id) || $0.title.localizedCaseInsensitiveContains(text) || ($0.url?.localizedCaseInsensitiveContains(text) ?? false) }
            } else {
                result = result.filter { $0.matches(text) }
            }
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Open to-dos under Overdue, Today, Upcoming and No Due Date (the shared grouping of `Todos.dueGroups`).
    static func dueSections(_ list: [Note]) -> [(ListSection, [ListItem])] {
        Todos.dueGroups(list).enumerated().map { index, group in
            let tint: ListSection.Tint = switch group.notes.first.flatMap({ TodoBridge.dueStatus(of: $0) }) {
            case .overdue?: .red
            case .today?: .task
            default: .navy
            }
            return (ListSection(id: "due-\(index)-" + group.title, title: group.title, tint: tint), group.notes.map { .note($0.id) })
        }
    }

    /// Notes under headings like Today, Yesterday, Previous 7 Days, months and years.
    static func dateSections(_ list: [Note]) -> [(ListSection, [ListItem])] {
        let calendar = Calendar.current
        let now = Date()
        var result: [(ListSection, [ListItem])] = []
        for note in list {
            let date = note.updatedAt
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
            let title: String
            if calendar.isDateInToday(date) {
                title = String(localized: "Today")
            } else if calendar.isDateInYesterday(date) {
                title = String(localized: "Yesterday")
            } else if days <= 7 {
                title = String(localized: "Previous 7 Days")
            } else if days <= 30 {
                title = String(localized: "Previous 30 Days")
            } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                title = date.formatted(.dateTime.month(.wide))
            } else {
                title = date.formatted(.dateTime.year())
            }
            if result.last?.0.title == title {
                result[result.count - 1].1.append(.note(note.id))
            } else {
                result.append((ListSection(id: "date-" + title, title: title, tint: .sky), [.note(note.id)]))
            }
        }
        return result
    }

    /// The tags of the notes with how many notes have them, by name.
    static func tagCounts(_ notes: [Note]) -> [(key: String, name: String, count: Int)] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for note in notes where !note.isDeleted {
            for tag in note.tags {
                let key = tag.lowercased()
                if names[key] == nil { names[key] = tag }
                counts[key, default: 0] += 1
            }
        }
        return names.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { (key: $0, name: names[$0]!, count: counts[$0]!) }
    }
}
