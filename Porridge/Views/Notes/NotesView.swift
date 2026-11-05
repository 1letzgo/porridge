import SwiftData
import SwiftUI

struct NotesView: View {
    var openSettings: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(ProcessingService.self) private var processing
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    /// The tasks and decisions of all notes, taken from their summaries.
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]

    @State private var selection: UUID?
    /// The note's page on the stack (phone). Follows `selection`, so that one place opens it without animation.
    @State private var notePath: [UUID] = []
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
    /// "More" was tapped: the list shows all elements, not only the first `HomeList.maxElements`.
    @State private var showAllElements = false
    /// What the long list is narrowed to, chosen with the button beside the search.
    @State private var homeFilter = HomeFilter.all
    /// The filter button is unfolded into its options.
    /// The search lies over whatever is shown, opened from its button.
    @State private var showSearch = false
    /// While the keyboard is up, the search card reaches down to it (the buttons below step aside).
    @State private var keyboardShown = false
    @State private var confirmEmptyTrash = false
    @State private var showRecorder = false
    @State private var showCalendar = false
    /// Where the back pill of the settings page returns to (iOS; the Mac uses `openSettings`).
    @State private var pageBeforeSettings = ListPage.home
    /// Dialog for a link typed or pasted by hand.
    @State private var showAddLink = false
    /// The plus button is unfolded into its options.
    @State private var showCreate = false
    @State private var showAudioImporter = false
    @State private var audioImportError: String?
    @State private var showPlaud = false
    @State private var plaudSignedIn = PlaudAccount.isSignedIn
    @State private var linkText = ""
    /// The task open in the detail column, like a note; a new one is made empty and opened right away.
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
            list
        } detail: {
            if let note = selectedNote {
                NoteDetailView(note: note, onClose: { close(note) }, startsRecording: note.id == draft?.id)
                    .id(note.id)
            } else {
                EmptyStateView(title: "No Note Selected", message: "Pick a note from the list.", systemImage: "note.text")
            }
        }
    }

    /// On a phone a note replaces the list at once, like a project does, instead of sliding in. It still is a
    /// real page of the stack: the system covers the list, keeps its scroll position and handles accessibility.
    @ViewBuilder
    private var columns: some View {
        #if os(iOS)
        if sizeClass == .compact {
            NavigationStack(path: $notePath) {
                list
                    .navigationDestination(for: UUID.self) { _ in
                        if let note = selectedNote {
                            NoteDetailView(note: note, onClose: { close(note) }, startsRecording: note.id == draft?.id, onBack: { selection = nil })
                                .id(note.id)
                        }
                    }
            }
            .onAppear { notePath = selection.map { [$0] } ?? [] }
            .onChange(of: selection) { withoutAnimation { notePath = selection.map { [$0] } ?? [] } }
            .onChange(of: notePath) { if notePath.isEmpty { selection = nil } }
        } else {
            splitView
        }
        #else
        splitView
        #endif
    }

    var body: some View {
        columns
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
                onPick: { appointment in startRecording(titled: appointment.title) },
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
        .alert("New Project", isPresented: $showNewProject) {
            TextField("Name", text: $projectName)
            Button("Cancel", role: .cancel) { projectName = "" }
            Button("Create") {
                if let project = Projects.create(projectName, in: context) { page = .project(project.id) }
                projectName = ""
            }
        }
        .alert("Rename Project", isPresented: .constant(renamingProject != nil)) {
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
            "Delete “\(deletingProject?.name ?? "")”?", isPresented: .constant(deletingProject != nil), titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                if let deletingProject {
                    if page == .project(deletingProject.id) { page = .home }
                    Projects.delete(deletingProject, in: context)
                }
                deletingProject = nil
            }
            Button("Cancel", role: .cancel) { deletingProject = nil }
        } message: {
            Text("Its meetings, notes and links stay.")
        }
        .task {
            LegacyMigration.run(in: context)
            LegacyMigration.removeDuplicates(in: context)
            await RecordingJournal.recover(context: context, processing: processing)
            removeEmptyNotes()
            NoteStore.purgeExpired(in: context)
            LinkImport.importInbox(context: context, processing: processing)
            Projects.migrateFolders(in: context)
        }
        // The search index follows the notes: only what changed is cut again.
        .task(id: indexSignature) {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await NoteIndex.shared.refresh(notes)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { LinkImport.importInbox(context: context, processing: processing) }
        }
        #if os(iOS)
        // From a widget, a control or a shortcut; on a cold launch the action waits until the list appears.
        .onReceive(NotificationCenter.default.publisher(for: .porridgeQuickAction)) { _ in runQuickAction() }
        .onAppear { runQuickAction() }
        #endif
        #if os(macOS)
        #if os(macOS)
        .focusedSceneValue(\.libraryActions, LibraryActions(
            canCreate: page != .archive && page != .trash,
            plaudSignedIn: plaudSignedIn,
            recordMeeting: { showCalendar = true },
            addLink: { showAddLink = true },
            newProject: page == .home ? { showNewProject = true } : nil,
            importAudio: { showAudioImporter = true },
            importPlaud: { showPlaud = true },
            search: { showSearch.toggle() }
        ))
        .focusedSceneValue(\.homeFilter, page == .home ? $homeFilter : nil)
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .newNote)) { _ in
            addNote()
        }
        #endif
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

    private var list: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            ChromeBar(title: listTitle, systemImage: listIcon, tint: listTint, onBack: barBack) {
                listActions
            }
            .padding(.bottom, Look.headerGap)
            #else
            // The list's name at the top of the sidebar, as in Things; the actions sit in the window's toolbar.
            ListTitle(title: listTitle, systemImage: listIcon, tint: listTint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, Look.headerGap)
            #endif

            pageContent
                .swipeBack(barBack)
        }
        .background(Color.appBackground)
        #if os(iOS)
        // Over the whole list column, bar included, so the dimming while it is open covers all of it.
        .overlay { createMenu }
        #endif
        .navigationTitle(listTitle)
        #if os(iOS)
        // Own bar (ChromeBar) instead of the system one: title on the left as in Things, plain icons on the right.
        .toolbar(.hidden, for: .navigationBar)
        #else
        .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 480)
        .toolbar {
            listToolbar
        }
        #endif
        .onChange(of: showSearch) { _, open in
            if !open {
                search = ""
                tagTokens = []
                searchKind = nil
            }
        }
        .onChange(of: selection) {
            // Leaving an empty new note leaves nothing behind.
            if let draft, draft.id != selection, draft.modelContext == nil { self.draft = nil }
        }
        .onChange(of: notes.map(\.id)) {
            if let draft, draft.modelContext != nil { self.draft = nil }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .home:
            home
        case .project:
            if let project = openProject {
                ProjectPage(
                    project: project, notes: notes, selection: $selection, onRemove: { remove($0) }
                )
                .id(project.id)
            } else {
                // Deleted on another device.
                home
            }
        case .archive:
            archive
        case .trash:
            trash
        case .settings, .voices, .acknowledgements:
            // Settings stays underneath its subpages so it keeps its scroll position.
            ZStack {
                SettingsView(isEmbedded: true)
                    .opacity(page == .settings ? 1 : 0)
                    .allowsHitTesting(page == .settings)
                    .accessibilityHidden(page != .settings)
                if page == .voices {
                    VoicesView()
                } else if page == .acknowledgements {
                    AcknowledgementsView()
                }
            }
            .environment(\.openListPage, { page = $0 })
        }
    }

    /// The search as a card: what is found opens, and the card folds away.
    private var searchPanel: some View {
        OverlayPanel(title: "Search", systemImage: "magnifyingglass", tint: .brandNavy, onClose: closeSearch) {
            SearchPane(
                text: $search, tokens: $tagTokens, kind: $searchKind,
                tags: TagToken.counts(notes.filter { !$0.isDeleted }),
                hasQuery: hasQuery
            ) {
                searchResults
            }
            .padding(.top, 12)
        }
    }

    private func closeSearch() {
        withAnimation(.snappy) { showSearch = false }
    }

    /// The one long list: the projects as folders on top, then what is in no project, open tasks first; at the
    /// end the way to the archive and the trash.
    private var home: some View {
        let keys = Set(projects.map(Projects.key))
        let filter = homeFilter
        let folders = filter.showsProjects ? HomeList.activeProjects(projects) : []
        let recent = HomeList.shownProjects(folders, showAll: showAllProjects || filter == .projects) { project in
            max(project.updatedAt, ProjectContent(of: project, notes: notes).lastChange ?? .distantPast)
        }
        let loose = HomeList.notes(notes, projects: keys).filter(filter.matches)
        let pinned = loose.filter(\.isPinned)
        let unpinned = loose.filter { !$0.isPinned }
        let limits = HomeList.elementLimits(pinned: pinned.count, notes: unpinned.count, showAll: showAllElements)
        let grouped = groups(Array(unpinned.prefix(limits.notes)))
        let archived = HomeList.archivedProjects(projects).count + HomeList.archivedNotes(notes).count
        let deleted = notes.filter(\.isDeleted).count
        let isEmpty = folders.isEmpty && loose.isEmpty
        return List(selection: $selection) {
            if !folders.isEmpty {
                projectsSection(recent.shown, isFirst: true, hidden: filter == .projects ? 0 : recent.hidden)
            }
            if !pinned.isEmpty {
                Section {
                    let shown = pinned.prefix(limits.pinned)
                    ForEach(shown) { note in row(note, isLast: note.id == shown.last?.id) }
                } header: {
                    ListHeader(title: "Pinned", tint: .brandNavy, isFirst: folders.isEmpty)
                }
            }
            dateSections(grouped, isFirst: folders.isEmpty && pinned.isEmpty)
            if limits.hidden > 0 {
                Section {
                    moreRow(hidden: limits.hidden, isExpanded: showAllElements, tint: .brandSky) { showAllElements.toggle() }
                }
            }
            if filter == .all, archived > 0 {
                Section {} header: {
                    ListHeaderButton(title: "Archive", count: archived, tint: .brandNavy, isFirst: isEmpty) { page = .archive }
                }
            }
            if filter == .all, deleted > 0 {
                Section {} header: {
                    ListHeaderButton(title: "Recently Deleted", count: deleted, tint: .red, isFirst: isEmpty && archived == 0) { page = .trash }
                }
            }
        }
        .cardList()
        .roomForFloatingButtons()
        .overlay {
            if isEmpty, filter != .all {
                EmptyStateView(
                    title: "Nothing to Show",
                    message: "The list has nothing of this kind.",
                    systemImage: filter.systemImage
                )
            } else if isEmpty, archived == 0, deleted == 0 {
                EmptyStateView(
                    title: "Nothing Here Yet",
                    message: "Add notes, meetings, links and projects with the plus button.",
                    systemImage: "note.text"
                )
            }
        }
    }

    private var archive: some View {
        let folders = HomeList.archivedProjects(projects)
        let archivedNotes = HomeList.archivedNotes(notes)
        return List(selection: $selection) {
            if !folders.isEmpty {
                projectsSection(folders, isFirst: true)
            }
            dateSections(groups(archivedNotes), isFirst: folders.isEmpty)
        }
        .cardList()
        .roomForFloatingButtons()
        .overlay {
            if folders.isEmpty, archivedNotes.isEmpty {
                EmptyStateView(
                    title: "Nothing Archived",
                    message: "Archive a project or note with a swipe or a long press.",
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
        let grouped = groups(found)
        return List {
            ForEach(grouped, id: \.title) { group in
                Section {
                    ForEach(group.notes) { note in
                        Button {
                            closeSearch()
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

    private func projectsSection(_ folders: [NoteFolder], isFirst: Bool, hidden: Int = 0) -> some View {
        Section {
            ForEach(folders) { project in
                ProjectRow(
                    project: project,
                    content: ProjectContent(of: project, notes: notes),
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
            ListHeader(title: "Projects", tint: .brandProject, isFirst: isFirst)
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

    /// Unfolds what the list leaves out, in place.
    private func moreRow(hidden: Int, isExpanded: Bool, tint: Color, toggle: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy, toggle)
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "Less" : "More")
                if !isExpanded {
                    Text("\(hidden)").foregroundStyle(.secondary)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint.readable)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardListRow()
        .listRowSeparator(.hidden, edges: .bottom)
    }

    /// Changes when a note's content changed (the index compares hashes, this only wakes it up).
    private var indexSignature: String {
        notes.reduce(into: "") { result, note in
            result += "\(note.id)\(note.updatedAt.timeIntervalSince1970)\(note.summary?.count ?? 0)\(note.segmentsData?.count ?? 0)\(note.pageText?.count ?? 0)\(note.isDeleted)|"
        }
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
    /// the imports, link, meeting and note (and project on the long list). Bottom left the filter and the search.
    private var createMenu: some View {
        ZStack(alignment: .bottom) {
            if showCreate || showSearch {
                // Tapping anywhere else folds the menu or the card again.
                Color.black.opacity(showSearch ? 0.18 : 0.08)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(.snappy) { showCreate = false; showSearch = false } }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 14) {
                #if os(iOS)
                if showSearch {
                    overlayCard { searchPanel }
                }
                #endif
                if !(showSearch && keyboardShown), !page.isSettings {
                    HStack(alignment: .bottom, spacing: 12) {
                        if !showSearch, page == .home {
                            Menu {
                                homeFilterPicker
                            } label: {
                                Image(systemName: homeFilter.systemImage)
                                    .font(.title2.weight(.semibold))
                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                                    .foregroundStyle(homeFilter == .all ? Color.brandNavy : homeFilter.tint.onFill)
                                    .frame(width: 58, height: 58)
                                    .floatingCircle(fill: homeFilter == .all ? .appBackground : homeFilter.tint)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(filterLabel)
                            .accessibilityIdentifier("HomeFilterButton")
                        }
                        FloatingActionButton(
                            systemImage: showSearch ? "xmark" : "magnifyingglass",
                            label: showSearch ? "Close Search" : "Search", fill: .appBackground, foreground: .brandNavy
                        ) {
                            withAnimation(.snappy) {
                                showCreate = false
                                showSearch.toggle()
                            }
                        }
                        Spacer()
                        if !showSearch, page != .archive, page != .trash {
                            VStack(alignment: .trailing, spacing: 14) {
                                if showCreate {
                                    createOption("Import Audio", systemImage: "square.and.arrow.down", tint: .brandNavy) { showAudioImporter = true }
                                    if plaudSignedIn {
                                        createOption("Import Plaud", systemImage: "waveform", tint: .brandNavy) { showPlaud = true }
                                    }
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.2))
                                        .frame(width: 150, height: 1)
                                    if page == .home {
                                        createOption("Project", systemImage: "folder.badge.plus", tint: .brandProject) { showNewProject = true }
                                    }
                                    createOption("Link", systemImage: "link", tint: .brandLink) { showAddLink = true }
                                    createOption("Meeting", systemImage: "mic.fill", tint: .brandNavy) { showCalendar = true }
                                    createOption("Note", systemImage: "square.and.pencil", tint: .brandSky) { addNote() }
                                }
                                FloatingActionButton(systemImage: "plus", label: showCreate ? "Close" : "Create") {
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
            .padding(.bottom, showSearch && keyboardShown ? 8 : 16)
            // While something is unfolded, VoiceOver stays in it and the escape gesture folds it.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(showCreate || showSearch ? .isModal : [])
            .accessibilityAction(.escape) {
                withAnimation(.snappy) { showCreate = false; showSearch = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.snappy) { keyboardShown = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.snappy) { keyboardShown = false }
        }
        #endif
    }

    /// The kinds the long list can be narrowed to, the chosen one checked.
    private var homeFilterPicker: some View {
        Picker("Filter", selection: $homeFilter.animation(.snappy)) {
            ForEach(HomeFilter.allCases, id: \.self) { option in
                Label(option.title, systemImage: option.systemImage).tag(option)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    private var filterLabel: String {
        switch homeFilter {
        case .all: "Filter"
        case .projects: "Filter: Projects"
        case .meetings: "Filter: Meetings"
        case .notes: "Filter: Notes"
        case .links: "Filter: Links"
        }
    }

    /// A card unfolding from the buttons at the bottom left.
    private func overlayCard<Card: View>(@ViewBuilder _ card: () -> Card) -> some View {
        card()
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
            .padding(.top, 8)
            .transition(Motion.slide(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottomLeading))))
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
            .background(Color.appBackground, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .transition(Motion.slide(.move(edge: .bottom).combined(with: .opacity)))
    }

    /// The actions of the list, shown as plain icons at the right of the custom bar (iOS).
    @ViewBuilder
    private var listActions: some View {
        if page == .trash, notes.contains(where: \.isDeleted) {
            Button(role: .destructive) { confirmEmptyTrash = true } label: {
                Label("Delete All", systemImage: "trash")
            }
        }
        if !page.isSettings {
            Button {
                pageBeforeSettings = page
                page = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
        if let barBack {
            ToolbarItem(placement: .navigation) {
                Button(action: barBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityLabel("Back")
            }
        }
        createToolbar
        ToolbarItem(placement: .primaryAction) {
            Button { showSearch.toggle() } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .accessibilityLabel("Search")
            .help("Search")
            .popover(isPresented: $showSearch, arrowEdge: .bottom) {
                searchPanel
                    .frame(width: 480, height: 620)
            }
        }
        if page == .home {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    homeFilterPicker
                } label: {
                    Label("Filter", systemImage: homeFilter.systemImage)
                }
                .foregroundStyle(homeFilter == .all ? Color.primary : homeFilter.tint)
                .accessibilityLabel(filterLabel)
                .help(filterLabel)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { openSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityLabel("Settings")
            .help("Settings")
        }
    }

    /// The Mac's plus: the same options as the button on iOS, or emptying the trash.
    @ToolbarContentBuilder
    private var createToolbar: some ToolbarContent {
        if page == .trash {
            if notes.contains(where: \.isDeleted) {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) { confirmEmptyTrash = true } label: {
                        Label("Delete All", systemImage: "trash")
                    }
                }
            }
        } else if page != .archive {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showAudioImporter = true } label: { Label("Import Audio", systemImage: "square.and.arrow.down") }
                    if plaudSignedIn {
                        Button { showPlaud = true } label: { Label("Import Plaud", systemImage: "waveform") }
                    }
                    Divider()
                    Button { addNote() } label: { Label("New Note", systemImage: "square.and.pencil") }
                    Button { showCalendar = true } label: { Label("Record Meeting", systemImage: "mic.fill") }
                    Button { showAddLink = true } label: { Label("Add Link", systemImage: "link") }
                    if page == .home {
                        Button { showNewProject = true } label: { Label("New Project", systemImage: "folder.badge.plus") }
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .accessibilityLabel("New")
                .help("New")
            }
        }
    }

    // MARK: - Content of the list

    /// The project shown, if any (it may have been deleted on another device).
    private var openProject: NoteFolder? {
        guard case .project(let id) = page else { return nil }
        return projects.first { $0.id == id }
    }

    private var listTitle: String {
        switch page {
        case .home: "Porridge"
        case .project: openProject?.name ?? "Porridge"
        case .archive: "Archive"
        case .trash: "Recently Deleted"
        case .settings: "Settings"
        case .voices: "Known Voices"
        case .acknowledgements: "Acknowledgements"
        }
    }

    /// Color of the square in front of the title.
    private var listTint: Color {
        switch page {
        case .project: openProject == nil ? .brandSky : .brandProject
        case .archive: .brandNavy
        case .trash: .red
        default: .brandSky
        }
    }

    /// The back pill of the bar: from a page to the long list, from an archived project to the archive.
    private var barBack: (() -> Void)? {
        switch page {
        case .home: nil
        case .project: { page = openProject?.isArchived == true ? .archive : .home }
        case .archive, .trash: { page = .home }
        case .settings: { page = pageBeforeSettings }
        case .voices, .acknowledgements: { page = .settings }
        }
    }

    /// Symbol in the colored square in front of the title (the list icon of Things).
    private var listIcon: String {
        switch page {
        case .home: "tray.full.fill"
        case .project: openProject == nil ? "tray.full.fill" : "folder.fill"
        case .archive: "archivebox.fill"
        case .trash: "trash.fill"
        case .settings: "gearshape.fill"
        case .voices: "person.2.fill"
        case .acknowledgements: "heart.text.square.fill"
        }
    }

    /// What the search finds among the notes, archived ones included.
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

    /// The project new things go into: the one that is open.
    private var projectForNew: String? {
        openProject.map(Projects.key)
    }

    private func addNote() {
        let note = Note()
        // In a project the new note goes into it.
        if let project = projectForNew {
            note.projectIDs = [project]
        }
        draft = note
        selection = note.id
        column = .detail
    }

    #if os(iOS)
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
    #endif

    /// Opens the recorder once the sheet with the appointments is gone.
    private func startRecording(titled title: String?) {
        appointmentTitle = title
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withoutAnimation { showRecorder = true }
        }
    }

    /// A recorded meeting becomes a note that is transcribed with speakers.
    private func addRecording(from result: RecordingResult, speakerNames: [String], liveText: String, written: [RecordingNote]) {
        let note = Note()
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
        if let project = projectForNew {
            note.projectIDs = [project]
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

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Plain notes are sky blue, recorded meetings navy, saved links orange.
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                ThingsRowIcon(systemImage: icon, tint: tint)
                    .accessibilityLabel(note.isLink ? "Link" : note.isRecording ? "Meeting" : "Note")
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.brandNavy)
                        .accessibilityLabel("Pinned")
                }
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
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
        }
    }

    private var icon: String {
        note.isLink ? "link" : (note.isRecording ? "waveform" : "text.alignleft")
    }

    private var tint: Color {
        note.isLink ? .brandLink : (note.isRecording ? .brandNavy : .brandSky)
    }

    @ViewBuilder
    private func footer(compact: Bool) -> some View {
        if let deletedAt = note.deletedAt {
            Text(daysLeft(deletedAt))
                .foregroundStyle(Color.brandDangerText)
        } else {
            if note.isArchived {
                Image(systemName: "archivebox")
                    .accessibilityLabel("Archived")
            }
            // "30. Oct 10:52": day and time without the "at" in between, to fit a narrow sidebar.
            Text(note.updatedAt.formatted(.dateTime.day().month(.abbreviated)) + " " + note.updatedAt.formatted(.dateTime.hour().minute()))
                .fixedSize()
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
        return left <= 1 ? String(localized: "Deleted tomorrow") : String(localized: "\(left) days left")
    }
}

/// Title in the navigation bar in the style of Things: a colored square with the list's symbol, then the name in bold.
private struct ListTitle: View {
    let title: String
    let systemImage: String
    var tint: Color = .brandSky
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(tint.onFill)
                .frame(width: min(size, 32), height: min(size, 32))
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

#if os(macOS)
/// What the menu bar can do with the list.
struct LibraryActions {
    let canCreate: Bool
    let plaudSignedIn: Bool
    let recordMeeting: () -> Void
    let addLink: () -> Void
    let newProject: (() -> Void)?
    let importAudio: () -> Void
    let importPlaud: () -> Void
    let search: () -> Void
}

/// What the menu bar can do with the open note.
struct NoteActions {
    let isDeleted: Bool
    let isPinned: Bool
    let hasSummary: Bool
    let canSummarize: Bool
    let canEditSummary: Bool
    let canTranscribe: Bool
    let hasTranscript: Bool
    let togglePin: () -> Void
    let summarize: () -> Void
    let editSummary: () -> Void
    let transcribeAgain: () -> Void
    let copyTranscript: () -> Void
    let delete: () -> Void
    let recover: () -> Void
}

extension FocusedValues {
    @Entry var libraryActions: LibraryActions?
    @Entry var noteActions: NoteActions?
    @Entry var homeFilter: Binding<HomeFilter>?
}

extension Notification.Name {
    /// File → New Note (⌘N) in the menu bar.
    static let newNote = Notification.Name("PorridgeNewNote")
}
#endif

/// What the list column shows.
enum ListPage: Hashable {
    /// The one long list.
    case home
    /// One project with everything in it.
    case project(UUID)
    case archive
    case trash
    case settings
    case voices
    case acknowledgements

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
}
