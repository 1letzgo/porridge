import SwiftData
import SwiftUI

/// A bowl as a row of a list (the Bowls place, the archive): name, what is in it, how many entries. Swipe right pins
/// it, swipe left archives or deletes it; the long press is the bowl's ⋯ menu (`BowlMenuItems`).
struct ProjectRow: View {
    let project: NoteFolder
    let content: ProjectContent
    var onOpen: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void
    /// Ask About This Bowl: the chat about it.
    var onAsk: () -> Void = {}
    /// Select Entries: the bowl opens with its selection on.
    var onSelect: (() -> Void)?

    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                ThingsRowIcon(systemImage: "folder.fill", tint: .brandProject, isPinned: project.isPinned)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(project.name)
                            .foregroundStyle(.primary)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        BowlSharedMark(bowlID: project.id)
                    }
                    Text(content.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                Spacer(minLength: 0)
                // The entries and the appointments, as the bowl lists them under All.
                let count = content.count(.all) + content.appointments
                if count > 0 {
                    Text("\(count)")
                        .font(.subheadline)
                        .monospacedDigit()
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
                BowlPinButton(project: project).tint(.brandNavy)
            }
        }
        .swipeActions(edge: .trailing) {
            deleteButton
            if !BowlSharing.shared.isReadOnly(project.id) {
                BowlArchiveButton(project: project).tint(.brandNavy)
            }
        }
        .contextMenu {
            BowlMenuItems(project: project, onSelect: onSelect, onRename: onRename, onAsk: onAsk, onDelete: onDelete)
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
}

/// The bowl's menu: the ⋯ of its page, the long press of its row in the Bowls place and the archive. Select Entries,
/// Pin, Rename… | Ask About This Bowl | Manage Sharing… (or Share Bowl…), Copy Link, Export Bowl… | Archive, Stop
/// Sharing…, Delete Bowl…. A bowl shared with me offers Leave Bowl… instead of Delete; one I may only view keeps
/// Pin, Ask, Copy Link, Export Bowl… and Leave Bowl….
struct BowlMenuItems: View {
    let project: NoteFolder
    var onSelect: (() -> Void)?
    var onRename: () -> Void
    var onAsk: () -> Void
    var onDelete: () -> Void

    var body: some View {
        let readOnly = BowlSharing.shared.isReadOnly(project.id)
        let info = BowlSharing.isAvailable ? BowlSharing.shared.info(for: project.id) : nil
        Section {
            if let onSelect, !readOnly {
                Button(action: onSelect) { Label("Select Entries", systemImage: "checkmark.circle") }
            }
            if !project.isArchived {
                BowlPinButton(project: project)
            }
            if !readOnly {
                Button(action: onRename) { Label("Rename…", systemImage: "pencil") }
            }
        }
        Section {
            Button(action: onAsk) { Label("Ask About This Bowl", systemImage: "bubble.left.and.text.bubble.right") }
        }
        Section {
            if BowlSharing.isAvailable {
                if info != nil {
                    if !readOnly {
                        Button { BowlShareController.shared.manage(project) } label: {
                            Label("Manage Sharing…", systemImage: "person.2")
                        }
                    }
                    Button { BowlShareController.shared.copyLink(project) } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                } else if !readOnly {
                    ShareLink(item: BowlShareItem(bowlID: project.id, name: project.name), preview: SharePreview(project.name)) {
                        Label("Share Bowl…", systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(BowlSharing.shared.preparing.contains(project.id))
                }
            }
            ExportBowlButton(project: project)
        }
        Section {
            if !readOnly {
                BowlArchiveButton(project: project)
            }
            if let info, info.role == .owner, info.endingSince == nil {
                Button(role: .destructive) { BowlShareController.shared.confirmStopSharing(project) } label: {
                    Label("Stop Sharing…", systemImage: "person.2.slash")
                }
            }
            if BowlSharing.shared.isSharedWithMe(project.id) {
                Button(role: .destructive) { BowlShareController.shared.confirmLeave(project) } label: {
                    Label("Leave Bowl…", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button(role: .destructive, action: onDelete) { Label("Delete Bowl…", systemImage: "trash") }
            }
        }
    }
}

/// Pin or Unpin a bowl.
struct BowlPinButton: View {
    let project: NoteFolder
    @Environment(\.modelContext) private var context

    var body: some View {
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
}

/// Archive or Unarchive a bowl.
struct BowlArchiveButton: View {
    let project: NoteFolder
    @Environment(\.modelContext) private var context

    var body: some View {
        Button {
            withAnimation(.snappy) { Archive.set(!project.isArchived, project, in: context) }
        } label: {
            Label(project.isArchived ? "Unarchive" : "Archive", systemImage: project.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
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
    /// Records a meeting for one of the bowl's appointments, or starts a note for it.
    var onRecord: (CalendarAppointment) -> Void = { _ in }
    var onNewNote: (CalendarAppointment) -> Void = { _ in }
    @State private var filter = ProjectFilter.all
    /// The appointment opened with a tap on its row.
    @State private var opened: CalendarAppointment?
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @Environment(\.modelContext) private var context
    @Environment(\.usesSystemBars) private var usesSystemBars

    var body: some View {
        let content = ProjectContent(of: project, notes: notes)
        // One flat list without headers: pinned first, then by last change; the To-dos filter by due day.
        let list = content.list(filter)
        // The appointments filed into the bowl (`BowlAppointments`, one per series) are rows like the entries, where
        // the date of their occurrence puts them, with the bowl's entries linked to them moved in under them
        // (`BowlListing`, as in Today); only with All and not while choosing entries (an appointment is not chosen).
        let calendar = TodayCalendar.shared
        let links = AppointmentLinks.shared
        let filed = calendar.status == .granted ? links.appointments(inBowl: Projects.key(project), among: calendar.windowAppointments()) : []
        let appointments = filter == .all && !isSelecting ? filed : []
        let listed = links.bowlRows(list, appointments: appointments)
        let lastID = listed.last?.id
        // Nothing to list: the bars stand above the empty view (also on an iPad, `PadPageBar.above`).
        let isEmpty = content.count(filter) == 0 && appointments.isEmpty
        let items = ForEach(listed) { row in
            switch row {
            case .note(let note):
                NoteListRow(note: note) { onRemove(note) }
                    .tag(note.id)
                    .lastInSection(row.id == lastID)
            case .appointment(let appointment, let linked):
                AppointmentRow(
                    appointment: appointment, bowlName: nil,
                    linked: linked.count,
                    projects: projects,
                    onBowl: { links.setBowl($0.map(Projects.key), for: appointment, notes: notes, in: context) },
                    onRecord: { onRecord(appointment) },
                    onNewNote: { onNewNote(appointment) },
                    onOpen: { opened = appointment },
                    showsDay: true
                )
                .lastInSection(linked.isEmpty && row.id == lastID)
                // What belongs to it, moved in a little (as in Today).
                ForEach(linked) { note in
                    NoteListRow(note: note) { onRemove(note) }
                        .underAppointment()
                        .lastInSection(note.id == linked.last?.id && row.id == lastID)
                }
            }
        }
        let rows = Group {
            if usesSystemBars, !isEmpty {
                // iPad: the share line and the chips (or "N Selected · Select All") as the list's pinned header
                // (`PadPageBar.inList`), so the bowl's large title stays sharp and collapses above them.
                Section {
                    items
                } header: {
                    bar(content: content, list: list, filed: filed)
                        .padPinnedHeader()
                }
            } else {
                Section { items }
            }
        }
        Group {
            Group {
                if isSelecting {
                    List(selection: $chosen) { rows }
                        .environment(\.editMode, .constant(.active))
                } else {
                    List(selection: $selection) { rows }
                }
            }
            .cardList()
            // What others added or changed is seen as far as the bowl goes, on the way in and on the way out.
            .onAppear { BowlSharing.shared.markVisited(project.id) }
            .onDisappear { BowlSharing.shared.markVisited(project.id) }
            .sheet(item: $opened) { appointment in
                AppointmentSheet(
                    appointment: appointment, notes: notes, projects: projects,
                    onRecord: onRecord, onNewNote: onNewNote, onOpenNote: { selection = $0.id }
                )
            }
            .overlay {
                if content.count(filter) == 0, appointments.isEmpty {
                    EmptyStateView(
                        title: "Nothing Here Yet",
                        message: "Add to the bowl with +, or move entries into it from their Details.",
                        systemImage: "folder"
                    )
                }
            }
        }
        // The share line and the chips: bars for the empty bowl's message (`emptyStateBar`). Phone: above the list;
        // iPad: inside it, or above the empty bowl's message.
        .pageTopBar(onPad: isEmpty ? .above : .inList) {
            if !usesSystemBars || isEmpty {
                bar(content: content, list: list, filed: filed)
                    .emptyStateBar()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                NoteSelectionBar(notes: list, chosen: $chosen)
            }
        }
        // iPad, the empty bowl: its list does not start right under the navigation bar (the bars stand above the
        // message), so the bar took the look of a scrolled page, with a hairline across the list column under it.
        // No other page has that line at rest.
        .toolbarBackground(usesSystemBars && isEmpty ? .hidden : .automatic, for: .navigationBar)
    }

    /// The share line, then the kinds as chips, or "N Selected · Select All" while choosing.
    private func bar(content: ProjectContent, list: [Note], filed: [CalendarAppointment]) -> some View {
        VStack(spacing: 0) {
            BowlShareLine(project: project)
            if isSelecting {
                // Choosing: "N Selected · Select All" takes the place of the kinds, the bar the tab bar's.
                NoteSelectionHeader(notes: list, chosen: $chosen)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // Only the kinds the bowl has something of; the one chosen stays while it is.
                        ForEach(ProjectFilter.allCases.filter { $0 == .all || $0 == filter || content.count($0) > 0 }, id: \.self) { kind in
                            // All counts the appointments too: they are rows of it.
                            chip(kind, count: content.count(kind) + (kind == .all ? filed.count : 0))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, Look.headerGap)
            }
        }
    }

    private func chip(_ kind: ProjectFilter, count: Int) -> some View {
        let isOn = filter == kind
        return Button { withAnimation(.snappy) { filter = kind } } label: {
            HStack(spacing: 4) {
                Text(kind.title)
                // The count only where there is one (owner revision 9: no "0" on a chip).
                if count > 0 {
                    Text("\(count)").foregroundStyle(isOn ? .white.opacity(0.8) : .secondary)
                }
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
    /// The appointments filed into the bowl (each series once, `BowlAppointments.counts`): a bowl with appointments
    /// is not empty.
    var appointments = 0

    init() {}

    init(of project: NoteFolder, notes all: [Note]) {
        let id = Projects.key(project)
        for note in all where !note.isDeleted && note.projectIDs.contains(id) { add(note) }
    }

    /// The content of every bowl in one pass over the notes, by the bowl's key (`Projects.key`). For lists of
    /// bowls: asking each bowl on its own would walk all notes once per bowl.
    static func byProject(_ all: [Note], appointments: [String: Int] = [:]) -> [String: ProjectContent] {
        var contents: [String: ProjectContent] = [:]
        for note in all where !note.isDeleted {
            for id in note.projectIDs { contents[id, default: ProjectContent()].add(note) }
        }
        for (id, count) in appointments { contents[id, default: ProjectContent()].appointments = count }
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
        let all = (appointments > 0 ? [appointments == 1 ? String(localized: "1 Appointment") : String(localized: "\(appointments) Appointments")] : []) + parts
        return all.isEmpty ? String(localized: "Empty") : all.joined(separator: " · ")
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
