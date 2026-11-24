import SwiftData
import SwiftUI

// MARK: - Today in "Up Next"

/// The Today card beside Inbox and To-dos: how many appointments the day has and how many to-dos are due.
struct TodayTile: View {
    let notes: [Note]
    var onOpen: () -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        let calendar = TodayCalendar.shared
        let appointments = calendar.appointments
        let todos = TodayTodos.open(notes).count
        UpNextTile(title: String(localized: "Today"), systemImage: "calendar", tint: .brandNavy, onOpen: onOpen) {
            // A third of the row: the appointments, then the to-dos due, each on its own short line.
            VStack(alignment: .leading, spacing: 2) {
                if calendar.status == .granted {
                    Text(appointments.isEmpty ? String(localized: "No appointments") : appointments.count == 1 ? String(localized: "1 appointment") : String(localized: "\(appointments.count) appointments"))
                }
                if todos > 0 || calendar.status != .granted {
                    Text(todos == 0 ? String(localized: "Nothing due") : todos == 1 ? String(localized: "1 to-do") : String(localized: "\(todos) to-dos"))
                }
            }
        }
        .accessibilityIdentifier("TodayCategory")
        // Meetings recorded for an appointment are linked to it, also those from before.
        .task(id: notes.count) { AppointmentLinks.shared.linkRecentMeetings(notes, in: context) }
    }
}

// MARK: - The Today page

/// Today: the day's appointments, each with what is linked to it, then the to-dos due today or before and those
/// done today. Paged a day at a time (`TodayDay`): another day shows its appointments and the to-dos due on it.
struct TodayPage: View {
    let notes: [Note]
    /// The day shown; nil is today.
    @Binding var day: Date?
    @Binding var selection: UUID?
    var onRemove: (Note) -> Void
    /// Records a meeting for the appointment.
    var onRecord: (CalendarAppointment) -> Void
    /// A new note for the appointment, linked to it.
    var onNewNote: (CalendarAppointment) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]

    var body: some View {
        let calendar = TodayCalendar.shared
        let shown = day ?? calendar.today
        let isToday = TodayDay.isToday(shown)
        list(shown, isToday: isToday)
        .task {
            calendar.refresh()
            AppointmentLinks.shared.linkRecentMeetings(notes, in: context)
        }
        // A new day (also one that began while the app was away) starts on it again.
        .onChange(of: calendar.today) { day = nil }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { calendar.refresh() }
        }
    }

    private func list(_ shown: Date, isToday: Bool) -> some View {
        let calendar = TodayCalendar.shared
        let links = AppointmentLinks.shared
        let appointments = calendar.appointments(on: shown)
        // A to-do under one of the appointments is not listed twice.
        let underAppointments = calendar.status == .granted ? Set(appointments.flatMap { links.notes(for: $0, among: notes).map(\.id) }) : []
        let open = TodayTodos.open(notes, on: shown).filter { !underAppointments.contains($0.id) }
        let done = TodayTodos.done(notes, on: shown).filter { !underAppointments.contains($0.id) }
        let names = Dictionary(projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { a, _ in a })
        func buckets(_ note: Note) -> [String] { note.projectIDs.compactMap { names[$0] } }
        return List(selection: $selection) {
            Section {
                switch calendar.status {
                case .granted:
                    if appointments.isEmpty {
                        Text(isToday ? String(localized: "No appointments today") : String(localized: "No appointments on this day"))
                            .foregroundStyle(.secondary)
                            .cardListRow()
                            .lastInSection(true)
                    }
                    ForEach(appointments) { appointment in
                        let linked = links.notes(for: appointment, among: notes)
                        AppointmentRow(
                            appointment: appointment, bowlName: links.bowl(for: appointment).flatMap { names[$0] }, linked: linked.count,
                            projects: projects,
                            onBowl: { links.setBowl($0.map(Projects.key), for: appointment, notes: notes, in: context) },
                            onRecord: { onRecord(appointment) },
                            onNewNote: { onNewNote(appointment) }
                        )
                        .lastInSection(linked.isEmpty && appointment.id == appointments.last?.id)
                        // What belongs to it, moved in a little.
                        ForEach(linked) { note in
                            NoteListRow(note: note, buckets: buckets(note)) { onRemove(note) }
                                .padding(.leading, 24)
                                .lastInSection(note.id == linked.last?.id && appointment.id == appointments.last?.id)
                        }
                    }
                case .notDetermined:
                    Button {
                        Task { await calendar.requestAccess() }
                    } label: {
                        Label("Show Appointments", systemImage: "calendar.badge.plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.brandNavy.readable)
                    }
                    .buttonStyle(.plain)
                    .cardListRow()
                    .lastInSection(true)
                case .denied:
                    Text("Porridge may not read your calendars. Allow it in the Settings app under Privacy, Calendars.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .cardListRow()
                        .lastInSection(true)
                }
            } header: {
                ListHeader(title: String(localized: "Appointments"), count: calendar.status == .granted ? appointments.count : nil, tint: .brandNavy, isFirst: true)
            }
            Section {
                if open.isEmpty, done.isEmpty {
                    Text(isToday ? String(localized: "Nothing due today") : String(localized: "Nothing due on this day"))
                        .foregroundStyle(.secondary)
                        .cardListRow()
                        .lastInSection(true)
                }
                ForEach(open + done) { note in
                    NoteListRow(note: note, buckets: buckets(note)) { onRemove(note) }
                        .lastInSection(note.id == (open + done).last?.id)
                }
            } header: {
                ListHeader(title: String(localized: "To-dos"), count: open.isEmpty ? nil : open.count, tint: .brandTask)
            }
        }
        .cardList()
        .roomForFloatingButtons()
        .refreshable { calendar.refresh() }
    }
}

/// An appointment of the day: time, title, its bowl and how many entries are linked; its menu files it into a
/// bowl, records a meeting for it or starts a note for it.
struct AppointmentRow: View {
    let appointment: CalendarAppointment
    let bowlName: String?
    let linked: Int
    let projects: [NoteFolder]
    var onBowl: (NoteFolder?) -> Void
    var onRecord: () -> Void
    var onNewNote: () -> Void

    var body: some View {
        let isOver = appointment.end < Date()
        HStack(spacing: 12) {
            ThingsRowIcon(systemImage: "calendar", tint: .brandNavy)
            VStack(alignment: .leading, spacing: 3) {
                Text(appointment.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isOver ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(time)
                    if let bowlName {
                        Label(bowlName, systemImage: "folder.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.brandProject)
                            .lineLimit(1)
                    }
                    if linked > 0 {
                        Label("\(linked)", systemImage: "link")
                            .accessibilityLabel(linked == 1 ? String(localized: "1 linked entry") : String(localized: "\(linked) linked entries"))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu { menuItems } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(Color.brandNavy.readable)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Appointment Actions")
        }
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .cardListRow()
    }

    private var time: String {
        appointment.isAllDay
            ? String(localized: "All Day")
            : "\(appointment.start.formatted(date: .omitted, time: .shortened))–\(appointment.end.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private var menuItems: some View {
        if appointment.end > Date() {
            Button { onRecord() } label: { Label("Record Meeting", systemImage: "mic") }
        }
        Button { onNewNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
        AppointmentBowlMenu(projects: projects, current: bowlName, onChoose: onBowl)
    }
}

/// "Bowl" as a submenu: the active bowls (the current one ticked) and None.
struct AppointmentBowlMenu: View {
    let projects: [NoteFolder]
    let current: String?
    var onChoose: (NoteFolder?) -> Void

    var body: some View {
        Menu {
            Button { onChoose(nil) } label: {
                if current == nil { Label("None", systemImage: "checkmark") } else { Text("None") }
            }
            ForEach(projects.filter { !$0.isArchived && !BowlSharing.shared.isReadOnly($0.id) }) { project in
                Button { onChoose(project) } label: {
                    if project.name == current { Label(project.name, systemImage: "checkmark") } else { Text(project.name) }
                }
            }
        } label: {
            Label("Bowl", systemImage: "folder")
        }
    }
}

// MARK: - An entry's appointment

/// Choosing the appointment for an entry: a day (the entry's own at first) and its appointments.
struct AppointmentPicker: View {
    let note: Note

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var day: Date
    @State private var appointments: [CalendarAppointment] = []
    @State private var status = CalendarAccess.status

    init(note: Note) {
        self.note = note
        _day = State(initialValue: AppointmentLinks.shared.appointment(for: note.id)?.start ?? note.createdAt)
    }

    var body: some View {
        let current = AppointmentLinks.shared.appointment(for: note.id)
        NavigationStack {
            List {
                Section {
                    DatePicker("Day", selection: $day, displayedComponents: .date)
                }
                Section {
                    switch status {
                    case .granted:
                        if appointments.isEmpty {
                            Text("No appointments on this day").foregroundStyle(.secondary)
                        }
                        ForEach(appointments) { appointment in
                            Button {
                                AppointmentLinks.shared.link(note, to: appointment, in: note.modelContext ?? context)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(appointment.title).foregroundStyle(.primary)
                                        Text(appointment.isAllDay ? String(localized: "All Day") : appointment.start.formatted(date: .omitted, time: .shortened))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if current?.matches(appointment) == true {
                                        Image(systemName: "checkmark").foregroundStyle(Color.brandNavy.readable)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    case .notDetermined:
                        Button("Show Appointments") {
                            Task {
                                _ = await CalendarAccess.requestAccess()
                                load()
                            }
                        }
                    case .denied:
                        Text("Porridge may not read your calendars. Allow it in the Settings app under Privacy, Calendars.")
                            .foregroundStyle(.secondary)
                    }
                }
                if current != nil {
                    Section {
                        Button("Remove Appointment", role: .destructive) {
                            AppointmentLinks.shared.link(note, to: nil, in: context)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Appointment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: day) { load() }
            .onAppear { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        status = CalendarAccess.status
        appointments = CalendarAccess.appointments(on: day).filter { !$0.isDeclined }
    }
}

// MARK: - Related entries

/// Entries under an entry ("Similar", the same appointment): symbol, title and day, each opening the entry.
struct RelatedEntryRows: View {
    let notes: [Note]

    @Environment(\.openNote) private var openNote

    var body: some View {
        VStack(spacing: 0) {
            ForEach(notes) { other in
                Button { openNote(other.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: other.kindSymbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(other.displayTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(other.createdAt.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(other.displayTitle)")
                if other.id != notes.last?.id { Divider() }
            }
        }
    }
}
