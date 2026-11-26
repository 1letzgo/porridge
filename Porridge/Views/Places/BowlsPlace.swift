import SwiftData
import SwiftUI

/// Bowls, the third place, on the Bowls side of its switch (Bowls · To-dos, `BowlsSide`): every bowl (pinned first,
/// then "All Bowls" in the order of Sort Bowls By, no limit), then the smart filters with "New Smart Filter…", always
/// there, and last the section Archive with its one row (owner revision 10), which opens the archived bowls.
struct BowlsPlace: View {
    let notes: [Note]
    let projects: [NoteFolder]
    let order: HomeList.BowlOrder
    var onOpen: (ListPage) -> Void
    var onNewBowl: () -> Void
    var onRename: (NoteFolder) -> Void
    var onDelete: (NoteFolder) -> Void
    /// Select Entries from a bowl's long press: its page opens choosing.
    var onSelect: (NoteFolder) -> Void
    var onAsk: (NoteFolder) -> Void
    var onNewSmartFilter: () -> Void
    var onEditFilter: (SmartFilter) -> Void
    var onRenameFilter: (SmartFilter) -> Void
    var onDeleteFilter: (SmartFilter) -> Void

    var body: some View {
        let bowls = HomeList.bowls(projects, notes: notes, order: order)
        let pinned = bowls.filter(\.isPinned)
        let others = bowls.filter { !$0.isPinned }
        let contents = ProjectContent.byProject(notes, appointments: AppointmentLinks.shared.appointmentCounts())
        let filters = SmartFilterStore.shared.filters
        List {
            if bowls.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Bowls Yet")
                            .font(.headline)
                        Text("A bowl holds everything about one topic.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(action: onNewBowl) {
                            Label("New Bowl", systemImage: "folder.badge.plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brandProject)
                        .accessibilityIdentifier("BowlsEmptyNewBowl")
                    }
                    .padding(.vertical, 6)
                    .cardListRow()
                    .lastInSection(true)
                } header: {
                    ListHeader(title: String(localized: "All Bowls"), tint: .brandProject, isFirst: true)
                }
            }
            if !pinned.isEmpty {
                CardSection {
                    rows(pinned, contents: contents)
                } header: {
                    ListHeader(title: String(localized: "Pinned"), tint: .brandProject, isFirst: true)
                }
            }
            if !others.isEmpty {
                CardSection {
                    rows(others, contents: contents)
                } header: {
                    ListHeader(
                        title: String(localized: "All Bowls"), tint: .brandProject, isFirst: pinned.isEmpty,
                        detail: String(localized: "by \(order.title)")
                    )
                }
            }
            // Saved searches: only views, nothing is moved into them.
            CardSection {
                ForEach(filters) { filter in
                    SmartFilterRow(
                        filter: filter, count: SmartFilters.results(filter.criteria, in: notes).count,
                        onOpen: { onOpen(.smartFilter(filter.id)) }, onEdit: { onEditFilter(filter) },
                        onRename: { onRenameFilter(filter) }, onDelete: { onDeleteFilter(filter) }
                    )
                }
                PlaceLinkRow(title: String(localized: "New Smart Filter…"), systemImage: "plus", tint: .brandNavy, showsChevron: false, action: onNewSmartFilter)
                    .lastInSection(true)
                    .accessibilityIdentifier("NewSmartFilter")
            } header: {
                ListHeader(title: String(localized: "Smart Filters"), tint: .brandNavy)
            }
            // The archived bowls, a page of their own (owner revision 10; before, a side of the switch). Always there,
            // the count only when something is archived.
            CardSection {
                PlaceLinkRow(
                    title: String(localized: "Archive"), systemImage: "archivebox.fill", tint: .brandNavy,
                    count: HomeList.archivedProjects(projects).count
                ) { onOpen(.archive) }
                    .lastInSection(true)
                    .accessibilityIdentifier("BowlsArchive")
            } header: {
                ListHeader(title: String(localized: "Archive"), tint: .brandNavy)
            }
        }
        .cardList()
    }

    private func rows(_ bowls: [NoteFolder], contents: [String: ProjectContent]) -> some View {
        ForEach(bowls) { project in
            ProjectRow(
                project: project,
                content: contents[Projects.key(project)] ?? ProjectContent(),
                onOpen: { onOpen(.project(project.id)) },
                onRename: { onRename(project) },
                onDelete: { onDelete(project) },
                onAsk: { onAsk(project) },
                onSelect: { onSelect(project) }
            )
            .lastInSection(project.id == bowls.last?.id)
        }
    }
}

/// The Bowls tab's To-dos side (owner revision 10; before, the Inbox's To-dos side and the page Open To-dos): every
/// open to-do by due day, grouped as the search's "Open To-dos", then those done today. Each row names its bowl. Only
/// a view: the to-dos stay where they are.
struct OpenTodosList: View {
    let notes: [Note]
    let projects: [NoteFolder]
    @Binding var selection: UUID?
    var onRemove: (Note) -> Void

    var body: some View {
        let folder = Todos.folder(notes)
        let names = Dictionary(projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { a, _ in a })
        func buckets(_ note: Note) -> [String] { note.projectIDs.compactMap { names[$0] } }
        return List(selection: $selection) {
            ForEach(Array(folder.groups.enumerated()), id: \.element.title) { index, group in
                Section {
                    ForEach(group.notes) { note in
                        NoteListRow(note: note, buckets: buckets(note)) { onRemove(note) }
                            .lastInSection(note.id == group.notes.last?.id)
                    }
                } header: {
                    ListHeader(
                        title: group.title, count: group.notes.count,
                        tint: group.title == String(localized: "Overdue") ? .red : .brandTask, isFirst: index == 0
                    )
                }
            }
            if !folder.doneToday.isEmpty {
                Section {
                    ForEach(folder.doneToday) { note in
                        NoteListRow(note: note, buckets: buckets(note)) { onRemove(note) }
                            .lastInSection(note.id == folder.doneToday.last?.id)
                    }
                } header: {
                    ListHeader(title: String(localized: "Done Today"), count: folder.doneToday.count, tint: .brandNavy, isFirst: folder.groups.isEmpty)
                }
            }
        }
        .cardList()
        .overlay {
            if folder.isEmpty {
                EmptyStateView(title: "Nothing to Do", message: "Open to-dos from the inbox and every bowl show up here.", systemImage: "checklist")
            }
        }
    }
}

/// A fixed row that leads somewhere (Archive, New Smart Filter…): a
/// symbol in its color, the name, a line about what is there and how many.
struct PlaceLinkRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color
    var count: Int?
    var showsChevron = true
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            // With the largest text sizes the row is tall: the icon stays by the first line.
            HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
                ThingsRowIcon(systemImage: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardListRow()
    }
}
