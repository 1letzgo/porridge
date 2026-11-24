import Foundation

/// An entry of the middle column: a note, or a bowl (the Bowls place, the archive).
enum ListItem: Hashable {
    case note(UUID)
    case project(UUID)
    /// An appointment of the day (Today), by `CalendarAppointment.key`.
    case appointment(String)
    /// A fixed row that leads somewhere (Today's Open To-dos and Weekly Review; the Bowls place's smart filters,
    /// Archive and Recently Deleted).
    case link(ListLink)
}

/// Where a fixed row of the list leads.
enum ListLink: Hashable {
    case openTodos, weeklyReview, archive, trash, newSmartFilter, newBowl
    case smartFilter(UUID)
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

/// What the middle column shows for a page of the sidebar: sections of notes (and archived bowls), built from
/// the library the same way the iOS lists build them.
@MainActor
enum NoteListContent {
    struct Built {
        var sections: [(ListSection, [ListItem])]
        var emptyTitle: String
        var emptyMessage: String
        var emptySymbol: String
        /// The kinds a bowl holds, for its filter; empty elsewhere.
        var kindCounts: [KindFilter: Int] = [:]
    }

    static func build(for state: WindowState, library: Library) -> Built {
        let notes = library.notes
        switch state.page {
        case .today:
            return today(notes, day: state.todayShownDay)
        case .inbox:
            // The segment New / Later of the header: what waits, or what was put away for later.
            if state.showsLater {
                let later = InboxSnooze.snoozed(notes)
                return Built(
                    sections: later.isEmpty ? [] : [(ListSection(id: "inbox-later", title: "", tint: .navy), later.map { .note($0.id) })],
                    emptyTitle: "Nothing for Later", emptyMessage: "Put an entry away with Entry › Later or L in triage: it comes back at the time you choose.",
                    emptySymbol: "clock"
                )
            }
            let waiting = Inbox.notes(notes)
            let later = InboxSnooze.snoozed(notes)
            let next = later.compactMap(\.snoozedUntil).min().map { " " + String(localized: "\(later.count) come back from Later · next \(InboxSnooze.timeLabel($0)).") } ?? ""
            return Built(
                sections: waiting.isEmpty ? [] : [(ListSection(id: "inbox", title: "", tint: .sky), waiting.map { .note($0.id) })],
                emptyTitle: "Inbox Empty", emptyMessage: "Everything is filed. Drop files, mails or links here, or press ⌘N." + next, emptySymbol: "tray"
            )
        case .bowls:
            return bowls(notes, library: library)
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
                emptyMessage: "Open to-dos from the inbox and every bowl show up here.", emptySymbol: "checklist"
            )
        case .project(let id):
            guard let project = library.project(id) else {
                return Built(sections: [], emptyTitle: "Bowl Deleted", emptyMessage: "This bowl is gone.", emptySymbol: "folder")
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
                emptyMessage: "Add meetings, notes and links to the bowl, or drop them on it in the sidebar.",
                emptySymbol: "folder", kindCounts: counts
            )
        case .smartFilter(let id):
            guard let filter = SmartFilterStore.shared.filter(id) else {
                return Built(sections: [], emptyTitle: "Smart Filter Deleted", emptyMessage: "This smart filter is gone.", emptySymbol: "line.3.horizontal.decrease")
            }
            // Only a view: the entries stay in their bowl or the Inbox.
            let found = SmartFilters.results(filter.criteria, in: notes)
            return Built(
                sections: found.isEmpty ? [] : [(ListSection(id: "smart-filter", title: "", tint: .navy), found.map { .note($0.id) })],
                emptyTitle: "Nothing Matches",
                emptyMessage: "No entry fits this smart filter right now. Edit it to change what it looks for.",
                emptySymbol: "line.3.horizontal.decrease"
            )
        case .archive:
            // Archived bowls only: notes are never archived.
            let buckets = HomeList.archivedProjects(library.projects)
            let sections: [(ListSection, [ListItem])] = buckets.isEmpty ? [] : [
                (ListSection(id: "buckets", title: "Bowls", tint: .project), buckets.map { .project($0.id) })
            ]
            return Built(
                sections: sections, emptyTitle: "Nothing Archived",
                emptyMessage: "Archive a bowl from its context menu.", emptySymbol: "archivebox"
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

    /// Today (or the day paged to): each appointment with the entries linked to it, then the open to-dos due (on today
    /// those due before too; those under an appointment not twice). Done to-dos never show in Today.
    static func today(_ notes: [Note], day: Date) -> Built {
        let calendar = TodayCalendar.shared
        let links = AppointmentLinks.shared
        let isToday = TodayDay.isToday(day)
        let appointments = calendar.appointments(on: day)
        var sections: [(ListSection, [ListItem])] = []
        var shown = Set<UUID>()
        if calendar.status == .granted, !appointments.isEmpty {
            var items: [ListItem] = []
            for appointment in appointments {
                items.append(.appointment(appointment.key))
                for note in TodayTodos.shown(links.notes(for: appointment, among: notes)) where !shown.contains(note.id) {
                    shown.insert(note.id)
                    items.append(.note(note.id))
                }
            }
            sections.append((ListSection(id: "today-appointments", title: String(localized: "Appointments"), tint: .navy, count: appointments.count), items))
        } else if calendar.status == .denied {
            sections.append((ListSection(id: "today-appointments", title: String(localized: "Appointments"), tint: .navy,
                                         footnote: String(localized: "Allow Porridge in System Settings under Privacy & Security, Calendars, to see your appointments here.")), []))
        }
        // Only what is open: done to-dos never show in Today.
        let open = TodayTodos.open(notes, on: day).filter { !shown.contains($0.id) }
        if !open.isEmpty {
            let overdue = open.filter { $0.todoDue.flatMap { Todos.dueStatus($0) } == .overdue }.count
            sections.append((ListSection(
                id: "today-todos", title: overdue > 0 ? String(localized: "Due · \(overdue) overdue") : String(localized: "Due"),
                tint: overdue > 0 ? .red : .task, count: open.count
            ), open.map { .note($0.id) }))
        }
        if isToday {
            // The next seven days, a few rows; then the fixed rows, so Today looks the same every day.
            let upcoming = TodayTodos.upcoming(notes).filter { !shown.contains($0.id) }.prefix(5)
            if !upcoming.isEmpty {
                sections.append((ListSection(id: "today-upnext", title: String(localized: "Up Next"), tint: .navy), upcoming.map { .note($0.id) }))
            }
            sections.append((ListSection(id: "today-links", title: "", tint: .navy), [.link(.openTodos), .link(.weeklyReview)]))
        }
        return Built(
            sections: sections, emptyTitle: isToday ? "Nothing Today" : "Nothing on This Day",
            emptyMessage: isToday ? "Today's appointments and the to-dos due show up here." : "The day's appointments and the to-dos due on it show up here.",
            emptySymbol: "calendar"
        )
    }

    /// The Bowls place (⌘3): every bowl like the iPhone's tab (pinned, then all in the order of Sort Bowls By), the
    /// smart filters with "New Smart Filter…", Archive and Recently Deleted. Never empty.
    static func bowls(_ notes: [Note], library: Library) -> Built {
        let bowls = HomeList.bowls(library.projects, notes: notes)
        let pinned = bowls.filter(\.isPinned)
        let others = bowls.filter { !$0.isPinned }
        var sections: [(ListSection, [ListItem])] = []
        if !pinned.isEmpty {
            sections.append((ListSection(id: "bowls-pinned", title: String(localized: "Pinned"), tint: .project), pinned.map { .project($0.id) }))
        }
        if !others.isEmpty || pinned.isEmpty {
            sections.append((
                ListSection(id: "bowls-all", title: String(localized: "All Bowls"), tint: .project, footnote: String(localized: "by \(HomeList.bowlOrder.title)")),
                others.isEmpty ? [.link(.newBowl)] : others.map { .project($0.id) }
            ))
        }
        let filters = SmartFilterStore.shared.filters
        sections.append((ListSection(id: "bowls-filters", title: String(localized: "Smart Filters"), tint: .navy),
                         filters.map { .link(.smartFilter($0.id)) } + [.link(.newSmartFilter)]))
        sections.append((ListSection(id: "bowls-more", title: "", tint: .navy), [.link(.archive), .link(.trash)]))
        return Built(sections: sections, emptyTitle: "", emptyMessage: "", emptySymbol: "folder")
    }

    /// What the search finds among the notes, those in archived bowls included; strictly a timeline.
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
                result = result.filter { ids.contains($0.id) || $0.title.localizedCaseInsensitiveContains(text) || ($0.url?.localizedCaseInsensitiveContains(text) ?? false) || Documents.matches($0, query: text) }
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
