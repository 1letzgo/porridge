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
                    Text(project.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
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
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
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
            Divider()
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

/// The inbox as the one entry of its category on the home list: what is new or in no bucket, with its own symbol.
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

/// One project opened: everything in it that is not archived (meetings, notes, links), filtered by kind.
struct ProjectPage: View {
    let project: NoteFolder
    let notes: [Note]
    /// The note open in the detail column.
    @Binding var selection: UUID?
    /// Moves a note to the trash.
    var onRemove: (Note) -> Void
    @State private var filter = ProjectFilter.all

    var body: some View {
        let content = ProjectContent(of: project, notes: notes)
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Only the kinds the bucket has something of; the one chosen stays while it is.
                    ForEach(ProjectFilter.allCases.filter { $0 == .all || $0 == filter || content.count($0) > 0 }, id: \.self) { kind in
                        chip(kind, count: content.count(kind))
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, Look.headerGap)
            List(selection: $selection) {
                section("To-dos", content.todos, kind: .todos, tint: .brandTask, isFirst: true)
                section("Meetings", content.meetings, kind: .meetings, tint: .brandNavy, isFirst: content.todos.isEmpty || !filter.shows(.todos))
                section("Notes", content.notes, kind: .notes, tint: .brandSky, isFirst: false)
                section("Links", content.links, kind: .links, tint: .brandLink, isFirst: false)
                section("Images", content.images, kind: .images, tint: .brandNavy, isFirst: false)
                section("Files", content.files, kind: .files, tint: .brandNavy, isFirst: false)
            }
            .cardList()
            .roomForFloatingButtons()
            .overlay {
                if content.count(filter) == 0 {
                    EmptyStateView(
                        title: "Nothing Here Yet",
                        message: "Add meetings, notes and links to the bucket from their page.",
                        systemImage: "folder"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ list: [Note], kind: ProjectFilter, tint: Color, isFirst: Bool) -> some View {
        if filter.shows(kind), !list.isEmpty {
            Section {
                ForEach(list) { note in
                    NoteListRow(note: note) { onRemove(note) }
                        .lastInSection(note.id == list.last?.id)
                }
            } header: { ListHeader(title: title, tint: tint, isFirst: isFirst) }
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

/// What is in a project, newest first. Archived elements are not
/// in it: they are in the archive.
struct ProjectContent {
    /// Open ones first, by due day, then those done today (done earlier ones are put away, see `Note.isPutAway`).
    var todos: [Note] = []
    var meetings: [Note] = []
    var notes: [Note] = []
    var links: [Note] = []
    var images: [Note] = []
    var files: [Note] = []

    init() {}

    init(of project: NoteFolder, notes all: [Note]) {
        let id = Projects.key(project)
        for note in all where !note.isDeleted && !note.isArchived && note.projectIDs.contains(id) { add(note) }
        sortTodos()
    }

    /// The content of every bucket in one pass over the notes, by the bucket's key (`Projects.key`). For lists of
    /// buckets: asking each bucket on its own would walk all notes once per bucket.
    static func byProject(_ all: [Note]) -> [String: ProjectContent] {
        var contents: [String: ProjectContent] = [:]
        for note in all where !note.isDeleted && !note.isArchived {
            for id in note.projectIDs { contents[id, default: ProjectContent()].add(note) }
        }
        for key in contents.keys { contents[key]?.sortTodos() }
        return contents
    }

    private mutating func sortTodos() {
        todos = Todos.byDue(todos)
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

    func shows(_ kind: ProjectFilter) -> Bool { self == .all || self == kind }
}
