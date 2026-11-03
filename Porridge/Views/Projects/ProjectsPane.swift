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
                VStack(spacing: 12) {
                    ThingsRowIcon(systemImage: "folder.fill", tint: .brandProject)
                    if project.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Pinned")
                    }
                }
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
                pinButton.tint(.orange)
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
                    ForEach(ProjectFilter.allCases, id: \.self) { kind in
                        chip(kind, count: content.count(kind))
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, Look.headerGap)
            List(selection: $selection) {
                let noMeetings = !filter.shows(.meetings) || content.meetings.isEmpty
                let noNotes = !filter.shows(.notes) || content.notes.isEmpty
                section("Meetings", content.meetings, kind: .meetings, tint: .brandNavy, isFirst: true)
                section("Notes", content.notes, kind: .notes, tint: .brandSky, isFirst: noMeetings)
                section("Links", content.links, kind: .links, tint: .brandLink, isFirst: noMeetings && noNotes)
            }
            .cardList()
            .roomForFloatingButtons()
            .overlay {
                if content.count(filter) == 0 {
                    EmptyStateView(
                        title: "Nothing Here Yet",
                        message: "Add meetings, notes and links to the project from their page.",
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
    var meetings: [Note] = []
    var notes: [Note] = []
    var links: [Note] = []

    init(of project: NoteFolder, notes all: [Note]) {
        let id = Projects.key(project)
        for note in all where !note.isDeleted && !note.isArchived && note.projectIDs.contains(id) {
            if note.isLink {
                links.append(note)
            } else if note.isRecording {
                meetings.append(note)
            } else {
                notes.append(note)
            }
        }
    }

    func count(_ kind: ProjectFilter) -> Int {
        switch kind {
        case .all: meetings.count + notes.count + links.count
        case .meetings: meetings.count
        case .notes: notes.count
        case .links: links.count
        }
    }

    var lastChange: Date? {
        (meetings + notes + links).map(\.updatedAt).max()
    }

    var summary: String {
        let parts = [
            (meetings.count, String(localized: "Meeting"), String(localized: "Meetings")),
            (notes.count, String(localized: "Note"), String(localized: "Notes")),
            (links.count, String(localized: "Link"), String(localized: "Links")),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        return parts.isEmpty ? String(localized: "Empty") : parts.joined(separator: " · ")
    }
}

enum ProjectFilter: CaseIterable {
    case all, meetings, notes, links

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .links: "Links"
        }
    }

    func shows(_ kind: ProjectFilter) -> Bool { self == .all || self == kind }
}
