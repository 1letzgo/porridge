import SwiftData
import SwiftUI

/// The Inbox, the second place: everything in no bowl (it stays there until it is filed), one list without a switch
/// (owner revision 10: the open to-dos moved to the Bowls tab). The bundle suggestion (one line) above the entries,
/// today's appointments that are in no bowl yet first (`InboxAppointments`); each entry names its suggested bowl
/// ("✦ Bowl") and swipes to file. While choosing several, "N Selected · Select All" is the first row and the selection
/// bar takes the tab bar's place.
struct InboxPlace: View {
    let notes: [Note]
    let projects: [NoteFolder]
    @Binding var selection: UUID?
    @Binding var isSelecting: Bool
    @Binding var chosen: Set<UUID>
    var onRemove: (Note) -> Void
    /// Records a meeting for one of today's appointments, or starts a note for it.
    var onRecord: (CalendarAppointment) -> Void = { _ in }
    var onNewNote: (CalendarAppointment) -> Void = { _ in }
    /// The appointment opened with a tap on its row.
    @State private var opened: CalendarAppointment?
    @Environment(\.modelContext) private var context

    var body: some View {
        let waiting = Inbox.notes(notes)
        return VStack(spacing: 0) {
            if isSelecting {
                NoteSelectionHeader(notes: waiting, chosen: $chosen)
            } else {
                // Entries that belong together: one suggestion for a new bowl at a time (`InboxBundler`).
                InboxBundleCard(notes: notes, projects: projects)
            }
            Group {
                if isSelecting {
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

