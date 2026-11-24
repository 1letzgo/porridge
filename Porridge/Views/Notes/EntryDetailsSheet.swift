import SwiftData
import SwiftUI

/// Which Details to open, and at which section (nil: the top).
struct DetailsRequest: Identifiable, Equatable {
    let id = UUID()
    var section: EntryDetails.Section.Kind?
}

/// Details of an entry (iPhone): every property in its fixed place, in the order of `EntryDetails` – Organize ·
/// Appointment · Document · Speakers · Connections · Sharing & Activity. Empty values say "None". In Recently
/// Deleted and in bowls shared to view only nothing can be changed here.
struct EntryDetailsSheet: View {
    let note: Note
    /// "Changed by Anna", as it was when the entry was opened (opening it marked it as seen).
    let activity: String?
    /// Where it opens.
    let section: EntryDetails.Section.Kind?
    /// Opens another entry once the sheet is closed.
    let openEntry: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @Environment(\.allNotes) private var allNotes
    @Query(sort: \NoteFolder.name) private var bowls: [NoteFolder]

    @State private var pickingDue = false
    @State private var pickingAppointment = false
    @State private var editingDocument = false
    @State private var showPages = false
    @State private var showVoices = false
    @State private var addingTag = false
    @State private var newTag = ""
    @State private var creatingBowl = false
    @State private var bowlName = ""
    @State private var renaming: Speaker?
    @State private var renameText = ""
    @State private var linkedFrom: [Note] = []
    @State private var mentions: [Note] = []
    @State private var similar: [Note] = []
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 84

    private enum Page: Hashable {
        case linkedFrom, similar, sameAppointment
    }

    private var entryContext: EntryContext {
        var state = EntryContext.live(for: note, bowls: bowls, processing: processing)
        if !note.isDeleted { state.activityLine = state.activityLine ?? activity }
        return state
    }

    var body: some View {
        let state = entryContext
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    ForEach(EntryDetails.sections(for: note, context: state)) { section in
                        Section {
                            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                rowView(row, state: state)
                                    .font(.subheadline)
                                    .id(index == 0 ? AnyHashable(section.kind) : AnyHashable(row.kind))
                            }
                        } header: {
                            header(section, state: state)
                        }
                    }
                }
                .task {
                    guard let section else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(.snappy) { proxy.scrollTo(section, anchor: .top) }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: Page.self) { page in
                connectionPage(page)
            }
        }
        .presentationDetents([.medium, .large])
        .environment(\.openNote) { id in open(id) }
        .task(id: EntryLinks.scanSignature(for: note, among: allNotes)) {
            guard !note.isDeleted, note.modelContext != nil else { return }
            similar = SimilarEntries.similar(to: note, among: allNotes)
            let found = await EntryLinks.linkedFromAndMentions(of: note, among: allNotes)
            guard !Task.isCancelled else { return }
            linkedFrom = found.linkedFrom
            mentions = found.mentions
        }
        .sheet(isPresented: $pickingDue) { DueDatePickerSheet(note: note) }
        .sheet(isPresented: $pickingAppointment) { AppointmentPicker(note: note) }
        .sheet(isPresented: $editingDocument) { DocumentInfoSheet(note: note) }
        .sheet(isPresented: $showPages) { PDFPageEditor(note: note) }
        .sheet(isPresented: $showVoices) { KnownVoicesSheet() }
        .alert("New Tag", isPresented: $addingTag) {
            TextField("Tag", text: $newTag)
            Button("Add", action: addTag)
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Bowl", isPresented: $creatingBowl) {
            TextField("Name", text: $bowlName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let bowl = Projects.create(bowlName, in: context) {
                    Undoable.move([note], toBowl: Projects.key(bowl), named: bowl.name, in: context)
                }
            }
        }
        .alert("Rename Speaker", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming {
                    SpeakerNaming.rename(renaming.id, to: renameText, in: note, context: context, processing: processing)
                }
                renaming = nil
            }
        }
    }

    // MARK: Sections

    private func header(_ section: EntryDetails.Section, state: EntryContext) -> some View {
        HStack {
            Text(section.kind.title).fontWeight(.bold)
            Spacer(minLength: 8)
            if let action = section.action {
                Button(actionTitle(action, state: state)) { run(action) }
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                    .buttonStyle(.borderless)
                    .disabled(action == .changeAppointment && note.modelContext == nil)
            }
        }
    }

    private func actionTitle(_ action: EntryDetails.Section.Action, state: EntryContext) -> String {
        switch action {
        case .changeAppointment: state.appointment == nil ? String(localized: "Link…") : String(localized: "Change…")
        case .editPages: String(localized: "Edit Pages…")
        case .knownVoices: String(localized: "Known Voices…")
        }
    }

    private func run(_ action: EntryDetails.Section.Action) {
        switch action {
        case .changeAppointment: pickingAppointment = true
        case .editPages: showPages = true
        case .knownVoices: showVoices = true
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func rowView(_ row: EntryDetails.Row, state: EntryContext) -> some View {
        let label = EntryDetails.label(row.kind, for: note)
        let locked = row.isLocked
        switch row.kind {
        case .type:
            DetailsRow(label: label, width: labelWidth) {
                Text(EntryDetails.typeName(for: note))
                Spacer(minLength: 8)
                if EntryDetails.showsTodoSwitch(note) {
                    Toggle("To-do", isOn: Binding(
                        get: { note.isTodo },
                        set: { value in withAnimation(.snappy) { Todos.setTodo(value, note, in: context) } }
                    ))
                    .fixedSize()
                    .tint(.brandTask)
                    .disabled(!EntryDetails.canSwitchTodo(note, context: state))
                }
            }
        case .bowl:
            DetailsRow(label: label, width: labelWidth) {
                if locked {
                    bowlLabel(state)
                } else {
                    Menu { bowlChoices } label: {
                        HStack(spacing: 4) {
                            bowlLabel(state)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Bowl")
                    .accessibilityValue(currentBowl(state)?.name ?? String(localized: "Inbox"))
                }
            }
        case .suggestedBowl:
            if let bowl = EntryDetails.suggestion(for: note, context: state) {
                DetailsRow(label: label, width: labelWidth) {
                    IconText(text: bowl.name, symbol: "sparkles")
                        .foregroundStyle(Color.brandProjectText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("File") {
                        withAnimation(.snappy) { Undoable.move([note], toBowl: Projects.key(bowl), named: bowl.name, in: context) }
                    }
                    .buttonStyle(.bordered)
                    .tint(.brandProject)
                    .accessibilityLabel("File into \(bowl.name)")
                    Button {
                        withAnimation(.snappy) { Inbox.dismissSuggestions(note, in: context) }
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Drop Suggestion")
                }
            }
        case .due:
            DetailsRow(label: label, width: labelWidth) {
                Menu {
                    ForEach(Todos.DueChoice.allCases, id: \.self) { choice in
                        Button {
                            withAnimation(.snappy) { Todos.setDue(Todos.dueKey(for: choice), note, in: context) }
                        } label: {
                            Label(choice.title, systemImage: choice.systemImage)
                        }
                    }
                    Button { pickingDue = true } label: { Label("Pick Date…", systemImage: "calendar") }
                    if note.todoDue != nil {
                        Divider()
                        Button(role: .destructive) {
                            withAnimation(.snappy) { Todos.setDue(nil, note, in: context) }
                        } label: {
                            Label("Clear Due Date", systemImage: "calendar.badge.minus")
                        }
                    }
                } label: {
                    if let due = note.todoDue {
                        Text(Todos.dueLabel(due))
                            .foregroundStyle(note.isOverdue ? Color.brandDangerText : Color.brandTaskText)
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                .disabled(locked)
                .accessibilityLabel("Due Date")
            }
        case .repeat:
            DetailsRow(label: label, width: labelWidth) {
                Menu {
                    RepeatMenuItems(note: note) { pickingDue = true }
                } label: {
                    Text(note.todoRepeat?.title ?? String(localized: "Never"))
                        .foregroundStyle(note.todoRepeat == nil ? Color.secondary : Color.brandTaskText)
                }
                .disabled(locked)
                .accessibilityLabel("Repeat")
            }
        case .tags:
            DetailsRow(label: label, width: labelWidth) {
                tagsView(locked: locked)
            }
        case .appointment:
            DetailsRow(label: label, width: labelWidth) {
                if let ref = state.appointment {
                    Menu {
                        Button { pickingAppointment = true } label: { Label("Change Appointment…", systemImage: "calendar") }
                        Button(role: .destructive) {
                            withAnimation(.snappy) { AppointmentLinks.shared.link(note, to: nil, in: context) }
                        } label: {
                            Label("Remove Appointment", systemImage: "calendar.badge.minus")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ref.title).foregroundStyle(Color.brandNavy).lineLimit(2).multilineTextAlignment(.leading)
                            Text(ref.when).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(locked)
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
        case .sameAppointment:
            let others = AppointmentLinks.shared.others(linkedWith: note, among: allNotes)
            DetailsRow(label: label, width: labelWidth) {
                if others.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    NavigationLink(value: Page.sameAppointment) {
                        Text(others.count == 1 ? String(localized: "1 more entry") : String(localized: "\(others.count) more entries"))
                    }
                }
            }
        case .documentKind:
            let info = note.documentInfo ?? DocumentInfo()
            DetailsRow(label: label, width: labelWidth) {
                Menu {
                    Button("Not Set") { Undoable.apply(.kind(nil), to: [note], in: context) }
                    Divider()
                    ForEach(DocumentKind.allCases) { kind in
                        Button { Undoable.apply(.kind(kind), to: [note], in: context) } label: {
                            if info.kind == kind { Label(kind.title, systemImage: "checkmark") } else { Label(kind.title, systemImage: kind.symbol) }
                        }
                    }
                } label: {
                    if let kind = info.kind {
                        IconText(text: kind.title, symbol: kind.symbol).foregroundStyle(Color.brandNavy)
                    } else {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                .disabled(locked)
                .accessibilityLabel("Document Kind")
            }
        case .sender, .dated, .amount, .payBy:
            let info = note.documentInfo ?? DocumentInfo()
            let value: String? = switch row.kind {
            case .sender: info.correspondent
            case .dated: info.dayText
            case .amount: info.amountText
            default: info.dueDate?.formatted(date: .abbreviated, time: .omitted)
            }
            Button { editingDocument = true } label: {
                DetailsRow(label: label, width: labelWidth) {
                    Text(value ?? String(localized: "None"))
                        .foregroundStyle(value == nil ? Color.secondary : row.kind == .payBy && info.isOverdue() ? Color.brandDangerText : Color.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if !locked {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .accessibilityHint("Edit Document Details")
        case .paid:
            let info = note.documentInfo ?? DocumentInfo()
            DetailsRow(label: label, width: labelWidth) {
                Text(info.paid ? String(localized: "Paid") : String(localized: "Not yet"))
                    .foregroundStyle(info.paid ? Color.brandTaskText : Color.secondary)
                Spacer(minLength: 8)
                Toggle("Paid", isOn: Binding(
                    get: { info.paid },
                    set: { value in withAnimation(.snappy) { Undoable.apply(.paid(value), to: [note], in: context) } }
                ))
                .labelsHidden()
                .tint(.brandTask)
                .disabled(locked)
            }
            if !info.isEmpty, !locked {
                Button(role: .destructive) {
                    withAnimation(.snappy) { Undoable.clearDocument(note, in: context) }
                } label: {
                    Text("Clear Document Details")
                }
            }
        case .speakers:
            WrapLayout(spacing: 8, lineSpacing: 8) {
                ForEach(note.speakers) { speaker in
                    if locked {
                        SpeakerChip(speaker: speaker)
                    } else {
                        Menu {
                            SpeakerMenuItems(speaker: speaker, note: note, askName: askName, showVoices: { showVoices = true })
                        } label: {
                            SpeakerChip(speaker: speaker)
                        }
                        .accessibilityLabel("Rename \(speaker.name)")
                    }
                }
            }
            .padding(.vertical, 4)
        case .linkedFrom:
            DetailsRow(label: label, width: labelWidth) {
                if linkedFrom.isEmpty, mentions.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    NavigationLink(value: Page.linkedFrom) {
                        Text(linkedText)
                    }
                }
            }
        case .similar:
            DetailsRow(label: label, width: labelWidth) {
                if similar.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    NavigationLink(value: Page.similar) {
                        Text(similar.count == 1 ? String(localized: "1 entry") : String(localized: "\(similar.count) entries"))
                    }
                }
            }
        case .sharing:
            DetailsRow(label: label, width: labelWidth) {
                Text(EntryDetails.sharingText(for: note))
            }
        case .activity:
            DetailsRow(label: label, width: labelWidth) {
                Text(state.activityLine ?? "").foregroundStyle(Color.brandProjectText)
            }
        case .origin:
            DetailsRow(label: label, width: labelWidth) {
                Text(EntryDetails.origin(for: note).value)
            }
        }
    }

    /// "2 · 1 Mention".
    private var linkedText: String {
        var parts: [String] = []
        if !linkedFrom.isEmpty { parts.append("\(linkedFrom.count)") }
        if !mentions.isEmpty { parts.append(mentions.count == 1 ? String(localized: "1 Mention") : String(localized: "\(mentions.count) Mentions")) }
        return parts.joined(separator: " · ")
    }

    private func currentBowl(_ state: EntryContext) -> NoteFolder? {
        note.projectIDs.lazy.compactMap { state.bowl($0) }.first
    }

    private func bowlLabel(_ state: EntryContext) -> some View {
        let bowl = currentBowl(state)
        return IconText(text: bowl?.name ?? String(localized: "Inbox"), symbol: bowl == nil ? "tray" : "folder.fill")
            .foregroundStyle(bowl == nil ? Color.primary : Color.brandProjectText)
            .lineLimit(1)
    }

    /// The Inbox, the active bowls (not those shared to view only) with the entry's ticked, and a new one.
    @ViewBuilder
    private var bowlChoices: some View {
        Button {
            withAnimation(.snappy) { Undoable.move([note], toBowl: nil, named: nil, in: context) }
        } label: {
            Label("Inbox", systemImage: note.isInInbox ? "checkmark" : "tray")
        }
        Divider()
        ForEach(bowls.filter { (!$0.isArchived && !BowlSharing.shared.isReadOnly($0.id)) || note.projectIDs.contains(Projects.key($0)) }) { bowl in
            let key = Projects.key(bowl)
            Button {
                guard note.projectIDs != [key] else { return }
                withAnimation(.snappy) { Undoable.move([note], toBowl: key, named: bowl.name, in: context) }
            } label: {
                if note.projectIDs.contains(key) { Label(bowl.name, systemImage: "checkmark") } else { Text(bowl.name) }
            }
        }
        Divider()
        Button {
            bowlName = ""
            creatingBowl = true
        } label: {
            Label("New Bowl…", systemImage: "folder.badge.plus")
        }
    }

    private func tagsView(locked: Bool) -> some View {
        WrapLayout(spacing: 6, lineSpacing: 6) {
            ForEach(note.tags, id: \.self) { tag in
                let removable = !locked && note.labels.contains { $0.lowercased() == tag.lowercased() }
                HStack(spacing: 5) {
                    Text("#\(tag)").lineLimit(1)
                    if removable {
                        Button { withAnimation(.snappy) { Undoable.removeTag(tag, from: note, in: context) } } label: {
                            Image(systemName: "xmark").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove Tag \(tag)")
                    }
                }
                .foregroundStyle(Color.brandNavy)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.14), in: Capsule())
            }
            if !locked {
                Button {
                    newTag = ""
                    addingTag = true
                } label: {
                    IconText(text: String(localized: "Tag"), symbol: "plus")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Tag")
            } else if note.tags.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func connectionPage(_ page: Page) -> some View {
        ScrollView {
            VStack(alignment: .leading) {
                switch page {
                case .linkedFrom: EntryLinksSection(note: note)
                case .similar: RelatedEntryRows(notes: similar)
                case .sameAppointment: RelatedEntryRows(notes: AppointmentLinks.shared.others(linkedWith: note, among: allNotes))
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle(page == .linkedFrom ? "Linked From" : page == .similar ? "Similar" : AppointmentLinks.shared.appointment(for: note.id)?.title ?? "Same Appointment")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Doing

    private func addTag() {
        let tag = Note.cleanTag(newTag)
        guard !tag.isEmpty, !note.tags.contains(where: { $0.lowercased() == tag.lowercased() }) else { return }
        note.labels.append(tag)
        note.updatedAt = Date()
        try? context.save()
    }

    private func askName(_ speaker: Speaker) {
        renameText = speaker.name
        renaming = speaker
    }

    private func open(_ id: UUID) {
        dismiss()
        let openEntry = openEntry
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            openEntry(id)
        }
    }
}

/// A row of Details: the label in its column, then the value or its control.
private struct DetailsRow<Content: View>: View {
    let label: String
    let width: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: width, alignment: .leading)
            HStack(spacing: 6) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 30)
    }
}

/// A small symbol and a word, close together (a `Label` in a Form row gets the wide icon column).
private struct IconText: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).lineLimit(1)
        }
    }
}

/// A speaker in Details: its colour, its name ("Me" for the user), "Name…" while it has none.
struct SpeakerChip: View {
    let speaker: Speaker

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.speaker(speaker.colorIndex)).frame(width: 9, height: 9)
            Text(speaker.name).fontWeight(.semibold).lineLimit(1)
            if AppSettings.isMe(speaker) { MeBadge() }
            if VoiceProfiles.isUnnamed(speaker) {
                Text("Name…").foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(Color.brandNavy)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.speaker(speaker.colorIndex).opacity(0.16), in: Capsule())
    }
}

/// Naming a speaker, in Details and on a name in the transcript: the people invited to the appointment, the user,
/// another name; on a line of the transcript also giving only that line to another speaker; the known voices.
struct SpeakerMenuItems: View {
    let speaker: Speaker
    let note: Note
    /// The line the menu was opened on, for "Only This Line".
    var segment: TranscriptSegment?
    let askName: (Speaker) -> Void
    let showVoices: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing

    var body: some View {
        let choices = SpeakerNaming.choices(for: speaker.id, in: note)
        Section("\(speaker.name) is…") {
            ForEach(choices, id: \.self) { name in
                Button {
                    SpeakerNaming.rename(speaker.id, to: name, in: note, context: context, processing: processing)
                } label: {
                    Text(name)
                    Text("Invited")
                }
            }
            if let me = AppSettings.myName, !AppSettings.isMe(speaker), !choices.contains(me) {
                Button {
                    SpeakerNaming.rename(speaker.id, to: me, in: note, context: context, processing: processing)
                } label: {
                    Text("\(me) (Me)")
                }
            }
            Button { askName(speaker) } label: { Label("Other Name…", systemImage: "pencil") }
        }
        if let segment {
            let others = note.speakers.filter { $0.id != segment.speakerId }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { other in
                        Button(other.name) { reassign(segment, to: other) }
                    }
                } label: {
                    Label("Only This Line", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
        }
        Button(action: showVoices) { Label("Known Voices…", systemImage: "person.wave.2") }
    }

    private func reassign(_ segment: TranscriptSegment, to speaker: Speaker) {
        note.segments = note.segments.map { item in
            var item = item
            if item.id == segment.id { item.speakerId = speaker.id }
            return item
        }
        try? context.save()
    }
}

/// The known voices in a sheet of their own (from Details › Speakers and the transcript).
struct KnownVoicesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Known Voices").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.fontWeight(.semibold)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            NavigationStack { VoicesView() }
        }
        .background(Color.appBackground)
        .presentationDetents([.medium, .large])
    }
}
