import SwiftData
import SwiftUI

/// The Inbox's two sides, one switch on top (owner revision 9): New, everything in no bowl (it stays there until it
/// is filed), and To-dos, every open to-do of the Inbox and all bowls. Every launch starts on New.
enum InboxSide: Hashable {
    case new, todos
}

/// The Inbox, the second place, with its switch New · To-dos in the first row of the content. New shows the bundle
/// suggestion (one line) above its entries, and today's appointments that are in no bowl yet first
/// (`InboxAppointments`); each entry names its suggested bowl ("✦ Bowl") and swipes to file. To-dos lists every open
/// to-do by due day (`Todos.folder`), then those done today; each row names its bowl. While choosing several (New
/// only), "N Selected · Select All" is the first row and the selection bar takes the tab bar's place.
struct InboxPlace: View {
    let notes: [Note]
    let projects: [NoteFolder]
    @Binding var selection: UUID?
    @Binding var isSelecting: Bool
    @Binding var chosen: Set<UUID>
    @Binding var side: InboxSide
    var onRemove: (Note) -> Void
    /// Records a meeting for one of today's appointments, or starts a note for it.
    var onRecord: (CalendarAppointment) -> Void = { _ in }
    var onNewNote: (CalendarAppointment) -> Void = { _ in }
    /// The appointment opened with a tap on its row.
    @State private var opened: CalendarAppointment?
    @Environment(\.modelContext) private var context

    var body: some View {
        let waiting = Inbox.notes(notes)
        let folder = Todos.folder(notes)
        return VStack(spacing: 0) {
            if isSelecting {
                NoteSelectionHeader(notes: waiting, chosen: $chosen)
            } else {
                // The counts only where there is something (owner revision 9).
                TabSwitcher(selection: $side, options: [
                    (value: InboxSide.new, title: Places.countedTitle(String(localized: "New"), waiting.count)),
                    (value: InboxSide.todos, title: Places.countedTitle(String(localized: "To-dos"), folder.open)),
                ])
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("InboxSegment")
                if side == .new {
                    // Entries that belong together: one suggestion for a new bowl at a time (`InboxBundler`).
                    InboxBundleCard(notes: notes, projects: projects)
                }
            }
            Group {
                if side == .todos, !isSelecting {
                    todos(folder)
                } else if isSelecting {
                    List(selection: $chosen) { newRows(waiting) }
                        .environment(\.editMode, .constant(.active))
                } else {
                    List(selection: $selection) {
                        // Today's appointments not filed into a bowl (`InboxAppointments`): filing one into a bowl
                        // takes it out of here.
                        let calendar = TodayCalendar.shared
                        let links = AppointmentLinks.shared
                        let appointments = calendar.status == .granted ? links.inboxAppointments(among: calendar.appointments, day: calendar.today) : []
                        if !appointments.isEmpty {
                            Section {
                                ForEach(appointments) { appointment in
                                    AppointmentRow(
                                        appointment: appointment, bowlName: nil,
                                        linked: TodayTodos.shown(links.notes(for: appointment, among: notes)).count,
                                        projects: projects,
                                        onBowl: { links.setBowl($0.map(Projects.key), for: appointment, notes: notes, in: context) },
                                        onRecord: { onRecord(appointment) },
                                        onNewNote: { onNewNote(appointment) },
                                        onOpen: { opened = appointment }
                                    )
                                    .lastInSection(appointment.id == appointments.last?.id)
                                }
                            } header: {
                                ListHeader(title: String(localized: "Appointments"), count: appointments.count, tint: .brandNavy, isFirst: true)
                            }
                        }
                        // Nothing new: the message in the list, below the appointments.
                        if waiting.isEmpty {
                            Section {
                                empty
                                    .frame(maxWidth: .infinity)
                                    .listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 8, trailing: 20))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }
                        newRows(waiting)
                    }
                }
            }
            .cardList()
        }
        .sheet(item: $opened) { appointment in
            AppointmentSheet(
                appointment: appointment, notes: notes, projects: projects,
                onRecord: onRecord, onNewNote: onNewNote, onOpenNote: { selection = $0.id }
            )
        }
        // The selection bar in the tab bar's place (`NotesView` hides the tab bar while choosing).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                NoteSelectionBar(notes: waiting, chosen: $chosen)
            }
        }
    }

    private func newRows(_ waiting: [Note]) -> some View {
        ForEach(waiting) { note in
            // While choosing, the suggestion gives way to the selection.
            NoteListRow(note: note, inInbox: true, suggestion: isSelecting ? nil : EntryMeta.suggestion(for: note, bowls: projects)) { onRemove(note) }
                .lastInSection(note.id == waiting.last?.id)
        }
    }

    /// The To-dos side (until owner revision 9 the page Open To-dos): every open to-do by due day, grouped as the
    /// search's "Open To-dos", then those done today. Each row names its bowl. Only a view: the to-dos stay where they
    /// are.
    private func todos(_ folder: Todos.Folder) -> some View {
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

    /// Nothing new: one sentence (adding is the "+" of the tab bar right below; a button in the list's row would make
    /// the whole row a button).
    private var empty: some View {
        ContentUnavailableView {
            Label {
                Text("Inbox Empty")
            } icon: {
                Image("Bowl")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } description: {
            Text("Everything is filed into a bowl. New things land here first and stay until they are filed.")
        }
    }
}

