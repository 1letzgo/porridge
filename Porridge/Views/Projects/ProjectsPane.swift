import SwiftData
import SwiftUI

/// The projects: all of them in a list, and one opened with everything in it (meetings, notes, links, tasks),
/// filtered by kind.
struct ProjectsPane: View {
    let projects: [NoteFolder]
    let notes: [Note]
    let items: [ActionItem]
    /// The project shown; nil = the list of all projects.
    @Binding var openProject: UUID?
    /// The note open in the detail column.
    @Binding var selection: UUID?
    /// The task open in the detail column, marked in the list.
    var selectedTaskID: UUID?
    var onOpenNote: (UUID) -> Void
    var onOpenTask: (ActionItem) -> Void

    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @State private var filter = ProjectFilter.all
    @State private var renaming: NoteFolder?
    @State private var deleting: NoteFolder?
    @State private var name = ""

    var body: some View {
        Group {
            if let id = openProject, let project = projects.first(where: { $0.id == id }) {
                detail(project)
            } else {
                overview
            }
        }
        .alert("Rename Project", isPresented: .constant(renaming != nil)) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let renaming { Projects.rename(renaming, to: name, in: context) }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?", isPresented: .constant(deleting != nil), titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                if let deleting {
                    if openProject == deleting.id { openProject = nil }
                    Projects.delete(deleting, in: context)
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Its meetings, notes, links and tasks stay.")
        }
        .onChange(of: openProject) { filter = .all }
    }

    private var notesByID: [UUID: Note] {
        Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: All projects

    private var overview: some View {
        let byID = notesByID
        return List {
            ForEach(projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { project in
                let content = contents(of: project, notes: byID)
                Button { openProject = project.id } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ThingsRowIcon(systemImage: "folder.fill", tint: .brandProject)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(summary(content))
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
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = project } label: { Label("Delete", systemImage: "trash") }
                    Button { rename(project) } label: { Label("Rename", systemImage: "pencil") }
                        .tint(.brandProject)
                }
                .contextMenu {
                    Button { rename(project) } label: { Label("Rename", systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { deleting = project } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .cardList()
        .overlay {
            if projects.isEmpty {
                EmptyStateView(
                    title: "No Projects Yet",
                    message: "Create a project with the plus button, then add meetings, notes, links and tasks to it.",
                    systemImage: "folder"
                )
            }
        }
    }

    private func rename(_ project: NoteFolder) {
        name = project.name
        renaming = project
    }

    private func summary(_ content: Content) -> String {
        let parts = [
            (content.meetings.count, String(localized: "Meetings")),
            (content.notes.count, String(localized: "Notes")),
            (content.links.count, String(localized: "Links")),
            (content.tasks.count, String(localized: "Tasks")),
        ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? String(localized: "Empty") : parts.joined(separator: " · ")
    }

    // MARK: One project

    private func detail(_ project: NoteFolder) -> some View {
        let byID = notesByID
        let content = contents(of: project, notes: byID)
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProjectFilter.allCases, id: \.self) { kind in
                        chip(kind, count: content.count(kind))
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 8)
            List(selection: $selection) {
                if filter.shows(.tasks), !content.tasks.isEmpty {
                    Section {
                        ForEach(content.tasks) { item in
                            TaskRow(
                                item: item, note: item.noteID.flatMap { byID[$0] }, selectedID: selectedTaskID,
                                onOpen: onOpenNote, onEdit: onOpenTask
                            )
                        }
                    } header: { header("Tasks", tint: .brandTask) }
                }
                section("Meetings", content.meetings, kind: .meetings, tint: .brandNavy)
                section("Notes", content.notes, kind: .notes, tint: .brandSky)
                section("Links", content.links, kind: .links, tint: .brandLink)
            }
            .cardList()
            #if os(iOS)
            .contentMargins(.bottom, 96, for: .scrollContent)
            #endif
            .overlay {
                if content.count(filter) == 0 {
                    EmptyStateView(
                        title: "Nothing Here Yet",
                        message: "Add meetings, notes, links and tasks to the project from their page.",
                        systemImage: "folder"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ list: [Note], kind: ProjectFilter, tint: Color) -> some View {
        if filter.shows(kind), !list.isEmpty {
            Section {
                ForEach(list) { note in
                    ListRowLink(value: note.id) {
                        NoteRow(note: note, stage: processing.stages[note.id])
                    }
                }
            } header: { header(title, tint: tint) }
        }
    }

    private func header(_ title: LocalizedStringKey, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
            Rectangle().fill(Look.hairline).frame(height: 0.5)
        }
        .padding(.top, 8)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
        .textCase(nil)
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

    // MARK: Contents

    struct Content {
        var meetings: [Note] = []
        var notes: [Note] = []
        var links: [Note] = []
        var tasks: [ActionItem] = []

        func count(_ kind: ProjectFilter) -> Int {
            switch kind {
            case .all: meetings.count + notes.count + links.count + tasks.count
            case .meetings: meetings.count
            case .notes: notes.count
            case .links: links.count
            case .tasks: tasks.count
            }
        }

        var lastChange: Date? {
            ((meetings + notes + links).map(\.updatedAt) + tasks.map(\.updatedAt)).max()
        }
    }

    /// What is in a project, newest first; tasks open before done, as in the task list.
    private func contents(of project: NoteFolder, notes byID: [UUID: Note]) -> Content {
        let id = Projects.key(project)
        var content = Content()
        for note in notes where !note.isDeleted && note.projectIDs.contains(id) {
            if note.isLink {
                content.links.append(note)
            } else if note.isRecording {
                content.meetings.append(note)
            } else {
                content.notes.append(note)
            }
        }
        content.tasks = items
            .filter { item in
                guard item.kind == .task, item.review != .dismissed else { return false }
                if let noteID = item.noteID, let note = byID[noteID], note.isDeleted { return false }
                return Projects.contains(item, project: id, notes: byID)
            }
            .sorted { a, b in a.isDone != b.isDone ? !a.isDone : a.updatedAt > b.updatedAt }
        return content
    }
}

enum ProjectFilter: CaseIterable {
    case all, meetings, notes, links, tasks

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .links: "Links"
        case .tasks: "Tasks"
        }
    }

    func shows(_ kind: ProjectFilter) -> Bool { self == .all || self == kind }
}
