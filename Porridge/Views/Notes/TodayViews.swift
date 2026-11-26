import SwiftData
import SwiftUI

// MARK: - The Today page

/// Today: the hint of the day, the day's appointments, each with what is linked to it, then the open to-dos due today
/// or before and Up Next (the next seven days, at most five rows, foldable). Open To-dos and Weekly Review are the
/// card at the end of the Inbox (owner revision 5). Paged a day at a time (`TodayDay`): another day shows its appointments and the open to-dos due on it,
/// nothing else. Only what is open: done to-dos never show, one ticked here leaves with the undo toast.
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
    /// The hint of the day was tapped.
    var onHint: (DailyHint) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    /// Up Next folded (on this device).
    @AppStorage("todayUpNextFolded") private var upNextFolded = false
    /// The one-time "What's New" card was put away (`WhatsNew`).
    @AppStorage(WhatsNew.seenKey) private var whatsNewSeen = false
    @AppStorage(AppSettings.onboardingDoneKey) private var onboardingDone = false
    /// The appointment opened with a tap on its row.
    @State private var opened: CalendarAppointment?

    /// Up Next shows this many rows at most.
    static let upNextLimit = 5

    var body: some View {
        let calendar = TodayCalendar.shared
        let shown = day ?? calendar.today
        let isToday = TodayDay.isToday(shown)
        list(shown, isToday: isToday)
            .pageTopBar {
                // The hint of the day ("1 to-do is overdue"), today only.
                if isToday, let hint = DailyHints.shared.current {
                    DailyHintBanner(hint: hint) { onHint(hint) }
                        .emptyStateBar()
                        .transition(.opacity)
                }
            }
        .sheet(item: $opened) { appointment in
            AppointmentSheet(
                appointment: appointment, notes: notes, projects: projects,
                onRecord: onRecord, onNewNote: onNewNote, onOpenNote: { selection = $0.id }
            )
        }
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
        let underAppointments = calendar.status == .granted ? Set(appointments.flatMap { TodayTodos.shown(links.notes(for: $0, among: notes)).map(\.id) }) : []
        let open = TodayTodos.open(notes, on: shown).filter { !underAppointments.contains($0.id) }
        let overdue = open.filter { $0.todoDue.flatMap { Todos.dueStatus($0) } == .overdue }.count
        let upcoming = isToday ? Array(TodayTodos.upcoming(notes).prefix(Self.upNextLimit)) : []
        let names = Dictionary(projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { a, _ in a })
        func buckets(_ note: Note) -> [String] { note.projectIDs.compactMap { names[$0] } }
        // Nothing at all on the day (the calendar read, no appointment, nothing due, nothing up next, no card): one
        // message in the middle of the page instead of two sections that each say so (as on the Mac). With something
        // in one section the other keeps its own short line.
        let showsWhatsNew = isToday && onboardingDone && !whatsNewSeen
        if calendar.status == .granted, appointments.isEmpty, open.isEmpty, upcoming.isEmpty, !showsWhatsNew {
            return AnyView(
                EmptyStateView(
                    title: isToday ? "Nothing Today" : "Nothing on This Day",
                    message: isToday ? "Today's appointments and the to-dos due show up here." : "The day's appointments and the to-dos due on it show up here.",
                    systemImage: "calendar"
                )
                .refreshable { calendar.refresh() }
            )
        }
        return AnyView(List(selection: $selection) {
            // After the update to the three places: what moved, once, on top of today.
            if showsWhatsNew {
                Section {
                    WhatsNewCard { withAnimation(.snappy) { whatsNewSeen = true } }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
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
                        let linked = TodayTodos.shown(links.notes(for: appointment, among: notes))
                        AppointmentRow(
                            appointment: appointment, bowlName: links.bowl(for: appointment).flatMap { names[$0] }, linked: linked.count,
                            projects: projects,
                            onBowl: { links.setBowl($0.map(Projects.key), for: appointment, notes: notes, in: context) },
                            onRecord: { onRecord(appointment) },
                            onNewNote: { onNewNote(appointment) },
                            onOpen: { opened = appointment }
                        )
                        .lastInSection(linked.isEmpty && appointment.id == appointments.last?.id)
                        // What belongs to it, moved in a little.
                        ForEach(linked) { note in
                            NoteListRow(note: note, buckets: buckets(note)) { onRemove(note) }
                                .underAppointment()
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
                if open.isEmpty {
                    Text(isToday ? String(localized: "Nothing due today") : String(localized: "Nothing due on this day"))
                        .foregroundStyle(.secondary)
                        .cardListRow()
                        .lastInSection(true)
                }
                ForEach(open) { note in
                    NoteListRow(note: note, buckets: buckets(note)) { onRemove(note) }
                        .lastInSection(note.id == open.last?.id)
                }
            } header: {
                ListHeader(
                    title: overdue > 0 ? String(localized: "Due \(open.count) · \(overdue) overdue") : String(localized: "Due"),
                    count: open.isEmpty || overdue > 0 ? nil : open.count, tint: overdue > 0 ? .red : .brandTask
                )
            }
            if isToday {
                // The next seven days, a few rows, foldable.
                if !upcoming.isEmpty {
                    Section {
                        if !upNextFolded {
                            ForEach(upcoming) { note in
                                NoteListRow(note: note, buckets: buckets(note)) { onRemove(note) }
                                    .lastInSection(note.id == upcoming.last?.id)
                            }
                        }
                    } header: {
                        ListHeaderButton(title: String(localized: "Up Next"), count: upcoming.count, tint: .brandNavy, isOpen: !upNextFolded) {
                            withAnimation(.snappy) { upNextFolded.toggle() }
                        }
                        .accessibilityHint(upNextFolded ? "Shows the to-dos of the next seven days" : "Hides the to-dos of the next seven days")
                    }
                }
            }
        }
        .cardList()
        // A to-do ticked done leaves Today: the tick offers Undo.
        .environment(\.ticksLeaveList, true)
        .refreshable { calendar.refresh() })
    }
}

extension View {
    /// An entry linked to the appointment above it, moved in a little as belonging to it (Today, a bowl).
    func underAppointment() -> some View {
        padding(.leading, 24)
    }
}

/// An appointment of the day (or, in its bowl, the next occurrence of its series): time, title, its bowl and how
/// many entries are linked; a tap opens it (`AppointmentSheet`), its menu files it into a bowl, records a meeting
/// for it or starts a note for it.
struct AppointmentRow: View {
    let appointment: CalendarAppointment
    let bowlName: String?
    let linked: Int
    let projects: [NoteFolder]
    var onBowl: (NoteFolder?) -> Void
    var onRecord: () -> Void
    var onNewNote: () -> Void
    var onOpen: () -> Void = {}
    /// The day before the time ("Mon 24 Nov, 18:00–22:00"): in a bowl, where appointments of many days show.
    var showsDay = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let isOver = appointment.end < Date()
        // With the largest text sizes the row is tall: the icon stays by the first line.
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            ThingsRowIcon(systemImage: "calendar", tint: .brandNavy)
            VStack(alignment: .leading, spacing: 3) {
                Text(appointment.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isOver ? .secondary : .primary)
                    .lineLimit(2)
                // The largest text sizes: the time stays whole on its line ("18:00–22:00", never broken at "–"), the
                // bowl and the links go under it instead of being squeezed beside it.
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))) {
                    HStack(spacing: 6) {
                        Text(time)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if appointment.isRecurring {
                            Image(systemName: "repeat")
                                .imageScale(.small)
                                .accessibilityLabel("Repeats")
                        }
                    }
                    .layoutPriority(1)
                    if let bowlName {
                        Label(bowlName, systemImage: "folder.fill")
                            .labelStyle(.tight)
                            .foregroundStyle(Color.brandProject)
                            .lineLimit(1)
                    }
                    if linked > 0 {
                        Label("\(linked)", systemImage: "link")
                            .labelStyle(.tight)
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
        .onTapGesture(perform: onOpen)
        .contextMenu { menuItems }
        .accessibilityAction(named: Text("Open"), onOpen)
        .accessibilityIdentifier("AppointmentRow")
        .cardListRow()
    }

    private var time: String {
        AppointmentSheet.time(appointment, showsDay: showsDay)
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

/// An appointment opened from Today or from its bowl, read only (the calendar is never changed): title, when, where,
/// the calendar, its bowl (to change), the entries linked to it, and Record Meeting (while it is not over) and New Note.
struct AppointmentSheet: View {
    let appointment: CalendarAppointment
    let notes: [Note]
    let projects: [NoteFolder]
    var onRecord: (CalendarAppointment) -> Void
    var onNewNote: (CalendarAppointment) -> Void
    var onOpenNote: (Note) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    /// "18:00–22:00", "All Day"; with the day "Mon 24 Nov, 18:00–22:00" ("Today, …").
    static func time(_ appointment: CalendarAppointment, showsDay: Bool) -> String {
        let hours = "\(appointment.start.formatted(date: .omitted, time: .shortened))–\(appointment.end.formatted(date: .omitted, time: .shortened))"
        guard showsDay else { return appointment.isAllDay ? String(localized: "All Day") : hours }
        let day = AppointmentRef.when(start: appointment.start, isAllDay: true)
        return appointment.isAllDay ? day : "\(day), \(hours)"
    }

    var body: some View {
        let links = AppointmentLinks.shared
        let bowlKey = links.bowl(for: appointment)
        let bowl = projects.first { Projects.key($0) == bowlKey }
        let linked = links.notes(for: appointment, among: notes)
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appointment.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                        Group {
                            Label(Self.time(appointment, showsDay: true), systemImage: "clock")
                            if appointment.isRecurring {
                                Label("Repeats", systemImage: "repeat")
                            }
                            if let location = appointment.location {
                                Label(location, systemImage: "mappin.and.ellipse")
                            }
                            if !appointment.calendarName.isEmpty {
                                Label(appointment.calendarName, systemImage: "calendar")
                            }
                        }
                        .labelStyle(.tight)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section("Bowl") {
                    Label(bowl?.name ?? String(localized: "None"), systemImage: "folder.fill")
                        .labelStyle(.tight)
                        .foregroundStyle(bowl == nil ? Color.secondary : Color.brandProject)
                    AppointmentBowlMenu(projects: projects, current: bowl?.name) {
                        links.setBowl($0.map(Projects.key), for: appointment, notes: notes, in: context)
                    }
                }
                Section("Linked Entries") {
                    if linked.isEmpty {
                        Text("Nothing linked yet").foregroundStyle(.secondary)
                    }
                    ForEach(linked) { note in
                        Button {
                            dismiss()
                            onOpenNote(note)
                        } label: {
                            Text(note.displayTitle).foregroundStyle(.primary).lineLimit(2)
                        }
                    }
                }
                Section {
                    if appointment.end > Date() {
                        Button {
                            dismiss()
                            onRecord(appointment)
                        } label: { Label("Record Meeting", systemImage: "mic") }
                    }
                    Button {
                        dismiss()
                        onNewNote(appointment)
                    } label: { Label("New Note", systemImage: "square.and.pencil") }
                }
            }
            .navigationTitle("Appointment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("AppointmentSheet")
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
