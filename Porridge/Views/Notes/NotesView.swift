import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct NotesView: View {
    var openSettings: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(ProcessingService.self) private var processing
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \NoteFolder.name) private var folders: [NoteFolder]
    /// The tasks and decisions of all notes, taken from their summaries.
    @Query private var items: [ActionItem]

    @State private var scope = NoteScope.all
    @State private var selection: UUID?
    /// A new note that is not saved yet; it is stored when it gets its first content.
    @State private var draft: Note?
    /// Which column is shown on a narrow screen. Set from code so a new note opens reliably.
    @State private var column = NavigationSplitViewColumn.sidebar
    @State private var folderPrompts = FolderPromptState()
    @State private var search = ""
    /// Tags picked in the search field; a note must have all of them.
    @State private var tagTokens: [TagToken] = []
    /// The tasks come first: the app opens on them; the notes are where they come from.
    @State private var mode = ListMode.tasks
    @State private var chat = ChatStore()
    @State private var confirmEmptyTrash = false
    @State private var showRecorder = false
    @State private var showCalendar = false
    @State private var showImporter = false
    /// Settings pushed as a full page with a back button (iOS); the Mac uses `openSettings` (a sheet).
    @State private var showSettings = false
    /// Dialog for a link typed or pasted by hand.
    @State private var showAddLink = false
    /// The plus button is unfolded into its options.
    @State private var showCreate = false
    @State private var linkText = ""
    /// The task open in the detail column (Tasks tab), like a note; a new one is made empty and opened right away.
    @State private var openTaskItem: ActionItem?
    @State private var importError: String?
    /// Title of the calendar appointment the next recording is made for.
    @State private var appointmentTitle: String?

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            list
        } detail: {
            if let item = openTaskItem, item.modelContext != nil {
                TaskDetailView(
                    item: item,
                    note: item.noteID.flatMap { id in notes.first { $0.id == id } },
                    onOpenNote: { openFromChat($0) },
                    onClose: { closeTask() }
                )
                .id(item.id)
            } else if let selection, let note = notes.first(where: { $0.id == selection }) ?? (draft?.id == selection ? draft : nil) {
                NoteDetailView(note: note) { close(note) }
                    .id(note.id)
            } else if mode == .tasks {
                EmptyStateView(title: "No Task Selected", message: "Pick a task from the list.", systemImage: "checklist")
            } else {
                EmptyStateView(title: "No Note Selected", message: "Pick a note from the list.", systemImage: "note.text")
            }
        }
        .fullScreenCoverOrSheet(isPresented: $showRecorder) {
            RecordingView { result, names, liveText in
                addRecording(from: result, speakerNames: names, liveText: liveText)
            }
        }
        .sheet(isPresented: $showCalendar) {
            RecordMeetingSheet(
                onPick: { appointment in startRecording(titled: appointment.title) },
                onNew: { startRecording(titled: nil) }
            )
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie]) { result in
            importAudio(result)
        }
        .alert("Add Link", isPresented: $showAddLink) {
            TextField("https://", text: $linkText)
                .urlFieldStyle()
            Button("Cancel", role: .cancel) { linkText = "" }
            Button("Add") { addLink() }
                .disabled(LinkImport.webAddress(from: linkText) == nil)
        } message: {
            Text("The page is saved as a note and summarized.")
        }
        .alert("Import Failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .task {
            LegacyMigration.run(in: context)
            LegacyMigration.removeDuplicates(in: context)
            removeEmptyNotes()
            NoteStore.purgeExpired(in: context)
            LinkImport.importInbox(context: context, processing: processing)
            ActionItems.backfill(notes, in: context)
            ActionItems.dropEmptyManual(in: context)
        }
        // The search index follows the notes: only what changed is cut and embedded again.
        .task(id: indexSignature) {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await NoteIndex.shared.refresh(notes)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { LinkImport.importInbox(context: context, processing: processing) }
        }
        .onChange(of: selection) { _, new in
            if new != nil { openTaskItem = nil }
        }
        .onChange(of: scope) {
            selection = nil
            search = ""
            tagTokens = []
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .newNote)) { _ in
            if mode != .timeline { mode = .timeline }
            addNote()
        }
        #endif
        .folderPrompts(folderPrompts, folders: folders, scope: $scope)
        .confirmationDialog("Delete all notes in Recently Deleted?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                notes.filter(\.isDeleted).forEach { NoteStore.deletePermanently($0, in: context) }
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - List

    private var list: some View {
        let shown = visibleNotes
        return VStack(spacing: 0) {
            #if os(iOS)
            ChromeBar(title: listTitle, systemImage: listIcon, tint: listTint) {
                listActions(isEmpty: shown.isEmpty)
            }
            #else
            // The list's name at the top of the sidebar, as in Things; the actions sit in the window's toolbar.
            ListTitle(title: listTitle, systemImage: listIcon, tint: listTint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 10)
            #endif
            ListTabs(mode: $mode)

            switch mode {
            case .timeline:
                timeline(shown)
            case .chat:
                ChatView(notes: notes, items: items, store: chat) { openFromChat($0) }
            case .tasks:
                tasksPane
            case .search:
                SearchPane(
                    text: $search, tokens: $tagTokens,
                    tags: FolderMenu.tagCounts(notes.filter { !$0.isDeleted }),
                    hasQuery: hasQuery
                ) {
                    listBase(shown)
                }
            }
        }
        .background(Color.appBackground)
        .navigationTitle(listTitle)
        #if os(iOS)
        // Own bar (ChromeBar) instead of the system one: title on the left as in Things, plain icons on the right.
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $showSettings) {
            SettingsView(isPushed: true)
        }
        #else
        .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 480)
        .toolbar {
            listToolbar(isEmpty: shown.isEmpty)
        }
        #endif
        #if os(iOS)
        .onChange(of: column) { _, new in
            // Back from a task on the iPhone: the list is shown again, the task is closed.
            if new == .sidebar, sizeClass == .compact { openTaskItem = nil }
        }
        #endif
        .onChange(of: openTaskItem) { old, _ in
            // Leaving a new task without title or text leaves nothing behind.
            if let old { dropIfEmpty(old) }
        }
        .onChange(of: mode) { _, new in
            if new != .tasks { openTaskItem = nil }
            if new != .chat { chat.release() }
            if new != .search {
                search = ""
                tagTokens = []
            }
        }
    }

    private func timeline(_ shown: [Note]) -> some View {
        #if os(iOS)
        listBase(shown)
            // Room below the last row, so it can scroll out from under the plus button.
            .contentMargins(.bottom, 96, for: .scrollContent)
            .overlay { createMenu }
        #else
        listBase(shown)
        #endif
    }

    /// The tasks list; on iOS with the same floating plus button as the timeline, the Mac has it in the toolbar.
    private var tasksPane: some View {
        #if os(iOS)
        TasksPane(items: items, notes: notes, onOpen: { openFromChat($0) }, selectedID: openTaskItem?.id, onEdit: { openTask($0) })
            .contentMargins(.bottom, 96, for: .scrollContent)
            .overlay(alignment: .bottomTrailing) {
                FloatingActionButton(systemImage: "plus", label: "New Task", fill: .brandTask) { addTask() }
                    .padding(.trailing, 22)
                    .padding(.bottom, 16)
            }
        #else
        TasksPane(items: items, notes: notes, onOpen: { openFromChat($0) }, selectedID: openTaskItem?.id, onEdit: { openTask($0) })
        #endif
    }

    private func addTask() {
        let item = ActionItems.newTask(in: context)
        try? context.save()
        openTask(item)
    }

    /// Shows a task in the detail column (pushed with a back button on the iPhone).
    private func openTask(_ item: ActionItem) {
        selection = nil
        openTaskItem = item
        column = .detail
    }

    private func closeTask() {
        openTaskItem = nil
        column = .sidebar
    }

    /// A task typed by hand that was left without title and text is not kept.
    private func dropIfEmpty(_ item: ActionItem) {
        guard item.modelContext != nil, item.source == "manual",
              item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        ActionItems.delete(item, in: context)
    }

    /// Changes when a note's content changed (the index compares hashes, this only wakes it up).
    private var indexSignature: String {
        notes.reduce(into: "") { result, note in
            result += "\(note.id)\(note.updatedAt.timeIntervalSince1970)\(note.summary?.count ?? 0)\(note.segmentsData?.count ?? 0)\(note.pageText?.count ?? 0)\(note.isDeleted)|"
        }
    }

    private var hasQuery: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || !tagTokens.isEmpty
    }

    /// Opens a source of a chat answer in the timeline; from a task the list stays on the tasks.
    private func openFromChat(_ id: UUID) {
        if mode != .tasks { mode = .timeline }
        if scope != .all { scope = .all }
        Task {
            selection = id
            column = .detail
        }
    }

    private func listBase(_ shown: [Note]) -> some View {
        List(selection: $selection) {
            listContent(shown)
        }
        .cardList()
        .timelineIndexVisible()
        .overlay { emptyOverlay(isEmpty: shown.isEmpty) }
        .onChange(of: selection) {
            // Leaving an empty new note leaves nothing behind.
            if let draft, draft.id != selection, draft.modelContext == nil { self.draft = nil }
        }
        .onChange(of: notes.map(\.id)) {
            if let draft, draft.modelContext != nil { self.draft = nil }
        }
    }

    private func emptyOverlay(isEmpty: Bool) -> some View {
        Group {
            if isEmpty {
                if mode == .search {
                    ContentUnavailableView.search(text: search.isEmpty ? tagTokens.map { "#" + $0.name }.joined(separator: " ") : search)
                } else {
                    EmptyStateView(title: emptyTitle, message: emptyMessage, systemImage: "note.text")
                }
            }
        }
    }

    /// The ways to start a note: one plus button bottom right that unfolds into note, meeting and link.
    @ViewBuilder
    private var createMenu: some View {
        if scope != .trash {
            ZStack(alignment: .bottomTrailing) {
                if showCreate {
                    // Tapping anywhere else folds the menu again.
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture { withAnimation(.snappy) { showCreate = false } }
                        .transition(.opacity)
                }
                VStack(alignment: .trailing, spacing: 14) {
                    if showCreate {
                        createOption("Link", systemImage: "link") { showAddLink = true }
                        createOption("Meeting", systemImage: "mic.fill") { showCalendar = true }
                        createOption("Note", systemImage: "square.and.pencil") { addNote() }
                    }
                    FloatingActionButton(systemImage: "plus", label: showCreate ? "Close" : "Create") {
                        withAnimation(.snappy) { showCreate.toggle() }
                    }
                    .rotationEffect(.degrees(showCreate ? 45 : 0))
                }
                .padding(.trailing, 22)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    /// One unfolded option: a single white pill, icon on the left, then the text.
    private func createOption(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { showCreate = false }
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .frame(height: 48)
            .background(Color.appBackground, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder
    private func listContent(_ shown: [Note]) -> some View {
        if scope == .trash {
            Section {
                ForEach(shown) { note in row(note) }
            } header: {
                Text("Notes are deleted after \(NoteStore.trashDays) days.")
                    .font(.footnote)
                    .textCase(nil)
            }
        } else {
            let pinned = shown.filter(\.isPinned)
            if !pinned.isEmpty {
                Section {
                    ForEach(pinned) { note in row(note) }
                } header: {
                    header("Pinned", isFirst: true)
                }
                .timelineIndex(Text(Image(systemName: "pin.fill")))
            }
            let grouped = groups(shown.filter { !$0.isPinned })
            ForEach(grouped, id: \.title) { group in
                Section {
                    ForEach(group.notes) { note in row(note) }
                } header: {
                    header(group.title, isFirst: pinned.isEmpty && group.title == grouped.first?.title)
                }
                .timelineIndex(Text(verbatim: group.label))
            }
        }
    }

    /// The actions of the list, shown as plain icons at the right of the custom bar (iOS).
    @ViewBuilder
    private func listActions(isEmpty: Bool) -> some View {
        if mode == .timeline {
            FolderMenu(notes: notes, folders: folders, scope: $scope, state: folderPrompts)
            if scope != .trash {
                Button { showImporter = true } label: {
                    Label("Import Audio", systemImage: "square.and.arrow.down")
                }
            }
            if scope == .trash, !isEmpty {
                Button(role: .destructive) { confirmEmptyTrash = true } label: {
                    Label("Delete All", systemImage: "trash")
                }
            }
        } else if mode == .chat, !chat.messages.isEmpty {
            Button { chat.reset() } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
        }
        Button { showSettings = true } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    @ToolbarContentBuilder
    private func listToolbar(isEmpty: Bool) -> some ToolbarContent {
        if mode == .timeline {
            ToolbarItem(placement: .primaryAction) {
                FolderMenu(notes: notes, folders: folders, scope: $scope, state: folderPrompts)
            }
            if scope != .trash {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { addNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                            .keyboardShortcut("n")
                        Button { showCalendar = true } label: { Label("Record Meeting", systemImage: "mic.fill") }
                            .keyboardShortcut("r")
                        Button { showAddLink = true } label: { Label("Add Link", systemImage: "link") }
                            .keyboardShortcut("l")
                        Divider()
                        Button { showImporter = true } label: { Label("Import Audio…", systemImage: "square.and.arrow.down") }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .accessibilityLabel("New")
                }
            }
            if scope == .trash, !isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { confirmEmptyTrash = true } label: {
                        Label("Delete All", systemImage: "trash")
                    }
                }
            }
        } else if mode == .chat, !chat.messages.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button { chat.reset() } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .accessibilityLabel("New Chat")
            }
        } else if mode == .tasks {
            ToolbarItem(placement: .primaryAction) {
                Button { addTask() } label: {
                    Label("New Task", systemImage: "plus")
                }
                .accessibilityLabel("New Task")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    /// Things: bold title over a hairline, no symbol. The first one sits right under the tabs
    /// (the gap comes from the header, `Look.headerGap`); later ones keep air from the section above.
    private func header(_ title: String, isFirst: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentColor)
            Rectangle().fill(Look.hairline).frame(height: 0.5)
        }
        .padding(.top, isFirst ? 0 : 16)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
        .textCase(nil)
    }

    private func row(_ note: Note) -> some View {
        ListRowLink(value: note.id) {
            NoteRow(
                note: note, stage: processing.stages[note.id],
                folderName: showsFolder ? folderName(of: note) : nil
            )
        }
        .swipeActions(edge: .leading) {
            if note.isDeleted {
                Button { NoteStore.restore(note, in: context) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                    .tint(.brandSky)
            } else {
                Button { togglePin(note) } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                    .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { remove(note) } label: {
                Label(note.isDeleted ? "Delete Now" : "Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            if note.isDeleted {
                Button { NoteStore.restore(note, in: context) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                Button(role: .destructive) { remove(note) } label: { Label("Delete Now", systemImage: "trash") }
            } else {
                Button { togglePin(note) } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                MoveToFolderMenu(note: note)
                ShareLink(item: note.title.isEmpty ? note.text : "\(note.title)\n\n\(note.text)") {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) { remove(note) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    // MARK: - Content of the list

    private var listTitle: String {
        mode == .chat ? "Chat" : mode == .search ? "Search" : mode == .tasks ? "Tasks" : scopeTitle
    }

    /// Color of the square in front of the title: tasks are green, everything else sky blue.
    private var listTint: Color { mode == .tasks ? .brandTask : .brandSky }

    /// Symbol in the colored square in front of the title (the list icon of Things).
    private var listIcon: String {
        switch mode {
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .search: return "magnifyingglass"
        case .tasks: return "checklist"
        case .timeline:
            switch scope {
            case .all: return "tray.full.fill"
            case .unfiled: return "note.text"
            case .folder: return "folder.fill"
            case .tag: return "number"
            case .trash: return "trash.fill"
            }
        }
    }

    private var scopeTitle: String {
        switch scope {
        case .all: "Notes"
        case .unfiled: "Notes"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Notes"
        case .tag(let tag): "#" + tag
        case .trash: "Recently Deleted"
        }
    }

    private var emptyTitle: String {
        scope == .trash ? "Nothing Deleted" : "No Notes Yet"
    }

    private var emptyMessage: String {
        scope == .trash ? "Deleted notes stay here for \(NoteStore.trashDays) days." : "Speak a thought – Porridge writes it down for you."
    }

    private var showsFolder: Bool {
        switch scope {
        case .all, .tag, .trash: true
        default: false
        }
    }

    private func folderName(of note: Note) -> String? {
        note.folderID.flatMap { id in folders.first { $0.id == id }?.name }
    }

    private var visibleNotes: [Note] {
        let folderIDs = Set(folders.map(\.id))
        var result: [Note]
        // The search looks through everything; the timeline shows the chosen folder.
        switch mode == .search ? .all : scope {
        case .all: result = notes.filter { !$0.isDeleted }
        case .unfiled: result = notes.filter { !$0.isDeleted && ($0.folderID.map { !folderIDs.contains($0) } ?? true) }
        case .folder(let id): result = notes.filter { !$0.isDeleted && $0.folderID == id }
        case .tag(let tag): result = notes.filter { !$0.isDeleted && $0.tags.contains { $0.lowercased() == tag } }
        case .trash: result = notes.filter(\.isDeleted)
        }
        if mode == .search, !tagTokens.isEmpty {
            result = result.filter { note in
                let tags = Set(note.tags.map { $0.lowercased() })
                return tagTokens.allSatisfy { tags.contains($0.id) }
            }
        }
        if mode == .search, !search.isEmpty {
            // The index knows the words of every passage (transcripts included) without decoding anything.
            if let ids = NoteIndex.shared.noteIDs(matching: search) {
                _ = NoteIndex.shared.version
                result = result.filter { ids.contains($0.id) || $0.title.localizedCaseInsensitiveContains(search) || ($0.url?.localizedCaseInsensitiveContains(search) ?? false) }
            } else {
                result = result.filter { $0.matches(search) }
            }
        }
        // Strictly a timeline: the newest on top.
        if scope == .trash {
            result.sort { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        } else {
            result.sort { $0.updatedAt > $1.updatedAt }
        }
        return result
    }

    /// Notes under headings like Today, Yesterday, Previous 7 Days, months and years. `label` is the short form
    /// shown in the index along the right edge.
    private func groups(_ list: [Note]) -> [(title: String, label: String, notes: [Note])] {
        let calendar = Calendar.current
        let now = Date()
        var result: [(title: String, label: String, notes: [Note])] = []
        for note in list {
            let date = note.updatedAt
            let title: String
            let label: String
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
            if calendar.isDateInToday(date) {
                title = String(localized: "Today"); label = "T"
            } else if calendar.isDateInYesterday(date) {
                title = String(localized: "Yesterday"); label = "Y"
            } else if days <= 7 {
                title = String(localized: "Previous 7 Days"); label = "7"
            } else if days <= 30 {
                title = String(localized: "Previous 30 Days"); label = "30"
            } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
                title = date.formatted(.dateTime.month(.wide)); label = String(date.formatted(.dateTime.month(.wide)).prefix(1)).uppercased()
            } else {
                title = date.formatted(.dateTime.year()); label = String(title.suffix(2))
            }
            if result.last?.title == title {
                result[result.count - 1].notes.append(note)
            } else {
                result.append((title, label, [note]))
            }
        }
        return result
    }

    // MARK: - Actions

    /// Saves the link from the dialog and opens it.
    private func addLink() {
        guard let address = LinkImport.webAddress(from: linkText) else { return }
        linkText = ""
        let note = LinkImport.add(address, context: context, processing: processing)
        if case .folder(let id) = scope, note.folderID == nil { note.folderID = id }
        selection = note.id
        column = .detail
    }

    private func addNote() {
        let note = Note()
        if case .folder(let id) = scope { note.folderID = id }
        draft = note
        selection = note.id
        column = .detail
    }

    /// Opens the recorder once the sheet with the appointments is gone.
    private func startRecording(titled title: String?) {
        appointmentTitle = title
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            showRecorder = true
        }
    }

    /// A recorded meeting becomes a note that is transcribed with speakers.
    private func addRecording(from result: RecordingResult, speakerNames: [String], liveText: String) {
        let note = Note()
        if case .folder(let id) = scope { note.folderID = id }
        note.title = appointmentTitle ?? Note.defaultMeetingTitle(for: note.createdAt)
        note.titleIsCustom = appointmentTitle != nil
        appointmentTitle = nil
        note.statusRaw = ProcessingStatus.recorded.rawValue
        note.audioFileName = result.fileName
        note.duration = result.duration
        note.channelCount = result.channelCount
        note.inputName = result.inputName
        if result.isSplitStereo {
            note.speakerMode = .channels
            note.speakers = [
                Speaker(id: SpeakerAssigner.leftChannelID, name: speakerNames[0], colorIndex: 0),
                Speaker(id: SpeakerAssigner.rightChannelID, name: speakerNames[1], colorIndex: 1),
            ]
        }
        if !liveText.isEmpty {
            // Shown until the final transcript with speakers is ready.
            note.segments = [TranscriptSegment(speakerId: nil, start: 0, end: result.duration, text: liveText)]
        }
        insertAndProcess(note)
    }

    private func importAudio(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let fileName = try AudioStore.importFile(from: url)
            let note = Note()
            if case .folder(let id) = scope { note.folderID = id }
            note.title = url.deletingPathExtension().lastPathComponent
            note.titleIsCustom = true
            note.statusRaw = ProcessingStatus.recorded.rawValue
            note.audioFileName = fileName
            note.inputName = "Import"
            if let info = AudioStore.audioInfo(for: fileName) {
                note.duration = info.duration
                note.channelCount = info.channels
            }
            insertAndProcess(note)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func insertAndProcess(_ note: Note) {
        context.insert(note)
        try? context.save()
        draft = nil
        selection = note.id
        column = .detail
        processing.enqueue(.transcript(note.id))
    }

    private func togglePin(_ note: Note) {
        note.isPinned.toggle()
        try? context.save()
    }

    /// Moves a note to the trash, or deletes it for good when it already is there.
    private func remove(_ note: Note) {
        if selection == note.id { selection = nil }
        if note.isDeleted {
            NoteStore.deletePermanently(note, in: context)
        } else {
            NoteStore.trash(note, in: context)
        }
    }

    /// Closes the open note (after it was deleted or recovered).
    private func close(_ note: Note) {
        selection = nil
        column = .sidebar
    }

    /// Notes left empty by earlier versions (no title, text or recording) are not worth keeping.
    private func removeEmptyNotes() {
        let empty = notes.filter {
            $0.title.isEmpty && $0.text.isEmpty && $0.audioFileNames.isEmpty && $0.pendingAudioFileName == nil
                && $0.audioFileName == nil && $0.segmentsData == nil
                && processing.stages[$0.id] == nil
        }
        guard !empty.isEmpty else { return }
        empty.forEach { context.delete($0) }
        try? context.save()
    }
}

private struct NoteRow: View {
    let note: Note
    let stage: String?
    let folderName: String?

    var body: some View {
        // Plain notes are sky blue, recorded meetings navy, saved links orange.
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                ThingsRowIcon(systemImage: icon, tint: tint)
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Pinned")
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // The full line when there is room (narrow sidebar on the Mac); otherwise without folder and speakers.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { footer(compact: false) }
                    HStack(spacing: 8) { footer(compact: true) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
            }
        }
    }

    private var icon: String {
        note.isLink ? "link" : (note.isRecording ? "waveform" : "text.alignleft")
    }

    private var tint: Color {
        note.isLink ? .brandLink : (note.isRecording ? .accentColor : .brandSky)
    }

    @ViewBuilder
    private func footer(compact: Bool) -> some View {
        if let deletedAt = note.deletedAt {
            Text(daysLeft(deletedAt))
                .foregroundStyle(.red.opacity(0.8))
        } else {
            // "30. Oct 10:52": day and time without the "at" in between, to fit a narrow sidebar.
            Text(note.updatedAt.formatted(.dateTime.day().month(.abbreviated)) + " " + note.updatedAt.formatted(.dateTime.hour().minute()))
                .fixedSize()
        }
        if let folderName, !compact {
            Label(folderName, systemImage: "folder")
                .labelStyle(.titleAndIcon)
        }
        if let domain = note.domain, !compact {
            Label(domain, systemImage: "link")
                .labelStyle(.titleAndIcon)
        }
        if note.isRecording, note.duration > 0 {
            Text(note.duration.durationText)
                .fixedSize()
            if note.speakers.count > 1, !compact {
                Label("\(note.speakers.count)", systemImage: "person.2.fill")
                    .fixedSize()
            }
        }
        Spacer(minLength: 8)
        // The state keeps its width; the folder and the domain give way first.
        Group {
            if let stage {
                StatusBadge(text: stage, color: .accentColor, spinning: true)
            } else if note.status == .failed {
                StatusBadge(text: "Failed", color: .red)
            } else if [.recorded, .transcribing].contains(note.status) && note.isRecording {
                StatusBadge(text: note.hasLocalAudio ? "Waiting for transcription" : "Processing on another device")
            } else if note.summary != nil {
                StatusBadge(text: "Summarized", color: .accentColor)
            }
        }
        .fixedSize()
    }

    private func daysLeft(_ deletedAt: Date) -> String {
        let passed = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
        let left = max(0, NoteStore.trashDays - passed)
        return String(localized: "\(left) days left")
    }
}

/// Title in the navigation bar in the style of Things: a colored square with the list's symbol, then the name in bold.
private struct ListTitle: View {
    let title: String
    let systemImage: String
    var tint: Color = .brandSky

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The views of the list as quiet text tabs below the bar, sharing the full width.
private struct ListTabs: View {
    @Binding var mode: ListMode

    var body: some View {
        TabSwitcher(selection: $mode, options: [
            (ListMode.tasks, "Tasks"),
            (ListMode.timeline, "Notes"),
            (ListMode.chat, "Chat"),
            (ListMode.search, "Search"),
        ])
        .padding(.horizontal, 20)
        // The same gap above and below the tabs, whatever comes next (timeline, chat or search).
        .padding(.vertical, Look.headerGap)
    }
}

#if os(macOS)
extension Notification.Name {
    /// File → New Note (⌘N) in the menu bar.
    static let newNote = Notification.Name("PorridgeNewNote")
}
#endif

enum ListMode: Hashable {
    case tasks
    case timeline
    case chat
    case search
}
