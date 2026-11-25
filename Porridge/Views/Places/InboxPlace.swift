import SwiftData
import SwiftUI

/// The Inbox, the second place: what is new or in no bowl, and what was put away for later, as the two halves of
/// one segment (New / Later) in the first row of the content. New shows the bundle suggestion (one line) above its
/// entries (between them, today's appointments that are in no bowl yet, `InboxAppointments`); each entry names its suggested bowl ("✦ Bowl") and swipes to file or put away. At the top of New, above
/// the entries and also when it is empty, one card leads to Open To-dos and the Weekly Review (`InboxEndCard`). While choosing several,
/// "N Selected · Select All" is the first row and the selection bar takes the tab bar's place.
struct InboxPlace: View {
    let notes: [Note]
    let projects: [NoteFolder]
    @Binding var selection: UUID?
    @Binding var isSelecting: Bool
    @Binding var chosen: Set<UUID>
    /// The Later half of the segment.
    @Binding var showsLater: Bool
    var onRemove: (Note) -> Void
    /// The card at the top of New: Open To-dos and the Weekly Review.
    var onOpenTodos: () -> Void = {}
    var onReview: () -> Void = {}
    /// Records a meeting for one of today's appointments, or starts a note for it.
    var onRecord: (CalendarAppointment) -> Void = { _ in }
    var onNewNote: (CalendarAppointment) -> Void = { _ in }
    /// The appointment opened with a tap on its row.
    @State private var opened: CalendarAppointment?
    @Environment(\.modelContext) private var context

    var body: some View {
        // Read so that an entry coming back from later shows up.
        _ = InboxSnoozeScheduler.shared.tick
        let waiting = Inbox.notes(notes)
        let later = InboxSnooze.snoozed(notes)
        return VStack(spacing: 0) {
            if isSelecting {
                NoteSelectionHeader(notes: waiting, chosen: $chosen)
            } else {
                TabSwitcher(selection: $showsLater, options: [
                    (value: false, title: String(localized: "New \(waiting.count)")),
                    (value: true, title: String(localized: "Later \(later.count)")),
                ])
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("InboxSegment")
                if !showsLater {
                    // Entries that belong together: one suggestion for a new bowl at a time (`InboxBundler`).
                    InboxBundleCard(notes: notes, projects: projects)
                }
            }
            Group {
                if showsLater {
                    List(selection: $selection) {
                        ForEach(later) { note in
                            NoteListRow(note: note) { onRemove(note) }
                                .lastInSection(note.id == later.last?.id)
                        }
                    }
                } else if isSelecting {
                    List(selection: $chosen) { newRows(waiting) }
                        .environment(\.editMode, .constant(.active))
                } else {
                    List(selection: $selection) {
                        // First, above the entries (owner revision 7), also when nothing is new.
                        Section {
                            InboxEndCard(notes: notes, onOpenTodos: onOpenTodos, onReview: onReview)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
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
                                ListHeader(title: String(localized: "Appointments"), count: appointments.count, tint: .brandNavy)
                            }
                        }
                        // Nothing new: the message in the list, below the card.
                        if waiting.isEmpty {
                            Section {
                                empty(later: later)
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
            .overlay {
                if showsLater, later.isEmpty {
                    EmptyStateView(title: "Nothing for Later", message: "Put an entry away with a swipe to the left: it comes back here at the time you choose.", systemImage: "clock")
                }
            }
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
                NoteSelectionBar(notes: waiting, chosen: $chosen, offersLater: true)
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

    /// Nothing new: one sentence and when what is away comes back (adding is the "+" of the tab bar right below; a
    /// button in the list's row would make the whole row a button).
    private func empty(later: [Note]) -> some View {
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
            Text("Everything is filed into a bowl. New things land here first.")
        } actions: {
            if let next = later.compactMap(\.snoozedUntil).min() {
                Text(later.count == 1
                     ? "1 entry comes back from Later · \(InboxSnooze.timeLabel(next))"
                     : "\(later.count) entries come back from Later · next \(InboxSnooze.timeLabel(next))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// The top of the Inbox's New side (owner revision 7; the name is from revision 5, when it was at the end): one card with the two ways that used to hang at the end of Today, Open To-dos
/// ("5 open · 2 overdue") and the Weekly Review ("This Week · 8 new entries").
struct InboxEndCard: View {
    let notes: [Note]
    var onOpenTodos: () -> Void
    var onReview: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let folder = Todos.folder(notes)
        VStack(spacing: 0) {
            // "5 open · 2 overdue", the overdue part red and semibold.
            let open = Text(folder.open == 0 ? String(localized: "None open") : String(localized: "\(folder.open) open"))
            let late = Text(" · " + String(localized: "\(folder.overdue) overdue")).fontWeight(.semibold).foregroundStyle(Color.brandDangerText)
            target(
                title: String(localized: "Open To-dos"), subtitle: folder.overdue > 0 ? open + late : open,
                systemImage: "checklist", tint: .brandTask, action: onOpenTodos
            )
            .accessibilityIdentifier("InboxOpenTodos")
            Divider().padding(.leading, 14 + ThingsRowIcon.inset)
            target(
                title: String(localized: "Weekly Review"),
                subtitle: Text(String(localized: "This Week · \(Places.newThisWeek(notes)) new entries")),
                systemImage: "calendar.badge.checkmark", tint: .brandNavy, action: onReview
            )
            .accessibilityIdentifier("InboxWeeklyReview")
        }
        .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous).strokeBorder(Look.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("InboxEndCard")
    }

    private func target(title: String, subtitle: Text, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // With the largest text sizes the row is tall: the icon stays by the first line.
            HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
                ThingsRowIcon(systemImage: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
