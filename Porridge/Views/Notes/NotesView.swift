import SwiftData
import SwiftUI
import UserNotifications

struct NotesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(ProcessingService.self) private var processing
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    /// The tasks and decisions of all notes, taken from their summaries.
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]

    @State private var selection: UUID?
    /// The pages on the stack: those of the list column, and on a phone the open note on top.
    @State private var path: [ListRoute] = []
    /// A new note that is not saved yet; it is stored when it gets its first content.
    @State private var draft: Note?
    /// Which column is shown on a narrow screen. Set from code so a new note opens reliably.
    @State private var column = NavigationSplitViewColumn.sidebar
    @State private var search = ""
    /// Tags picked in the search field; a note must have all of them.
    @State private var tagTokens: [TagToken] = []
    /// Kind of element the search is narrowed to.
    @State private var searchKind: SearchKind?
    /// What the list column shows: the one long list, or a page reached from it.
    @State private var page = ListPage.home
    /// "More" was tapped: the list shows all projects, not only the latest.
    @State private var showAllProjects = false
    /// The chat page: which chat shows, kept while the app runs.
    @State private var chatNavigation = ChatNavigation()
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var chatThreads: [ChatThread]
    @State private var confirmEmptyTrash = false
    @State private var showRecorder = false
    @State private var showCalendar = false
    /// Dialog for a link typed or pasted by hand.
    @State private var showAddLink = false
    /// The plus button is unfolded into its options.
    @State private var showCreate = false
    @State private var showAudioImporter = false
    @State private var showFileImporter = false
    @State private var audioImportError: String?
    @State private var showPlaud = false
    @State private var plaudSignedIn = PlaudAccount.isSignedIn
    @State private var linkText = ""
    /// Title of the calendar appointment the next recording is made for.
    @State private var appointmentTitle: String?
    @State private var showNewProject = false
    @State private var projectName = ""
    @State private var renamingProject: NoteFolder?
    @State private var deletingProject: NoteFolder?
    /// A note in Recently Deleted that is about to go for good.
    @State private var deletingNow: Note?

    /// The note that is open, a new one not saved yet included.
    private var selectedNote: Note? {
        guard let selection else { return nil }
        return notes.first { $0.id == selection } ?? (draft?.id == selection ? draft : nil)
    }

    private var splitView: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            pageStack
        } detail: {
            if let note = selectedNote {
                NoteDetailView(note: note, onClose: { close(note) }, startsRecording: note.id == draft?.id)
                    .id(note.id)
                    .environment(\.openNote, { openNote($0) })
                    .environment(\.allNotes, notes)
            } else {
                EmptyStateView(title: "No Note Selected", message: "Pick a note from the list.", systemImage: "note.text")
            }
        }
    }

    /// Every page is a real page of the system's stack: it slides in, the swipe from the edge follows the finger,
    /// and what lies below keeps its scroll position. The floating buttons stay in place above the pages.
    private var pageStack: some View {
        NavigationStack(path: $path) {
            listColumn(.home)
                .navigationDestination(for: ListRoute.self) { route in
                    switch route {
                    case .page(let shown):
                        listColumn(shown)
                    case .note(let id):
                        // By its id: the note stays on the page while the page slides away.
                        if let note = notes.first(where: { $0.id == id }) ?? (draft?.id == id ? draft : nil) {
                            NoteDetailView(note: note, onClose: { close(note) }, startsRecording: note.id == draft?.id, onBack: { selection = nil })
                                .id(note.id)
                                .environment(\.openNote, { openNote($0) })
                                .environment(\.allNotes, notes)
                        }
                    }
                }
        }
        .overlay {
            if sizeClass != .compact || selection == nil {
                createMenu
            }
        }
    }

    /// The open note is on the stack only on a phone; elsewhere it has the detail column.
    private func syncNoteRoute() {
        var routes = path.filter(\.isPage)
        if sizeClass == .compact, let selection { routes.append(.note(selection)) }
        if routes != path { path = routes }
    }

    /// `page` changed in code: go back to it if it is on the stack, otherwise it opens on top.
    private func syncPageRoutes() {
        let pages = path.compactMap(\.page)
        guard page != (pages.last ?? .home) else { return }
        if page == .home {
            path.removeAll()
        } else if let index = path.firstIndex(of: .page(page)) {
            path = Array(path[...index])
        } else {
            path = pages.map(ListRoute.page) + [.page(page)]
        }
    }

    @ViewBuilder
    private var columns: some View {
        Group {
            if sizeClass == .compact {
                pageStack
            } else {
                splitView
            }
        }
        .onAppear(perform: syncNoteRoute)
        .onChange(of: selection) { syncNoteRoute() }
        .onChange(of: sizeClass) { syncNoteRoute() }
        .onChange(of: page) { syncPageRoutes() }
        .onChange(of: path) {
            page = path.compactMap(\.page).last ?? .home
            // Swiped back from the note.
            if sizeClass == .compact, selection != nil, path.last?.isPage != false { selection = nil }
        }
    }

    var body: some View {
        columns
        // The search page was left: what was asked is forgotten. (A found note opened from it keeps the page.)
        .onChange(of: page) { old, new in
            if old == .search, new != .search {
                search = ""
                tagTokens = []
                searchKind = nil
            }
        }
        .onChange(of: selection) {
            // Leaving an empty new note leaves nothing behind, once its page has slid away.
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                if let draft, draft.id != selection, draft.modelContext == nil { self.draft = nil }
            }
        }
        .onChange(of: notes.map(\.id)) {
            if let draft, draft.modelContext != nil { self.draft = nil }
        }
        .fullScreenCoverOrSheet(isPresented: $showRecorder) {
            RecordingView(title: appointmentTitle) { result, names, liveText, written in
                addRecording(from: result, speakerNames: names, liveText: liveText, written: written)
            }
        }
        .sheet(isPresented: $showPlaud) {
            PlaudImportSheet { audio in
                PlaudImporter.addNote(audio, projectID: projectForNew, context: context, processing: processing)
            }
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio, .movie]) { result in
            importAudio(result)
        }
        .modifier(FileIntake(isPicking: $showFileImporter) { addFiles($0) })
        .alert("Import Failed", isPresented: Binding(get: { audioImportError != nil }, set: { if !$0 { audioImportError = nil } })) {
            Button("OK") { audioImportError = nil }
        } message: {
            Text(audioImportError ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .plaudAccountChanged)) { _ in
            plaudSignedIn = PlaudAccount.isSignedIn
        }
        .sheet(isPresented: $showCalendar) {
            RecordMeetingSheet(
                onPick: { appointment in startRecording(for: appointment) },
                onNew: { startRecording(titled: nil) }
            )
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
        .alert("New Bowl", isPresented: $showNewProject) {
            TextField("Name", text: $projectName)
            Button("Cancel", role: .cancel) { projectName = "" }
            Button("Create") {
                if let project = Projects.create(projectName, in: context) { page = .project(project.id) }
                projectName = ""
            }
        }
        .alert("Rename Bowl", isPresented: .constant(renamingProject != nil)) {
            TextField("Name", text: $projectName)
            Button("Cancel", role: .cancel) {
                renamingProject = nil
                projectName = ""
            }
            Button("Rename") {
                if let renamingProject { Projects.rename(renamingProject, to: projectName, in: context) }
                renamingProject = nil
                projectName = ""
            }
        }
        .confirmationDialog(
            "Delete “\(deletingProject?.name ?? "")”?", isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }),
            titleVisibility: .visible, presenting: deletingProject
        ) { project in
            // The bowl comes with the dialog: closing it may clear `deletingProject` before this runs.
            Button("Delete Bowl", role: .destructive) {
                if page == .project(project.id) { page = .home }
                Projects.delete(project, in: context)
                deletingProject = nil
            }
            Button("Cancel", role: .cancel) { deletingProject = nil }
        } message: { _ in
            Text("Its meetings, notes and links stay.")
        }
        .task {
            LegacyMigration.run(in: context)
            LegacyMigration.removeDuplicates(in: context)
            await RecordingJournal.recover(context: context, processing: processing)
            removeEmptyNotes()
            NoteStore.purgeExpired(in: context)
            ShareImport.importInbox(context: context, processing: processing)
            Projects.migrateFolders(in: context)
            // Only bowls are archived now: notes archived by earlier versions come back.
            Archive.clearArchivedNotes(in: context)
            // Reminders are gone: what was planned for them is taken back once.
            let center = UNUserNotificationCenter.current()
            let planned = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("remind-") }
            if !planned.isEmpty { center.removePendingNotificationRequests(withIdentifiers: planned) }
        }
        // The share sheet offers the bowls: it reads this list, it cannot open the store.
        .task(id: shareProjects) { ShareInbox.writeProjects(shareProjects) }
        // The search index follows the notes: only what changed is cut again.
        .task(id: indexSignature) {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await NoteIndex.shared.refresh(notes)
            // New entries and those from other devices: what came in gets its summary (`AutoSummary`).
            processing.summarizeIncoming()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ShareImport.importInbox(context: context, processing: processing)
                processing.summarizeIncoming()
            }
        }
        // From a widget, a control or a shortcut; on a cold launch the action waits until the list appears.
        .onReceive(NotificationCenter.default.publisher(for: .porridgeQuickAction)) { _ in runQuickAction() }
        .onAppear { runQuickAction() }
        .confirmationDialog("Delete All in Recently Deleted?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                if let selection, notes.first(where: { $0.id == selection })?.isDeleted == true { self.selection = nil }
                notes.filter(\.isDeleted).forEach { NoteStore.deletePermanently($0, in: context) }
            }
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            "Delete Note Now?",
            isPresented: Binding(get: { deletingNow != nil }, set: { if !$0 { deletingNow = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Now", role: .destructive) {
                if let note = deletingNow {
                    if selection == note.id { selection = nil }
                    NoteStore.deletePermanently(note, in: context)
                }
                deletingNow = nil
            }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - List

    private func listColumn(_ shown: ListPage) -> some View {
        VStack(spacing: 0) {
            ChromeBar(title: listTitle(shown), systemImage: listIcon(shown), tint: listTint(shown), onBack: barBack(shown)) {
                listActions(shown)
            }
            .padding(.bottom, Look.headerGap)

            pageContent(shown)
        }
        .background(Color.appBackground)
        .navigationTitle(listTitle(shown))
        // Own bar (ChromeBar) instead of the system one: title on the left as in Things, plain icons on the right.
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func pageContent(_ shown: ListPage) -> some View {
        switch shown {
        case .home:
            home
        case .project:
            if let project = project(on: shown) {
                ProjectPage(
                    project: project, notes: notes, selection: $selection, onRemove: { remove($0) }
                )
                .id(project.id)
            } else {
                // Deleted on another device.
                home
            }
        case .inbox:
            inboxPage
        case .todos:
            todosPage
        case .search:
            searchPage
        case .chat:
            ChatPage(notes: notes, projects: projects, navigation: chatNavigation) { openNote($0) }
        case .archive:
            archive
        case .trash:
            trash
        case .settings:
            SettingsView(isEmbedded: true)
                .environment(\.openListPage, { page = $0 })
        case .voices:
            VoicesView()
        case .acknowledgements:
            AcknowledgementsView()
        }
    }

    /// The search as a page of its own: what is found opens from it, and going back returns to the results.
    private var searchPage: some View {
        SearchPane(
            text: $search, tokens: $tagTokens, kind: $searchKind,
            tags: TagToken.counts(notes.filter { !$0.isDeleted }),
            hasQuery: hasQuery
        ) {
            searchResults
        }
    }

    /// Opens the chat page. From a bowl the chat is about that bowl; the last chat about it is taken up again.
    private func openChat() {
        chatNavigation.open(from: projectForNew, threads: chatThreads)
        page = .chat
    }

    /// The one long list: the projects as folders on top, then what is in no project, open tasks first; at the
    /// end the way to the archive and the trash.
    private var home: some View {
        let folders = HomeList.activeProjects(projects)
        let contents = ProjectContent.byProject(notes)
        let recent = HomeList.shownProjects(folders, showAll: showAllProjects) { project in
            max(project.updatedAt, contents[Projects.key(project)]?.lastChange ?? .distantPast)
        }
        let waiting = Inbox.notes(notes)
        let archived = HomeList.archivedProjects(projects).count
        let isEmpty = folders.isEmpty && waiting.isEmpty
        return List(selection: $selection) {
            // "Up Next" is the first category: the Inbox (what is new or in no bowl) and below it the to-dos folder,
            // while there are to-dos to show: a view of every open one, wherever it is filed.
            let todoFolder = Todos.folder(notes)
            Section {
                InboxRow(waiting: waiting) { page = .inbox }
                    .lastInSection(todoFolder.isEmpty)
                if !todoFolder.isEmpty {
                    TodoFolderRow(folder: todoFolder) { page = .todos }
                        .lastInSection(true)
                }
            } header: {
                ListHeader(title: "Up Next", tint: .brandSky, isFirst: true)
            }
            // The bowls as a list: the pinned and the latest few, the rest behind "More".
            if !folders.isEmpty {
                projectsSection(recent.shown, contents: contents, isFirst: false, hidden: recent.hidden)
            }
            if archived > 0 {
                Section {} header: {
                    ListHeaderButton(title: "Archive", count: archived, tint: .brandNavy, isFirst: false) { page = .archive }
                }
            }
        }
        .cardList()
        .roomForFloatingButtons()
        .overlay {
            if isEmpty, archived == 0 {
                EmptyStateView(
                    title: "Nothing Here Yet",
                    message: "Add notes, meetings, links and bowls with the plus button.",
                    systemImage: "note.text"
                )
            }
        }
    }

    /// The to-dos folder opened: every open to-do by due day, grouped as the search's "Open To-dos", then those
    /// done today. Each row names its bowls. Only a view: the to-dos stay where they are.
    private var todosPage: some View {
        let folder = Todos.folder(notes)
        let names = Dictionary(projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { a, _ in a })
        func buckets(_ note: Note) -> [String] { note.projectIDs.compactMap { names[$0] } }
        return List(selection: $selection) {
            ForEach(Array(folder.groups.enumerated()), id: \.element.title) { index, group in
                Section {
                    ForEach(group.notes) { note in
                        NoteListRow(note: note, buckets: buckets(note)) { remove(note) }
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
                        NoteListRow(note: note, buckets: buckets(note)) { remove(note) }
                            .lastInSection(note.id == folder.doneToday.last?.id)
                    }
                } header: {
                    ListHeader(title: String(localized: "Done Today"), count: folder.doneToday.count, tint: .brandNavy, isFirst: folder.groups.isEmpty)
                }
            }
        }
        .cardList()
        .roomForFloatingButtons()
        .overlay {
            if folder.isEmpty {
                EmptyStateView(title: "Nothing to Do", message: "Open to-dos from the inbox and every bowl show up here.", systemImage: "checklist")
            }
        }
    }

    /// The inbox opened: what is in no bowl, newest first, each with its suggested bowls.
    private var inboxPage: some View {
        let waiting = Inbox.notes(notes)
        let buckets = projects.filter { !$0.isArchived }
        return List(selection: $selection) {
            Section {
                ForEach(waiting) { note in
                    let isLast = note.id == waiting.last?.id
                    if FilingBar.suggested(for: note, among: buckets).isEmpty {
                        NoteListRow(note: note) { remove(note) }
                            .lastInSection(isLast)
                    } else {
                        NoteListRow(note: note) { remove(note) }
                        FilingBar(note: note, projects: buckets)
                            .lastInSection(isLast)
                    }
                }
            }
        }
        .cardList()
        .roomForFloatingButtons()
        .overlay {
            if waiting.isEmpty {
                EmptyStateView(title: "Inbox Empty", message: "What is new or in no bowl waits here.", systemImage: "tray")
            }
        }
    }

    /// The archive: archived bowls only. Notes are never archived.
    private var archive: some View {
        let folders = HomeList.archivedProjects(projects)
        return List(selection: $selection) {
            if !folders.isEmpty {
                projectsSection(folders, contents: ProjectContent.byProject(notes), isFirst: true)
            }
        }
        .cardList()
        .roomForFloatingButtons()
        .overlay {
            if folders.isEmpty {
                EmptyStateView(
                    title: "Nothing Archived",
                    message: "Archive a bowl with a swipe or a long press.",
                    systemImage: "archivebox"
                )
            }
        }
    }

    private var trash: some View {
        let deleted = notes.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        return List(selection: $selection) {
            if !deleted.isEmpty {
                Section {
                    ForEach(deleted) { note in row(note, isLast: note.id == deleted.last?.id) }
                } header: {
                    Text("Notes are deleted after \(NoteStore.trashDays) days.")
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        }
        .cardList()
        .roomForFloatingButtons()
        .overlay {
            if deleted.isEmpty {
                EmptyStateView(title: "Nothing Deleted", message: "Deleted notes stay here for \(NoteStore.trashDays) days.", systemImage: "trash")
            }
        }
    }

    private var searchResults: some View {
        let found = foundNotes
        // The open to-dos by when they are due; everything else by when it changed.
        let grouped = searchKind == .todos
            ? Todos.dueGroups(found).map { (title: $0.title, label: String($0.title.prefix(1)), notes: $0.notes) }
            : groups(found)
        return List {
            ForEach(grouped, id: \.title) { group in
                Section {
                    ForEach(group.notes) { note in
                        Button {
                            openNote(note.id)
                        } label: {
                            NoteRow(note: note, stage: processing.stages[note.id])
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .cardListRow()
                        .lastInSection(note.id == group.notes.last?.id)
                    }
                } header: {
                    ListHeader(title: group.title, tint: .brandSky, isFirst: group.title == grouped.first?.title)
                }
            }
        }
        .cardList()
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if found.isEmpty {
                ContentUnavailableView.search(text: search.isEmpty ? tagTokens.map { "#" + $0.name }.joined(separator: " ") : search)
            }
        }
    }

    private func projectsSection(_ folders: [NoteFolder], contents: [String: ProjectContent], isFirst: Bool, hidden: Int = 0) -> some View {
        Section {
            ForEach(folders) { project in
                ProjectRow(
                    project: project,
                    content: contents[Projects.key(project)] ?? ProjectContent(),
                    onOpen: { page = .project(project.id) },
                    onRename: {
                        projectName = project.name
                        renamingProject = project
                    },
                    onDelete: { deletingProject = project }
                )
                // With "More" below it the row is not the last one.
                .lastInSection(hidden == 0 && project.id == folders.last?.id)
            }
            if hidden > 0 {
                moreRow(hidden: hidden, isExpanded: showAllProjects, tint: .brandProject) { showAllProjects.toggle() }
            }
        } header: {
            ListHeader(title: "Bowls", tint: .brandProject, isFirst: isFirst)
        }
    }

    private func dateSections(_ grouped: [(title: String, label: String, notes: [Note])], isFirst: Bool) -> some View {
        ForEach(grouped, id: \.title) { group in
            Section {
                ForEach(group.notes) { note in row(note, isLast: note.id == group.notes.last?.id) }
            } header: {
                ListHeader(title: group.title, tint: .brandSky, isFirst: isFirst && group.title == grouped.first?.title)
            }
        }
    }

    private func row(_ note: Note, isLast: Bool) -> some View {
        NoteListRow(note: note) { remove(note) }
            .lastInSection(isLast)
    }

    private func moreRow(hidden: Int, isExpanded: Bool, tint: Color, toggle: @escaping () -> Void) -> some View {
        MoreRow(hidden: hidden, isExpanded: isExpanded, tint: tint, toggle: toggle)
    }

    /// Changes when a note's content changed (the index compares hashes, this only wakes it up).
    /// A number, not a text: this is asked at every redraw of the list, and a string of every note's id and date
    /// was built and thrown away each time.
    private var indexSignature: Int {
        var hasher = Hasher()
        for note in notes {
            hasher.combine(note.id)
            hasher.combine(note.updatedAt)
            hasher.combine(note.summary?.utf8.count ?? 0)
            hasher.combine(note.segmentsData?.count ?? 0)
            hasher.combine(note.pageText?.utf8.count ?? 0)
            hasher.combine(note.isDeleted)
        }
        return hasher.finalize()
    }

    private var hasQuery: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty || !tagTokens.isEmpty || searchKind != nil
    }

    /// Opens a note; the list stays where it is.
    private func openNote(_ id: UUID) {
        Task {
            selection = id
            column = .detail
        }
    }

    /// The ways to start something: one plus button bottom right, the same in every view, that unfolds into
    /// link, meeting and note (and bowl on the long list). Bottom left the chat and the search.
    private var createMenu: some View {
        ZStack(alignment: .bottom) {
            if showCreate {
                // Tapping anywhere else folds the menu again.
                Color.black.opacity(0.08)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy) { showCreate = false } }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 14) {
                if !page.hidesFloatingButtons {
                    HStack(alignment: .bottom, spacing: 12) {
                        // The chat with the notes and the search, bottom left: each opens its own page.
                        FloatingActionButton(
                            systemImage: "bubble.left.and.bubble.right.fill", label: "Chat", fill: .appBackground, foreground: .brandNavy
                        ) {
                            withAnimation(.snappy) { showCreate = false }
                            openChat()
                        }
                        FloatingActionButton(systemImage: "magnifyingglass", label: "Search", fill: .appBackground, foreground: .brandNavy) {
                            withAnimation(.snappy) { showCreate = false }
                            page = .search
                        }
                        Spacer()
                        if page != .archive, page != .trash {
                            VStack(alignment: .trailing, spacing: 14) {
                                if showCreate {
                                    if page == .home {
                                        createOption("Bowl", systemImage: "folder.badge.plus", tint: .brandProject) { showNewProject = true }
                                    }
                                    createOption("Link", systemImage: "link", tint: .brandLink) { showAddLink = true }
                                    createOption("Meeting", systemImage: "mic.fill", tint: .brandNavy) { showCalendar = true }
                                    createOption("To-do", systemImage: "checklist", tint: .brandTask) { addNote(todo: true) }
                                    createOption("Note", systemImage: "square.and.pencil", tint: .brandSky) { addNote() }
                                }
                                FloatingActionButton(systemImage: "plus", label: showCreate ? "Close" : "Create") {
                                    // In the to-dos folder the plus makes a to-do, without the menu.
                                    if page == .todos, !showCreate { addNote(todo: true); return }
                                    withAnimation(.snappy) {
                                        // Signed in on another device, or the sign-in ran out.
                                        plaudSignedIn = PlaudAccount.isSignedIn
                                        showCreate.toggle()
                                    }
                                }
                                .rotationEffect(.degrees(showCreate ? 45 : 0))
                            }
                            // Only the button takes room in the row; the options reach out over it to the left.
                            .frame(width: 58, alignment: .trailing)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            // While something is unfolded, VoiceOver stays in it and the escape gesture folds it.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(showCreate ? .isModal : [])
            .accessibilityAction(.escape) {
                withAnimation(.snappy) { showCreate = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// One unfolded option: a single white pill, icon on the left in the color of its kind, then the text.
    private func createOption(_ title: LocalizedStringKey, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { showCreate = false }
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint.readable)
                    .frame(minWidth: 22)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .fixedSize()
            // Beyond this the longest option no longer fits the width of the phone.
            .dynamicTypeSize(...DynamicTypeSize.accessibility3)
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .frame(minHeight: 48)
            // In dark mode the page is black: the pill takes the raised surface, or it vanishes into the list.
            .background(colorScheme == .dark ? Color.appSecondaryBackground : Color.appBackground, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(Motion.slide(.move(edge: .bottom).combined(with: .opacity)))
    }

    /// Opens Recently Deleted; shown next to Settings while it holds notes.
    private var trashButton: some View {
        Button { page = .trash } label: {
            Label("Recently Deleted", systemImage: "trash")
        }
        .foregroundStyle(.red)
        .accessibilityLabel("Recently Deleted")
        .help("Recently Deleted")
    }

    /// The actions of the list, shown as plain icons at the right of the custom bar (iOS).
    @ViewBuilder
    private func listActions(_ shown: ListPage) -> some View {
        if shown == .trash, notes.contains(where: \.isDeleted) {
            Button(role: .destructive) { confirmEmptyTrash = true } label: {
                Label("Delete All", systemImage: "trash")
            }
        }
        if shown == .chat {
            ChatBarActions(navigation: chatNavigation)
        }
        if shown == .home, notes.contains(where: \.isDeleted) {
            trashButton
        }
        // What is brought in from outside has its own menu in the bar; on a bowl's page it goes into the bowl.
        if shown == .home || project(on: shown) != nil {
            importMenu
                .menuStyle(.button)
        }
        if shown == .home {
            Button {
                page = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    /// Import: audio, a photo or a file, recordings from Plaud.
    private var importMenu: some View {
        Menu {
            Button { showAudioImporter = true } label: { Label("Import Audio", systemImage: "waveform") }
            if plaudSignedIn {
                Button { showPlaud = true } label: { Label("Import Plaud", systemImage: "recordingtape") }
            }
            Button { showFileImporter = true } label: { Label("Photo or File", systemImage: "paperclip") }
        } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .accessibilityLabel("Import")
        .help("Import")
    }

    // MARK: - Content of the list

    /// The project shown, if any (it may have been deleted on another device).
    private var openProject: NoteFolder? {
        project(on: page)
    }

    private func project(on shown: ListPage) -> NoteFolder? {
        guard case .project(let id) = shown else { return nil }
        return projects.first { $0.id == id }
    }

    private func listTitle(_ shown: ListPage) -> String {
        switch shown {
        case .home: "Porridge"
        case .project: project(on: shown)?.name ?? "Porridge"
        case .inbox: "Inbox"
        case .todos: "To-dos"
        case .chat: "Chat"
        case .search: "Search"
        case .archive: "Archive"
        case .trash: "Recently Deleted"
        case .settings: "Settings"
        case .voices: "Known Voices"
        case .acknowledgements: "Acknowledgements"
        }
    }

    /// Color of the square in front of the title.
    private func listTint(_ shown: ListPage) -> Color {
        switch shown {
        case .project: project(on: shown) == nil ? .brandSky : .brandProject
        case .archive, .chat, .search: .brandNavy
        case .trash: .red
        case .todos: .brandTask
        default: .brandSky
        }
    }

    /// The back pill of the bar: from a page to the long list, from an archived project to the archive.
    private func barBack(_ shown: ListPage) -> (() -> Void)? {
        guard shown != .home else { return nil }
        return { if !path.isEmpty { path.removeLast() } }
    }

    /// Symbol in the colored square in front of the title (the list icon of Things).
    private func listIcon(_ shown: ListPage) -> String {
        switch shown {
        case .home: "tray.full.fill"
        case .project: project(on: shown) == nil ? "tray.full.fill" : "folder.fill"
        case .inbox: "tray.fill"
        case .todos: "checklist"
        case .chat: "bubble.left.and.bubble.right.fill"
        case .search: "magnifyingglass"
        case .archive: "archivebox.fill"
        case .trash: "trash.fill"
        case .settings: "gearshape.fill"
        case .voices: "person.2.fill"
        case .acknowledgements: "heart.text.square.fill"
        }
    }

    /// What the search finds among the notes, those in archived bowls included.
    private var foundNotes: [Note] {
        var result = notes.filter { !$0.isDeleted }
        if let searchKind { result = result.filter(searchKind.matches) }
        if !tagTokens.isEmpty {
            result = result.filter { note in
                let tags = Set(note.tags.map { $0.lowercased() })
                return tagTokens.allSatisfy { tags.contains($0.id) }
            }
        }
        if !search.isEmpty {
            // The index knows the words of every passage (transcripts included) without decoding anything.
            if let ids = NoteIndex.shared.noteIDs(matching: search) {
                _ = NoteIndex.shared.version
                result = result.filter { ids.contains($0.id) || $0.title.localizedCaseInsensitiveContains(search) || ($0.url?.localizedCaseInsensitiveContains(search) ?? false) }
            } else {
                result = result.filter { $0.matches(search) }
            }
        }
        // Strictly a timeline: the newest on top.
        return result.sorted { $0.updatedAt > $1.updatedAt }
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
            // A date ahead (another device's clock) counts as today, so no heading comes twice.
            if calendar.isDateInToday(date) || days < 0 {
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
        // In a project the new link goes into it.
        if let project = projectForNew {
            note.projectIDs = [project]
            try? context.save()
        }
        selection = note.id
        column = .detail
    }

    /// An imported recording opens, as a new one does; in a project it goes into it.
    private func importAudio(_ result: Result<URL, Error>) {
        do {
            let note = try NoteStore.importAudio(from: result.get(), context: context, processing: processing)
            if let project = projectForNew {
                note.projectIDs = [project]
                try? context.save()
            }
            selection = note.id
            column = .detail
        } catch {
            audioImportError = error.localizedDescription
        }
    }

    private var shareProjects: [ShareInbox.Project] {
        projects.filter { !$0.isArchived }.map { ShareInbox.Project(id: Projects.key($0), name: $0.name) }
    }

    /// Files picked or dropped: each becomes a file (audio a recording), the first is opened at once.
    private func addFiles(_ urls: [URL]) {
        guard let note = ShareImport.add(files: urls, project: projectForNew, context: context, processing: processing) else { return }
        selection = note.id
        column = .detail
    }

    /// The project new things go into: the one that is open.
    private var projectForNew: String? {
        openProject.map(Projects.key)
    }

    /// A new note, or a to-do: the same note with a done state, made the same way.
    private func addNote(todo: Bool = false) {
        let note = Note()
        note.source = .note
        if todo { note.todoState = .open }
        // In a project the new note goes into it.
        if let project = projectForNew {
            note.projectIDs = [project]
        }
        draft = note
        selection = note.id
        column = .detail
    }

    private func runQuickAction() {
        switch QuickActionCenter.take() {
        case .newNote:
            addNote()
        case .startMeeting:
            guard !showRecorder else { return }
            showCalendar = false
            startRecording(titled: nil)
        case nil:
            break
        }
    }

    /// Records a meeting for a calendar appointment: the note gets its title.
    private func startRecording(for event: CalendarAppointment) {
        startRecording(titled: event.title)
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
    private func addRecording(from result: RecordingResult, speakerNames: [String], liveText: String, written: [RecordingNote]) {
        let note = Note()
        note.source = .meeting
        note.title = appointmentTitle ?? Note.defaultMeetingTitle(for: note.createdAt)
        note.titleIsCustom = appointmentTitle != nil
        appointmentTitle = nil
        note.statusRaw = ProcessingStatus.recorded.rawValue
        note.audioFileName = result.fileName
        note.duration = result.duration
        note.channelCount = result.channelCount
        note.inputName = result.inputName
        note.text = RecordingNote.markdown(written)
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

    /// A recorded meeting: stored, opened and transcribed.
    private func insertAndProcess(_ note: Note) {
        if let project = projectForNew, !note.projectIDs.contains(project) {
            note.projectIDs.append(project)
        }
        context.insert(note)
        try? context.save()
        draft = nil
        selection = note.id
        column = .detail
        processing.enqueue(.transcript(note.id))
    }

    /// Moves a note to the trash, or deletes it for good when it already is there.
    private func remove(_ note: Note) {
        if note.isDeleted {
            deletingNow = note
        } else {
            if selection == note.id { selection = nil }
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
        let empty = notes.filter { $0.isEmptyLeftover && processing.stages[$0.id] == nil }
        guard !empty.isEmpty else { return }
        empty.forEach { context.delete($0) }
        try? context.save()
    }
}

struct NoteRow: View {
    let note: Note
    let stage: String?
    /// Bowl names to show in the footer (a list of several bowls' notes); empty shows none.
    var buckets: [String] = []

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.modelContext) private var context

    var body: some View {
        // Plain notes are sky blue, recorded meetings navy, saved links orange, to-dos green.
        HStack(alignment: .top, spacing: 12) {
            ThingsRowIcon(systemImage: note.kindSymbol, tint: tint, isPinned: note.isPinned)
                .accessibilityLabel(note.kindName)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.body)
                    .foregroundStyle(note.isDone ? .secondary : .primary)
                    .strikethrough(note.isDone, color: .secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                // The full line when there is room (narrow sidebar on the Mac); otherwise without domain and speakers.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { footer(compact: false) }
                    HStack(spacing: 8) { footer(compact: true) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
            }
            // The first picture or PDF of the note, small.
            if let attachment = note.attachmentsData == nil ? nil : note.attachments.first(where: { $0.kind != .file }) {
                Spacer(minLength: 0)
                RowThumbnail(attachment: attachment)
            }
            // A to-do is ticked right in the list, with its box at the end of the row; a deleted one only shows it.
            if note.isTodo {
                Spacer(minLength: 0)
                TodoCheckbox(isDone: note.isDone, size: 26) {
                    withAnimation(.snappy) { Todos.setDone(!note.isDone, note, in: context) }
                }
                .disabled(note.isDeleted)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var tint: Color {
        note.isTodo ? .brandTask : note.isLink ? .brandLink : (note.isRecording || note.isStored ? .brandNavy : .brandSky)
    }

    @ViewBuilder
    private func footer(compact: Bool) -> some View {
        if let deletedAt = note.deletedAt {
            Text(daysLeft(deletedAt))
                .foregroundStyle(Color.brandDangerText)
        } else {
            // "30. Oct 10:52": day and time without the "at" in between, to fit a narrow sidebar. Where a to-do names
            // its bowls (the to-dos folder) its due day says more, and the date makes room for them.
            if buckets.isEmpty || !note.isTodo {
                Text(note.updatedAt.formatted(.dateTime.day().month(.abbreviated)) + " " + note.updatedAt.formatted(.dateTime.hour().minute()))
                    .fixedSize()
            }
        }
        if note.isTodo {
            TodoDueLabel(note: note)
            TodoProgressLabel(progress: note.todoProgress)
        }
        // Where a list mixes bowls the row names its own; on a narrow row the names give way first.
        if !buckets.isEmpty {
            Label(buckets.joined(separator: ", "), systemImage: "folder")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.brandProject.readable)
                .truncationMode(.tail)
                .layoutPriority(compact ? -1 : 0)
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
        // The state keeps its width; the domain gives way first.
        Group {
            if let stage {
                StatusBadge(text: stage, color: .accentColor, spinning: true)
            } else if note.status == .failed {
                StatusBadge(text: "Failed", color: .red)
            } else if [.recorded, .transcribing].contains(note.status) && note.isRecording {
                StatusBadge(text: AudioStore.isLocal(note.audioFileName) ? "Waiting for transcription" : "Processing on another device")
            } else if case let waiting = note.pendingTodoSuggestions(made: []).count, waiting > 0 {
                // A summary with to-dos waiting to be taken on says so instead of "Summarized".
                StatusBadge(text: waiting == 1 ? "1 suggested to-do" : "\(waiting) suggested to-dos", color: .brandTaskText)
            } else if note.summary != nil {
                StatusBadge(text: "Summarized", color: .accentColor)
            }
        }
        .fixedSize()
    }

    private func daysLeft(_ deletedAt: Date) -> String {
        let passed = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
        let left = max(0, NoteStore.trashDays - passed)
        return left <= 1 ? String(localized: "Deleted tomorrow") : String(localized: "\(left) days left")
    }
}

/// A page on the stack.
enum ListRoute: Hashable {
    case page(ListPage)
    case note(UUID)

    var page: ListPage? {
        if case .page(let page) = self { page } else { nil }
    }

    var isPage: Bool { page != nil }
}

/// What the list column shows.
enum ListPage: Hashable {
    /// The one long list.
    case home
    /// One project with everything in it.
    case project(UUID)
    /// The inbox: what is new or in no bowl.
    case inbox
    /// The virtual folder of every open to-do by due day (`Todos.folder`), in the "Up Next" section of the home list.
    case todos
    /// The chat with the notes.
    case chat
    /// The search through everything.
    case search
    case archive
    case trash
    case settings
    case voices
    case acknowledgements

    /// The page has its own bottom (the chat's field, the settings): the round buttons stay away.
    var hidesFloatingButtons: Bool { isSettings || self == .chat || self == .search }

    var isSettings: Bool {
        switch self {
        case .settings, .voices, .acknowledgements: true
        default: false
        }
    }
}

extension EnvironmentValues {
    /// Goes to another page of the list column; for the subpages of Settings.
    @Entry var openListPage: (ListPage) -> Void = { _ in }
    /// Opens a note by its id; for the way from a to-do back to the note it was made from.
    @Entry var openNote: (UUID) -> Void = { _ in }
    /// Every note of the list, for views that look up others (the to-dos made from a summary).
    @Entry var allNotes: [Note] = []
}

/// Files come into the list through a picker ("Photo or File") or by dropping them on it (Mac, iPad).
private struct FileIntake: ViewModifier {
    @Binding var isPicking: Bool
    let add: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            // A second importer on the same view would replace the one for audio: this one sits on a view of its own.
            .background {
                Color.clear.fileImporter(isPresented: $isPicking, allowedContentTypes: [.image, .pdf, .data], allowsMultipleSelection: true) { result in
                    if let urls = try? result.get() { add(urls) }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard !files.isEmpty else { return false }
                add(files)
                return true
            }
    }
}

/// The small picture of an attachment at the end of a list row.
private struct RowThumbnail: View {
    let attachment: Attachment
    @State private var picture: CGImage?

    var body: some View {
        Group {
            if let picture {
                Image(decorative: picture, scale: 1).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: attachment.fileName) { picture = await AttachmentThumbnail.load(attachment, maxPixels: 160) }
    }
}
