import SwiftData
import SwiftUI

/// The Inbox, the second place: everything in no bowl (it stays there until it is filed). On a phone the Inbox tab's
/// Inbox side (its switch Inbox | To-dos stands above, owner revision 13). Today's appointments that are in no bowl
/// yet first (`InboxAppointments`), under their header "Appointments"; then the entries, under a header "New" of their
/// own while the appointments show (without them the list starts with the entries, as before). The bundle suggestion
/// (one line) belongs to the entries: over the list, or under the "New" header. Each entry names its suggested bowl
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
    @Environment(\.usesSystemBars) private var usesSystemBars

    var body: some View {
        let waiting = Inbox.notes(notes)
        // Today's appointments not filed into a bowl (`InboxAppointments`): filing one into a bowl takes it out of here.
        let calendar = TodayCalendar.shared
        let links = AppointmentLinks.shared
        let appointments = calendar.status == .granted ? links.inboxAppointments(among: calendar.appointments, day: calendar.today) : []
        return Group {
            Group {
                if isSelecting {
                    List(selection: $chosen) {
                        if usesSystemBars {
                            // iPad: "N Selected · Select All" as the list's pinned header (`PadPageBar.inList`).
                            Section {
                                newRows(waiting)
                            } header: {
                                NoteSelectionHeader(notes: waiting, chosen: $chosen)
                                    .padding(.top, 4)
                                    .padPinnedHeader()
                            }
                        } else {
                            newRows(waiting)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                } else {
                    List(selection: $selection) {
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
                        if appointments.isEmpty {
                            if usesSystemBars {
                                // iPad: the bundle suggestion as the entries' pinned header (`PadPageBar.inList`);
                                // without a suggestion it has no height.
                                Section {
                                    newRows(waiting)
                                } header: {
                                    InboxBundleCard(notes: notes, projects: projects, sideInset: 20)
                                        .padPinnedHeader()
                                }
                            } else {
                                newRows(waiting)
                            }
                        } else {
                            // The entries under a header of their own, so they do not run on from the last
                            // appointment; the bundle suggestion under it, as a part of them.
                            Section {
                                if waiting.isEmpty {
                                    // Nothing new below appointments: the message is a part of the page, under them.
                                    EmptyStateLabel(title: Self.emptyTitle, message: Self.emptyMessage) {}
                                        .frame(maxWidth: .infinity)
                                        .listRowInsets(EdgeInsets(top: 24, leading: 20, bottom: 8, trailing: 20))
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.hidden)
                                }
                                newRows(waiting)
                            } header: {
                                VStack(spacing: 0) {
                                    ListHeader(title: Self.newTitle, count: waiting.isEmpty ? nil : waiting.count, tint: .brandSky)
                                    InboxBundleCard(notes: notes, projects: projects, sideInset: 0)
                                }
                                .background(Color.appBackground)
                            }
                        }
                    }
                }
            }
            .cardList()
            .overlay {
                // The whole page is empty: the message in its middle (adding is the "+" of the tab bar right below).
                if !isSelecting, waiting.isEmpty, appointments.isEmpty {
                    EmptyStateView(title: Self.emptyTitle, message: Self.emptyMessage)
                }
            }
        }
        // Phone: above the list. iPad: inside it (the selection header, the bundle suggestion), so the large title
        // stays sharp.
        .pageTopBar(onPad: .inList) {
            Group {
                if isSelecting {
                    NoteSelectionHeader(notes: waiting, chosen: $chosen)
                } else if appointments.isEmpty {
                    // Entries that belong together: one suggestion for a new bowl at a time (`InboxBundler`). With
                    // appointments on top it stands under the entries' header instead.
                    InboxBundleCard(notes: notes, projects: projects)
                }
            }
            .emptyStateBar()
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

    /// The header of the entries below today's appointments.
    static let newTitle = String(localized: "New")
    static let emptyTitle = "Inbox Empty"
    static let emptyMessage = "Everything is filed into a bowl. New things land here first and stay until they are filed."
}

