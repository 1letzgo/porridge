import SwiftData
import SwiftUI

/// A project as a folder in a list: name, what is in it, when it last changed.
struct ProjectRow: View {
    let project: NoteFolder
    let content: ProjectContent
    var onOpen: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                ThingsRowIcon(systemImage: "folder.fill", tint: .brandProject, isPinned: project.isPinned)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(project.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        BowlSharedMark(bowlID: project.id)
                    }
                    Text(content.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let last = content.lastChange {
                    Text(last.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardListRow()
        .swipeActions(edge: .leading) {
            if !project.isArchived {
                pinButton.tint(.brandNavy)
            }
        }
        .swipeActions(edge: .trailing) {
            deleteButton
            archiveButton.tint(.brandNavy)
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                .tint(.brandProject)
        }
        .contextMenu {
            if !project.isArchived {
                pinButton
            }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            archiveButton
            BowlShareMenuItems(project: project)
            Divider()
            deleteButton
        }
    }

    /// A bowl someone shared with me is left, not deleted: the owner keeps it.
    @ViewBuilder
    private var deleteButton: some View {
        if BowlSharing.shared.isSharedWithMe(project.id) {
            Button(role: .destructive) { BowlShareController.shared.confirmLeave(project) } label: {
                Label("Leave Bowl…", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } else {
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }

    private var pinButton: some View {
        Button {
            withAnimation(.snappy) {
                project.isPinned.toggle()
                project.updatedAt = Date()
                try? context.save()
            }
        } label: {
            Label(project.isPinned ? "Unpin" : "Pin", systemImage: project.isPinned ? "pin.slash" : "pin")
        }
    }

    private var archiveButton: some View {
        Button {
            withAnimation(.snappy) { Archive.set(!project.isArchived, project, in: context) }
        } label: {
            Label(project.isArchived ? "Unarchive" : "Archive", systemImage: project.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
    }
}

/// The inbox as the one entry of its category on the home list: what is new or in no bowl, with its own symbol.
struct InboxRow: View {
    let waiting: [Note]
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                ThingsRowIcon(systemImage: "tray.fill", tint: .brandSky)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Inbox")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(waiting.isEmpty ? "Nothing waiting" : "\(waiting.count) waiting")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let last = waiting.first?.createdAt {
                    Text(last.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardListRow()
        .accessibilityIdentifier("InboxCategory")
    }
}

/// The to-dos folder as an entry of the "Up Next" section, under the Inbox: every open to-do, how many there are and how many are late.
struct TodoFolderRow: View {
    let folder: Todos.Folder
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                ThingsRowIcon(systemImage: "checklist", tint: .brandTask)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("To-dos")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 0) {
                        Text(folder.open == 0 ? String(localized: "Nothing open") : folder.open == 1 ? String(localized: "1 open") : String(localized: "\(folder.open) open"))
                            .foregroundStyle(.secondary)
                        if folder.overdue > 0 {
                            Text(" · ").foregroundStyle(.secondary)
                            Text(String(localized: "\(folder.overdue) overdue"))
                                .foregroundStyle(Color.brandDangerText)
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardListRow()
        .accessibilityIdentifier("TodosFolder")
    }
}

/// One project opened: everything in it that is not deleted (meetings, notes, links, to-dos done or not), filtered by kind.
struct ProjectPage: View {
    let project: NoteFolder
    let notes: [Note]
    /// The note open in the detail column.
    @Binding var selection: UUID?
    /// Choosing several entries to change at once (`NoteSelectionBar`), and the chosen ones.
    @Binding var isSelecting: Bool
    @Binding var chosen: Set<UUID>
    /// Moves a note to the trash.
    var onRemove: (Note) -> Void
    @State private var filter = ProjectFilter.all

    var body: some View {
        let content = ProjectContent(of: project, notes: notes)
        // One flat list without headers: pinned first, then by last change; the To-dos filter by due day.
        let list = content.list(filter)
        let rows = Section {
            ForEach(list) { note in
                NoteListRow(note: note) { onRemove(note) }
                    .lastInSection(note.id == list.last?.id)
            }
        }
        VStack(spacing: 0) {
            BowlShareLine(project: project)
            if isSelecting {
                // Choosing: what can be done with the chosen entries takes the place of the kinds.
                NoteSelectionBar(notes: list, chosen: $chosen) {
                    withAnimation(.snappy) {
                        isSelecting = false
                        chosen = []
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Only the kinds the bowl has something of; the one chosen stays while it is.
                        ForEach(ProjectFilter.allCases.filter { $0 == .all || $0 == filter || content.count($0) > 0 }, id: \.self) { kind in
                            chip(kind, count: content.count(kind))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, Look.headerGap)
            }
            Group {
                if isSelecting {
                    List(selection: $chosen) { rows }
                        .environment(\.editMode, .constant(.active))
                } else {
                    List(selection: $selection) { rows }
                }
            }
            .cardList()
            .roomForFloatingButtons()
            .overlay {
                if content.count(filter) == 0 {
                    EmptyStateView(
                        title: "Nothing Here Yet",
                        message: "Add meetings, notes and links to the bowl from their page.",
                        systemImage: "folder"
                    )
                }
            }
        }
    }

    private func chip(_ kind: ProjectFilter, count: Int) -> some View {
        let isOn = filter == kind
        return Button { withAnimation(.snappy) { filter = kind } } label: {
            HStack(spacing: 4) {
                Text(kind.title)
                Text("\(count)").foregroundStyle(isOn ? .white.opacity(0.8) : .secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOn ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isOn ? Color.brandProject : Color.brandProject.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// What is in a project, by kind (in the order of the notes given). Notes are never archived: done to-dos of
/// earlier days stay in it too. `list` gives the order the bowl shows.
struct ProjectContent {
    var todos: [Note] = []
    var meetings: [Note] = []
    var notes: [Note] = []
    var links: [Note] = []
    var images: [Note] = []
    var files: [Note] = []

    init() {}

    init(of project: NoteFolder, notes all: [Note]) {
        let id = Projects.key(project)
        for note in all where !note.isDeleted && note.projectIDs.contains(id) { add(note) }
    }

    /// The content of every bowl in one pass over the notes, by the bowl's key (`Projects.key`). For lists of
    /// bowls: asking each bowl on its own would walk all notes once per bowl.
    static func byProject(_ all: [Note]) -> [String: ProjectContent] {
        var contents: [String: ProjectContent] = [:]
        for note in all where !note.isDeleted {
            for id in note.projectIDs { contents[id, default: ProjectContent()].add(note) }
        }
        return contents
    }

    /// What the bowl shows under the filter, in its order (`Projects.ordered`).
    func list(_ filter: ProjectFilter) -> [Note] {
        switch filter {
        case .all: Projects.ordered(todos + meetings + notes + links + images + files)
        case .todos: Projects.ordered(todos, byDue: true)
        case .meetings: Projects.ordered(meetings)
        case .notes: Projects.ordered(notes)
        case .links: Projects.ordered(links)
        case .images: Projects.ordered(images)
        case .files: Projects.ordered(files)
        }
    }

    private mutating func add(_ note: Note) {
        if note.isTodo {
            todos.append(note)
        } else if note.isLink {
            links.append(note)
        } else if note.isStored {
            // Read once: telling an image from a file decodes the note's attachments.
            if note.isImage { images.append(note) } else { files.append(note) }
        } else if note.isRecording {
            meetings.append(note)
        } else {
            notes.append(note)
        }
    }

    func count(_ kind: ProjectFilter) -> Int {
        switch kind {
        case .all: todos.count + meetings.count + notes.count + links.count + images.count + files.count
        case .todos: todos.count
        case .meetings: meetings.count
        case .notes: notes.count
        case .links: links.count
        case .images: images.count
        case .files: files.count
        }
    }

    var lastChange: Date? {
        (todos + meetings + notes + links + images + files).map(\.updatedAt).max()
    }

    var summary: String {
        let open = todos.filter { !$0.isDone }.count
        let parts = [
            (open, String(localized: "Open To-do"), String(localized: "Open To-dos")),
            (meetings.count, String(localized: "Meeting"), String(localized: "Meetings")),
            (notes.count, String(localized: "Note"), String(localized: "Notes")),
            (links.count, String(localized: "Link"), String(localized: "Links")),
            (images.count, String(localized: "Image"), String(localized: "Images")),
            (files.count, String(localized: "File"), String(localized: "Files")),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        return parts.isEmpty ? String(localized: "Empty") : parts.joined(separator: " · ")
    }
}

enum ProjectFilter: CaseIterable {
    case all, todos, meetings, notes, links, images, files

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .todos: "To-dos"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        }
    }
}
