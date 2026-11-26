import SwiftData
import SwiftUI
import UserNotifications

/// The app's root on iPhone and iPad: the places Today · Inbox · To-dos · Bowls · Search · Chat (`Place`). On a phone
/// (and an iPad window of compact width) four tabs with a stack each (an entry opens on top of it): To-dos is the Inbox
/// tab's other side, Chat the Search tab's. On an iPad of regular width a split view: the sidebar lists the six places
/// (`PadSidebar`); right of it the place's own stack with
/// the same pages as on the phone (bowls and smart filters open from the Bowls page there), and, where the width
/// allows and the page lists entries, the open entry in a column beside the list (else it is pushed onto the stack, as
/// on a phone). Holds what every place shares: the Add sheet and what it starts, quick actions, links and the dialogs about
/// bowls and smart filters.
struct NotesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(ProcessingService.self) private var processing
    @Query(sort: \Note.updatedAt, order: .reverse) private var notes: [Note]
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]

    @State private var selection: UUID?
    /// The place in front, the one state both layouts are drawn from: the sidebar's row on an iPad of regular width,
    /// on a phone its tab and side (`Place.tab`: To-dos is the Inbox tab on To-dos, Chat the Search tab on Chat). So
    /// turning an iPad or resizing its window keeps it. Every launch starts on Today (owner revision 5), whatever was
    /// used last; a link, a widget, a shortcut or a notification that opened the app moves on from there. Kept while
    /// the app runs, so coming back from the background keeps the tab.
    @State private var place: Place = .today
    /// The Search tab's side last chosen (Search or Chat, on this device): the tab comes back on it.
    @AppStorage(SearchSide.key) private var searchSide = SearchSide.search
    /// The Inbox tab's side last chosen while the app runs (Inbox or To-dos): the tab comes back on it. Every launch
    /// starts on Inbox.
    @State private var inboxSide = InboxSide.inbox
    /// The pages on each stack: those of the list column, and on a phone the open note on top. A phone has a stack
    /// per tab, an iPad of regular width one per place (`stackKey`).
    @State private var paths: [Place: [ListRoute]] = [:]
    /// A new note that is not saved yet; it is stored when it gets its first content.
    @State private var draft: Note?
    /// A new note whose title takes the focus and that does not start recording: made from the keyboard (⌘N, ⇧⌘N),
    /// or with the Add sheet's Note or To-do while new notes do not record (`addTyped`).
    @State private var typedDraftID: UUID?
    /// iPad: which columns of the split view show (sidebar, list, entry). Set by the window's width
    /// (`fitColumns`): all three where they fit, else the list and the entry with the sidebar shown on demand; the
    /// sidebar button, the edge swipe and ⌃⌘S change it. The list column never goes away (never the entry alone).
    @State private var columnVisibility = NavigationSplitViewVisibility.doubleColumn
    /// iPad: the split view's width, measured (0 until it is).
    @State private var splitWidth: CGFloat = 0
    /// iPad: the whole window (safe areas included) and its safe-area insets, measured: the Add popover may reach
    /// down to the home indicator's safe area. (The split view's own height is the safe area's, 790 pt of the 834 pt
    /// window of an 11-inch iPad in landscape: less 80 pt it cut the popover after "Meeting Notes".)
    @State private var windowArea = WindowArea()
    /// iPad: the list column's width, measured (0 until it is): Today's bar makes room for "+" in a narrow column.
    @State private var listColumnWidth: CGFloat = 0
    /// iPad: the sidebar's width grows with the text size, so the places and their counts are not cut.
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 210
    /// iPad: Settings as a sheet over the window (on a phone a page of the stack).
    @State private var showPadSettings = false
    /// iPad: the Add sheet as a popover at the "+" of the bar.
    @State private var showAddPopover = false
    /// iPad: the system search field of the Search place has the focus (⌘F).
    @FocusState private var searchFieldFocused: Bool
    @State private var search = ""
    /// Tags picked in the search field; a note must have all of them.
    @State private var tagTokens: [TagToken] = []
    /// Kind of element the search is narrowed to.
    @State private var searchKind: SearchKind?
    /// Where the search looks (Everywhere, the Inbox, a bowl); also what "Ask Porridge" asks about.
    @State private var searchScope = SearchAsk.Scope.everywhere
    /// What was searched for lately on this device (`SearchAsk.RecentSearches`).
    @State private var recentSearches = SearchAsk.RecentSearches.all()
    /// The day the Today page shows; nil is today. Only while the app runs: opening Today starts on today.
    @State private var todayDay: Date?
    @AppStorage(HomeList.bowlOrderKey) private var bowlOrder = HomeList.BowlOrder.lastChange
    /// The chat page: which chat shows, kept while the app runs.
    @State private var chatNavigation = ChatNavigation()
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var chatThreads: [ChatThread]
    @State private var confirmEmptyTrash = false
    /// A `porridge://meeting` link (any app or website can open one) asks first before recording starts.
    @State private var confirmLinkMeeting = false
    @State private var showRecorder = false
    @State private var showCalendar = false
    /// Dialog for a link typed or pasted by hand.
    @State private var showAddLink = false
    /// The Add sheet ("+" of every place).
    @State private var showAdd = false
    /// What the Add sheet asked for: done once the sheet is gone (a sheet cannot open while another one closes).
    @State private var pendingAdd: AddChoice?
    /// The bowl the Add sheet's "Into:" chose (`.some(nil)`: the Inbox); nil when no Add sheet chose: the open bowl then.
    @State private var addInto: String??
    /// A template that needs a title first.
    @State private var askingTemplate: NoteTemplate?
    @State private var templateTitle = ""
    @State private var showAudioImporter = false
    @State private var showFileImporter = false
    /// The document camera is open.
    @State private var showScanner = false
    @State private var audioImportError: String?
    @State private var linkText = ""
    /// Title of the calendar appointment the next recording is made for.
    @State private var appointmentTitle: String?
    /// The appointment itself: its people are offered for the speakers later (`MeetingLinks`).
    @State private var appointment: CalendarAppointment?
    @State private var showNewProject = false
    @State private var projectName = ""
    @State private var renamingProject: NoteFolder?
    @State private var deletingProject: NoteFolder?
    /// The Inbox or a bowl is in its selection mode: several entries are changed at once (`NoteSelectionBar`).
    @State private var isSelecting = false
    @State private var chosen = Set<UUID>()
    /// A note in Recently Deleted that is about to go for good.
    @State private var deletingNow: Note?
    /// Triage: the Inbox one entry at a time (`TriageView`): full screen on a phone, a sheet on an iPad.
    @State private var showTriage = false
    @AppStorage(DailyHint.enabledKey) private var hintsEnabled = true
    /// The smart filter being made or changed (`SmartFilterEditor`).
    @State private var smartFilterDraft: SmartFilterDraft?
    @State private var renamingFilter: SmartFilter?
    @State private var deletingFilter: SmartFilter?
    @State private var filterName = ""
    /// A long press on "+" made a note: the tap that ends it opens no Add sheet.
    @State private var plusLongPressed = false
    /// The phone's tab bar (`PlaceTabBar`): the screen's width, its bottom safe area (the home indicator), and
    /// whether a software keyboard is up.
    @State private var screenWidth: CGFloat = 390
    @State private var bottomSafeArea: CGFloat = 34
    @State private var keyboardShown = false

    /// The note that is open, a new one not saved yet included.
    private var selectedNote: Note? {
        guard let selection else { return nil }
        return notes.first { $0.id == selection } ?? (draft?.id == selection ? draft : nil)
    }

    /// The stack a place is on: its tab's on a phone (To-dos and the Inbox share one, Chat and Search), its own on an
    /// iPad of regular width.
    private func stackKey(_ shown: Place) -> Place {
        usesSystemBars ? shown : shown.tab
    }

    /// The stack that is in front: the tab's on a phone, the place chosen in the sidebar on an iPad.
    private var activeStack: Place { stackKey(place) }

    private var currentPath: [ListRoute] { paths[activeStack] ?? [] }

    /// What the list column shows in front: the top page of the stack, else the place itself.
    private var page: ListPage { currentPath.compactMap(\.page).last ?? place.root }

    /// The place a phone's tab shows: the place in front for its own tab, else the side the tab was left on.
    private func shown(in tab: Place) -> Place {
        if place.tab == tab { return place }
        switch tab {
        case .inbox: return inboxSide.place
        case .search: return searchSide.place
        default: return tab
        }
    }

    /// Keeps the side of a phone's tab the place is on, for coming back to the tab.
    private func remember(_ shown: Place) {
        switch shown {
        case .inbox: inboxSide = .inbox
        case .todos: inboxSide = .todos
        case .search: searchSide = .search
        case .chat: searchSide = .chat
        default: break
        }
    }

    private func pathBinding(_ place: Place) -> Binding<[ListRoute]> {
        Binding(get: { paths[place] ?? [] }, set: { paths[place] = $0 })
    }

    /// iPad, regular width: the system's split view with three columns, as Notes, Reminders and Mail. The sidebar lists
    /// the places (`PadSidebar`); the list column holds the place's own stack with its pages (`placeStack`); the entry
    /// column shows the open entry, on the Chat side the conversation (`padDetail`). Every column has the system's
    /// navigation bar: titles, back button, sidebar button and the pages' actions as toolbar items. The columns lie
    /// side by side (`.balanced`): a wide window shows all three, a narrower one (portrait, a smaller window) the list
    /// and the entry, the sidebar coming in on its button and going again once a place is chosen. The system's
    /// automatic choice showed the entry column alone in portrait ("No Entry Selected" without its list).
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PadSidebar(
                notes: notes,
                selection: Binding(get: { place }, set: { chosen in
                    guard let chosen else { return }
                    choosePlace(chosen)
                    // Where the three columns do not fit, the sidebar steps aside for the place it chose.
                    if !fitsThreeColumns { columnVisibility = .doubleColumn }
                }),
                onSettings: { go(.settings) }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: min(sidebarWidth, 320), max: 340)
        } content: {
            placeStack(place)
                // One stack per place, as the phone's tabs: its pages come back from `paths` when the place does.
                .id(place)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
        } detail: {
            padDetail
        }
        .navigationSplitViewStyle(.balanced)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            fitColumns(to: width)
        }
        .background {
            // Safe areas ignored: the window's whole size, with the insets it keeps.
            Color.clear
                .onGeometryChange(for: WindowArea.self) { proxy in
                    WindowArea(size: proxy.size, top: proxy.safeAreaInsets.top, bottom: proxy.safeAreaInsets.bottom)
                } action: { windowArea = $0 }
                .ignoresSafeArea()
        }
        .onChange(of: columnVisibility) { _, shown in
            // The list column stays: the entry column alone is never left (a gesture or a key that hid both).
            if shown == .detailOnly { columnVisibility = .doubleColumn }
        }
        .environment(\.usesSystemBars, true)
        .sheet(isPresented: $showPadSettings) {
            PadSettingsSheet()
                .presentationSizing(.page)
        }
    }

    /// iPad: the width from which the sidebar, the list and the entry all lie side by side (landscape of the 11 and
    /// 13 inch iPads); below it the list and the entry (portrait, smaller windows).
    private static let threeColumnWidth: CGFloat = 1100

    private var fitsThreeColumns: Bool { splitWidth >= Self.threeColumnWidth }

    /// iPad: the columns for the window's width, at the start and whenever the width crosses `threeColumnWidth`
    /// (turning the iPad, resizing the window); what the sidebar button chose in between stays.
    private func fitColumns(to width: CGFloat) {
        let wasMeasured = splitWidth > 0
        let wasWide = fitsThreeColumns
        splitWidth = width
        guard !wasMeasured || wasWide != fitsThreeColumns else { return }
        columnVisibility = fitsThreeColumns ? .all : .doubleColumn
    }

    /// iPad: the place Chat shows its chats in the list column and the conversation in the entry column.
    private var padShowsChat: Bool {
        sizeClass != .compact && page == .chat
    }

    /// iPad: the entry column. The open entry, else what the list column invites to; on the Chat side the conversation,
    /// with an entry opened from it (a source of an answer) pushed over it.
    private var padDetail: some View {
        NavigationStack(path: padDetailPath) {
            Group {
                if padShowsChat {
                    ChatPage(notes: notes, projects: projects, navigation: chatNavigation, part: .conversation) { openNote($0) }
                        .navigationTitle(chatTitle)
                        .navigationBarTitleDisplayMode(.inline)
                } else if let note = selectedNote {
                    noteView(note, onBack: nil)
                } else if page == .bowls {
                    // The Bowls page lists bowls, not entries: the column invites to open one.
                    PadNoEntry(title: "Pick a Bowl", message: "Open a bowl or a smart filter to see its entries here.")
                } else {
                    PadNoEntry(title: "No Entry Selected", message: "Pick an entry from the list.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.appBackground)
            .navigationDestination(for: DetailRoute.self) { route in
                if let note = notes.first(where: { $0.id == route.id }) ?? (draft?.id == route.id ? draft : nil) {
                    noteView(note, onBack: nil)
                }
            }
        }
    }

    /// iPad, Chat side: an entry opened from the conversation is pushed over it; going back lets go of it.
    private var padDetailPath: Binding<[DetailRoute]> {
        Binding(
            get: { padShowsChat ? selection.map { [DetailRoute(id: $0)] } ?? [] : [] },
            set: { if $0.isEmpty, padShowsChat { selection = nil } }
        )
    }

    /// The title of the conversation in the entry column (iPad).
    private var chatTitle: String {
        let title = chatNavigation.openID.flatMap { id in chatThreads.first { $0.id == id }?.title } ?? ""
        return title.isEmpty ? String(localized: "New Chat") : title
    }

    /// The open entry is a page of the stack on a phone (and an iPad window of compact width); an iPad of regular
    /// width shows it in the entry column.
    private var entriesOnStack: Bool { sizeClass == .compact }

    /// iPad: the system bars (navigation bar, toolbar items) instead of the app's own bar (`ChromeBar`).
    private var usesSystemBars: Bool { sizeClass != .compact }


    /// The places and the search as tabs, "+" in the middle: Today · Inbox · + · Bowls · Search. Each place has its own
    /// stack, so it keeps where it was. "+" is no tab: it opens the Add sheet and the tab in front stays.
    private var tabs: some View {
        // The system's tab bar is hidden: its five even slots left no room for a big "+" (owner revision 6). The
        // app's own bar (`PlaceTabBar`) lies over the bottom, and the pages keep its height free (lists scroll under
        // it). While choosing several the selection bar takes its place; with the keyboard up the pages lose the
        // room, and the keyboard covers the bar.
        let layout = TabBarLayout(width: screenWidth)
        let showsBar = !isSelecting
        let room = showsBar && !keyboardShown ? max(0, layout.contentInset - bottomSafeArea) : 0
        let selected = place.tab
        // Each tab is named after the side it shows (To-dos, Chat), its badge counts that side: the Inbox tab on
        // To-dos the open to-dos, as the iPad's sidebar row To-dos does.
        let sides = Dictionary(uniqueKeysWithValues: Place.tabs.map { ($0, shown(in: $0)) })
        let inboxBadge = sides[.inbox] == .todos ? Todos.folder(notes).open : inboxCount
        let badges: [Place: Int] = [.today: Places.todayCount(notes), .inbox: inboxBadge]
        return TabView(selection: Binding(get: { place.tab }, set: { chooseTab($0) })) {
            ForEach(Place.tabs, id: \.self) { shown in
                // The app's own bowl is an image, not an SF Symbol (`Places.bowlsSymbol`).
                if SymbolImage.isOwn(shown.tabSymbol) {
                    Tab(shown.tabTitle, image: shown.tabSymbol, value: shown) {
                        placeStack(shown)
                            .toolbar(.hidden, for: .tabBar)
                    }
                } else {
                    Tab(sides[shown, default: shown].tabTitle, systemImage: sides[shown, default: shown].tabSymbol, value: shown) {
                        placeStack(shown)
                            .toolbar(.hidden, for: .tabBar)
                    }
                }
            }
        }
        // Each page of the stacks keeps it free (`keepsTabBarRoom`): a padding of the whole stack does not reach
        // the pages of a `NavigationStack`.
        .environment(\.tabBarRoom, room)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { screenWidth = $0 }
        // The home indicator's room (the pages' own room for the bar is added inside the tabs, so it is not in here);
        // a keyboard's height is not taken.
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
            if inset < 60 { bottomSafeArea = inset }
        }
        .overlay(alignment: .bottom) {
            // Counted from the screen's bottom edge; the keyboard covers the bar instead of lifting it.
            if showsBar {
                PlaceTabBar(
                    layout: layout, selection: selected, badges: badges, sides: sides,
                    onSelect: { chooseTab($0) },
                    onAdd: { tapAdd() },
                    onAddLongPress: { longPressAdd() }
                )
                .padding(.bottom, TabBarLayout.bottomGap)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds
            // A software keyboard on screen; a hardware keyboard's shortcut bar alone does not count.
            keyboardShown = frame.minY < screen.maxY - 120 && frame.height > 120
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
    }

    /// A tab of the bar: its place comes to the front on the side it was left on (Inbox or To-dos, Search or Chat);
    /// the one in front goes back to its start (as with the system's tab bar).
    private func chooseTab(_ tab: Place) {
        if tab == place.tab {
            if !(paths[tab] ?? []).isEmpty { paths[tab] = [] }
        } else {
            place = shown(in: tab)
        }
    }

    /// A row of the iPad's sidebar: its place comes to the front; the one in front goes back to its start.
    private func choosePlace(_ chosen: Place) {
        if chosen == place {
            if !(paths[stackKey(chosen)] ?? []).isEmpty { paths[stackKey(chosen)] = [] }
        } else {
            place = chosen
        }
    }

    private var inboxCount: Int { Places.inboxCount(notes) }

    /// Every page is a real page of the system's stack: it slides in, the swipe from the edge follows the finger,
    /// and what lies below keeps its scroll position.
    /// `shown` is a phone's tab (its root is the side it shows) or an iPad's place.
    private func placeStack(_ shown: Place) -> some View {
        NavigationStack(path: pathBinding(shown)) {
            listColumn(usesSystemBars ? shown.root : self.shown(in: shown).root)
                .navigationDestination(for: ListRoute.self) { route in
                    switch route {
                    case .page(let next):
                        listColumn(next)
                    case .note(let id):
                        // By its id: the note stays on the page while the page slides away.
                        if let note = notes.first(where: { $0.id == id }) ?? (draft?.id == id ? draft : nil) {
                            noteView(note, onBack: { selection = nil })
                        }
                    }
                }
        }
    }

    private func noteView(_ note: Note, onBack: (() -> Void)?) -> some View {
        NoteDetailView(
            note: note, onClose: { close(note) },
            startsRecording: note.id == draft?.id && note.id != typedDraftID,
            focusesTitle: note.id == typedDraftID,
            onBack: onBack
        )
            .id(note.id)
            .keepsTabBarRoom()
            .environment(\.openNote, { openNote($0) })
            .environment(\.askAboutBowl, { askAbout($0) })
            .environment(\.allNotes, notes)
    }

    /// The open note is on the stack on a phone and where an iPad has no room beside the list; elsewhere it has the
    /// column beside the list.
    private func syncNoteRoute() {
        var routes = currentPath.filter(\.isPage)
        if entriesOnStack, let selection { routes.append(.note(selection)) }
        if routes != currentPath { paths[activeStack] = routes }
    }

    /// Goes to a page: a place's own page brings it to the front at its start (on a phone its tab on that side: To-dos
    /// the Inbox tab on To-dos, Chat the Search tab on Chat; on an iPad its row of the sidebar); any other page is
    /// pushed onto the stack it belongs to (a bowl, a smart filter, Archive, Recently Deleted and Settings onto Bowls;
    /// the Weekly Review onto Today; Settings onto Today when Today is in front, from its gear), or the stack is taken
    /// back to it when it is on it already. On an iPad of regular width Settings opens as a sheet.
    private func go(_ target: ListPage) {
        if let root = Place(root: target) {
            place = root
            paths[stackKey(root)] = []
            return
        }
        // iPad: Settings is a sheet over the window (its subpages are pushed inside it).
        if usesSystemBars, target.isSettings {
            showPadSettings = true
            return
        }
        let owner = currentPath.contains(.page(target)) ? place
            : target.isSettings && place == .today ? place : target.place
        place = owner
        push(target, on: owner)
    }

    private func push(_ target: ListPage, on owner: Place) {
        let key = stackKey(owner)
        if target == owner.root {
            paths[key] = []
            return
        }
        var routes = (paths[key] ?? []).filter(\.isPage)
        if let index = routes.firstIndex(of: .page(target)) {
            routes = Array(routes[...index])
        } else {
            routes.append(.page(target))
        }
        paths[key] = routes
    }

    @ViewBuilder
    private var columns: some View {
        Group {
            if sizeClass == .compact {
                tabs
            } else {
                splitView
            }
        }
        .onAppear(perform: syncNoteRoute)
        .onChange(of: selection) { syncNoteRoute() }
        .onChange(of: sizeClass) { syncNoteRoute() }
        .onChange(of: currentPath) {
            // Swiped back from the note.
            if entriesOnStack, selection != nil, currentPath.last?.isPage != false { selection = nil }
        }
        .onChange(of: page) { old, new in
            guard sizeClass != .compact else { return }
            // iPad: the entry in the entry column belonged to the page that was left; another page does not show it.
            if old != new { selection = nil }
            syncNoteRoute()
        }
        .onChange(of: place) { old, new in
            // The phone's tabs remember their side: the Inbox tab comes back on To-dos, Search on Chat.
            remember(new)
            let (oldKey, newKey) = (stackKey(old), stackKey(new))
            // A new note left empty in the tab that was left goes with it.
            if let draft, draft.modelContext == nil, paths[oldKey]?.last == .note(draft.id) { paths[oldKey]?.removeLast() }
            // The tab in front says which note is open: the one on top of its stack, if any.
            if case .note(let id)? = paths[newKey]?.last { selection = id } else { selection = nil }
        }
    }

    var body: some View {
        smartFilterDialogs(bowlDialogs(triageAndArchive(columns)))
        // The menu bar and the keyboard shortcuts (`PlaceCommands`).
        .focusedSceneValue(\.placeCommands, commandActions)
        .onChange(of: page) { old, new in
            // Another page: what was chosen there is let go, and so is the Add sheet's last "Into:".
            isSelecting = false
            chosen = []
            addInto = nil
            // Today opens on today.
            if new == .today, old != .today { todayDay = nil }
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
            // An entry link that came before its entry was loaded.
            if EntryLinkRouter.waiting != nil { openRequestedEntry() }
        }
        .sheet(isPresented: $showAdd, onDismiss: runPendingAdd) {
            addSheet()
        }
        .onChange(of: showAddPopover) { _, shown in
            // iPad: what the popover asked for, once it is gone (a sheet cannot open while it closes).
            guard !shown, pendingAdd != nil else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                runPendingAdd()
            }
        }
        .fullScreenCoverOrSheet(isPresented: $showRecorder) {
            RecordingView(title: appointmentTitle) { result, names, liveText, written in
                addRecording(from: result, speakerNames: names, liveText: liveText, written: written)
            }
        }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio, .movie]) { result in
            importAudio(result)
        }
        .modifier(FileIntake(isPicking: $showFileImporter) { addFiles($0) })
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner { url in
                showScanner = false
                if let url { addFiles([url]) }
            }
            .ignoresSafeArea()
        }
        .alert("Import Failed", isPresented: Binding(get: { audioImportError != nil }, set: { if !$0 { audioImportError = nil } })) {
            Button("OK") { audioImportError = nil }
        } message: {
            Text(audioImportError ?? "")
        }
        .modifier(DailyHintRefresh(notes: notes, signature: indexSignature, hintsEnabled: hintsEnabled))
        .sheet(isPresented: $showCalendar) {
            RecordMeetingSheet(
                onPick: { appointment in startRecording(for: appointment) },
                onNew: { startRecording(titled: nil) }
            )
        }
        .alert(askingTemplate?.name ?? "", isPresented: Binding(get: { askingTemplate != nil }, set: { if !$0 { askingTemplate = nil } })) {
            TextField("Title", text: $templateTitle)
            Button("Cancel", role: .cancel) { askingTemplate = nil }
            Button("Create") {
                if let askingTemplate { addFromTemplate(askingTemplate, title: templateTitle) }
                askingTemplate = nil
            }
        } message: {
            Text("What is it about?")
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
        // A `porridge://entry/<UUID>` link (another entry, a widget, another app); on a cold launch it waits until the list appears.
        .modifier(EntryLinkOpening(open: openRequestedEntry))
        // The widgets' copy of the notes, and what was ticked in a widget or added by a shortcut.
        .modifier(WidgetSyncModifier(notes: notes))
        .alert("Start Recording?", isPresented: $confirmLinkMeeting) {
            Button("Start Recording") {
                guard !showRecorder else { return }
                showCalendar = false
                startRecording(titled: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A link asked Porridge to record a meeting.")
        }
        .alert("Delete All in Recently Deleted?", isPresented: $confirmEmptyTrash) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                if let selection, notes.first(where: { $0.id == selection })?.isDeleted == true { self.selection = nil }
                notes.filter(\.isDeleted).forEach { NoteStore.deletePermanently($0, in: context) }
            }
        } message: {
            Text("This cannot be undone.")
        }
        .alert(
            "Delete Note Now?",
            isPresented: Binding(get: { deletingNow != nil }, set: { if !$0 { deletingNow = nil } })
        ) {
            Button("Cancel", role: .cancel) { deletingNow = nil }
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

    /// New bowl, renaming and deleting one (a function of its own: the body's chain is long enough).
    private func bowlDialogs(_ content: some View) -> some View {
        content
        .alert("New Bowl", isPresented: $showNewProject) {
            TextField("Name", text: $projectName)
            Button("Cancel", role: .cancel) { projectName = "" }
            Button("Create") {
                if let project = Projects.create(projectName, in: context) { go(.project(project.id)) }
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
        .alert(
            "Delete “\(deletingProject?.name ?? "")”?", isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }),
            presenting: deletingProject
        ) { project in
            // The bowl comes with the dialog: closing it may clear `deletingProject` before this runs.
            Button("Delete Bowl", role: .destructive) {
                leave(.project(project.id))
                // A shared bowl stops being shared first, so its entries do not leave it one by one for the others.
                BowlSharing.shared.bowlWillBeDeleted(project.id)
                Projects.delete(project, in: context)
                deletingProject = nil
            }
            Button("Cancel", role: .cancel) { deletingProject = nil }
        } message: { project in
            Text(BowlSharing.shared.isShared(project.id)
                ? "Its meetings, notes and links stay. The people you shared it with lose access."
                : "Its meetings, notes and links stay.")
        }
    }

    /// Triage, the selection bar's word to the undo toast, and a bowl that was just archived.
    private func triageAndArchive(_ content: some View) -> some View {
        content
        // Triage: full screen on a phone; on an iPad of regular width a page-sized sheet with the system's bar.
        .fullScreenCover(isPresented: Binding(get: { showTriage && !usesSystemBars }, set: { showTriage = $0 })) {
            TriageView()
        }
        .sheet(isPresented: Binding(get: { showTriage && usesSystemBars }, set: { showTriage = $0 })) {
            TriageView(inSheet: true)
                .presentationSizing(.page)
        }
        .onChange(of: Set(projects.filter(\.isArchived).map(\.id))) { old, new in
            // A bowl just archived (its ⋯, a swipe, another device) leaves the stacks it is open on: the list goes back
            // to the Bowls page and an entry of it open beside the list closes with it. A bowl opened from Archive is
            // archived already and stays.
            for id in new.subtracting(old) { leave(.project(id)) }
        }
        // The undo toast keeps above the selection bar (`RootView`).
        .preference(key: SelectionBarShownKey.self, value: isSelecting)
    }

    /// The smart filters' editor, renaming and deleting.
    private func smartFilterDialogs(_ content: some View) -> some View {
        content
        .sheet(item: $smartFilterDraft) { draft in
            SmartFilterEditor(draft: draft, notes: notes) { saved in
                if draft.existing == nil { go(.smartFilter(saved.id)) }
            }
        }
        .alert("Rename Smart Filter", isPresented: Binding(get: { renamingFilter != nil }, set: { if !$0 { renamingFilter = nil } })) {
            TextField("Name", text: $filterName)
            Button("Cancel", role: .cancel) { renamingFilter = nil }
            Button("Rename") {
                if let renamingFilter { SmartFilterStore.shared.rename(renamingFilter.id, to: filterName) }
                renamingFilter = nil
            }
        }
        .alert(
            "Delete “\(deletingFilter?.name ?? "")”?", isPresented: Binding(get: { deletingFilter != nil }, set: { if !$0 { deletingFilter = nil } }),
            presenting: deletingFilter
        ) { filter in
            Button("Delete Smart Filter", role: .destructive) {
                leave(.smartFilter(filter.id))
                SmartFilterStore.shared.delete(filter.id)
                deletingFilter = nil
            }
            Button("Cancel", role: .cancel) { deletingFilter = nil }
        } message: { _ in
            Text("Only the saved search is deleted. The entries stay where they are.")
        }
    }

    /// A page that is about to go (its bowl or filter deleted) leaves every stack it is on.
    private func leave(_ gone: ListPage) {
        for (owner, routes) in paths {
            if let index = routes.firstIndex(of: .page(gone)) { paths[owner] = Array(routes[..<index]) }
        }
    }

    // MARK: - List

    /// A page of a place's stack: its head and its content. The content (`pageContent`) is the same everywhere; the head
    /// is the app's own bar on a phone (`ChromeBar`: back pill, title, the actions as pills) and the system's
    /// navigation bar on an iPad of regular width (large title, back button, the same actions as toolbar items). The
    /// actions are defined once (`listActions`, `barAddButton`).
    @ViewBuilder
    private func listColumn(_ shown: ListPage) -> some View {
        if usesSystemBars {
            // The room of empty views: below the navigation bar (its safe area).
            pageContent(shown)
                .emptyStateArea()
                .background(Color.appBackground)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listColumnWidth = $0 }
                .environment(\.highlightedEntry, selection)
                .navigationTitle(listTitle(shown))
                // Search: inline, the search field and its chips right under the bar. A large title there left an
                // empty band of its height above the field once a search ran (the results list replaced the recents).
                .navigationBarTitleDisplayMode(shown != .search && largeTitleFits(listTitle(shown)) ? .large : .inline)
                .toolbar { pageToolbar(shown) }
        } else {
            VStack(spacing: 0) {
                ChromeBar(
                    title: listTitle(shown), systemImage: listIcon(shown), tint: listTint(shown), onBack: barBack(shown),
                    onTitleTap: shown == .today && todayDay != nil ? { withAnimation(.snappy) { todayDay = nil } } : nil,
                    titleHint: String(localized: "Back to today")
                ) {
                    listActions(shown)
                }
                .padding(.bottom, Look.headerGap)

                // The room of empty views: from here (the head's lower edge) to the tab bar, bars or not.
                VStack(spacing: 0) {
                    // The switch of a tab with two places (Inbox | To-dos, Search | Chat): it stays while the side
                    // below it changes.
                    tabSwitcher(shown)
                    pageContent(shown)
                }
                .emptyStateArea()
            }
            .background(Color.appBackground)
            .keepsTabBarRoom()
            .navigationTitle(listTitle(shown))
            // Own bar (ChromeBar) instead of the system one: title on the left as in Things, plain icons on the right.
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    /// iPad: whether the page's title fits as a large title into the list column (the system cuts it with "…" where it
    /// does not: "Weekly Revi…" with the largest text sizes); else the page has the inline title, whole. Measured with
    /// the large title's font at the text size in use against the narrowest list column.
    private func largeTitleFits(_ title: String) -> Bool {
        guard typeSize.isAccessibilitySize else { return true }
        let base = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory))
        let font = UIFont.systemFont(ofSize: base.pointSize, weight: .bold)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
        // The list column is at least 300 pt wide, the title keeps the bar's margins.
        return width <= 300 - 2 * 20
    }

    /// iPad: the page's actions as toolbar items at the trailing end of the list column's bar, "+" last on its own,
    /// the one prominent action (the system moves what does not fit into its overflow menu).
    /// "+" is an item of its own with the highest visibility priority (iOS 27), so the system never moves it into
    /// the overflow menu; Today's day pair ‹ › is one item (a toolbar item of its own, so the system cannot take one
    /// chevron and leave the other) right below it, "Today" (another day) below that, the Weekly Review the lowest.
    /// "Today" (another day) is always there, a symbol where the room is small (`todayBarRoom`); the Weekly Review
    /// goes into the system's overflow menu ⋯ where it does not fit, never out of reach (in a window of 829 pt both
    /// had been left out: only "‹ › +"); on another day in a narrow bar it leaves the bar so "Today" keeps its place
    /// (`showsPadWeeklyReviewItem`). Before iOS 27 (no priorities) Today's bar still leaves them out by its room.
    @ToolbarContentBuilder
    private func pageToolbar(_ shown: ListPage) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarItemGroup(placement: .topBarTrailing) {
                listActions(shown)
            }
            if shown == .today, showsPadTodayButton {
                ToolbarItem(placement: .topBarTrailing) {
                    backToTodayButton
                }
            }
            if shown == .today {
                ToolbarItem(placement: .topBarTrailing) {
                    padDayPair
                }
                .visibilityPriority(.high)
            }
            if shown == .today, showsPadWeeklyReviewItem {
                ToolbarItem(placement: .topBarTrailing) {
                    weeklyReviewButton
                }
                .visibilityPriority(.low)
            }
            ToolbarItem(placement: .topBarTrailing) {
                barAddButton(shown)
            }
            .visibilityPriority(ToolbarItemVisibilityPriority(higherThan: .high))
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                listActions(shown)
            }
            if shown == .today, showsPadTodayButton {
                ToolbarItem(placement: .topBarTrailing) {
                    backToTodayButton
                }
            }
            if shown == .today {
                ToolbarItem(placement: .topBarTrailing) {
                    padDayPair
                }
            }
            if shown == .today, showsPadWeeklyReview {
                ToolbarItem(placement: .topBarTrailing) {
                    weeklyReviewButton
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                barAddButton(shown)
            }
        }
    }

    /// iPad: the room of Today's trailing bar items: the list column's width less what stands at the bar's leading
    /// end. Where the list column is the window's first (the sidebar hidden), the sidebar button stands there (about
    /// 68 pt with its margin); in a window that does not fill the screen (Stage Manager, windowed apps) also the
    /// window's buttons (about 62 pt more: measured 122 pt with the sidebar button in a 916 pt window).
    /// Measured with the system's own bar: full screen in landscape (sidebar shown) about 340 pt hold "Today ‹ › +"
    /// and on today "‹ › Weekly Review +"; in portrait (325 pt column, sidebar button) 257 pt hold "↺ ‹ › +" and
    /// "‹ › Weekly Review +"; in a window of 829 or 916 pt 212 pt held only three buttons ("‹ + ⋯").
    private var todayBarRoom: CGFloat {
        var leading: CGFloat = 0
        if columnVisibility != .all {
            leading += 68
            if isWindowed { leading += 62 }
        }
        return listColumnWidth - leading
    }

    /// iPad: the app's window does not fill the screen (its buttons stand in the leading bar).
    private var isWindowed: Bool {
        guard windowArea.size.width > 0,
              let screen = UIApplication.shared.connectedScenes.lazy.compactMap({ ($0 as? UIWindowScene)?.screen }).first
        else { return false }
        let bounds = screen.bounds.size
        return windowArea.size.width < bounds.width - 1 || windowArea.size.height < bounds.height - 1
    }

    /// iPad, Today on another day: "Today" brings back today. As the word from 300 pt of room, else as a symbol
    /// (about 44 pt), also with the largest text sizes (from xxxLarge). iOS 27: always in the bar (its priority is
    /// between the day pair's and the Weekly Review's; a window of 829 pt has room for it left of ‹ ›). Before iOS 27
    /// only from 235 pt of room (today also comes back with ⌘1 or View › Today).
    private var showsPadTodayButton: Bool {
        guard todayDay != nil else { return false }
        if #available(iOS 27.0, *) { return true }
        return listColumnWidth == 0 || todayBarRoom >= 235
    }

    private var todayButtonIsSymbol: Bool {
        todayDay != nil && (todayBarRoom < 300 || typeSize >= .xxxLarge)
    }

    /// iPad before iOS 27: the Weekly Review in Today's bar. On today from 235 pt of room; on another day ("Today"
    /// there too) from 400 pt and without the largest text sizes. Else it is not in the bar (View › Weekly Review and
    /// Search's Go To have it). From iOS 27 it is always an item, with the lowest priority (the overflow menu).
    private var showsPadWeeklyReview: Bool {
        guard listColumnWidth > 0 else { return true }
        if todayDay == nil { return todayBarRoom >= 235 }
        return todayBarRoom >= 400 && !typeSize.isAccessibilitySize
    }

    /// iPad, iOS 27: the Weekly Review as a bar item (lowest priority, into the overflow menu ⋯ where it does not
    /// fit). On another day only from 280 pt of room: the bar's trailing end holds three glass items in a window of
    /// 829–968 pt (about 218 pt: ‹ › 60 since round 9, "+" 45, a symbol or ⋯ 45, with their gaps), and the overflow menu is an item
    /// itself, so with the Weekly Review in ⋯ "Today" went into ⋯ too ("‹ › + ⋯"). Below 280 pt the bar is
    /// "↺ ‹ › +" and the Weekly Review is in View › Weekly Review, Search's Go To and in today's bar (the symbol
    /// "Today" leads there). From 280 pt the four items fit ("Today ‹ › Weekly Review +" in landscape, 340 pt).
    private var showsPadWeeklyReviewItem: Bool {
        todayDay == nil || listColumnWidth == 0 || todayBarRoom >= 280
    }

    /// iPad: "Today", back from another day (the phone taps the title for it).
    private var backToTodayButton: some View {
        Button { withAnimation(.snappy) { todayDay = nil } } label: {
            if todayButtonIsSymbol {
                Label("Today", systemImage: "arrow.uturn.backward.circle")
            } else {
                Text("Today")
            }
        }
        .help("Back to today")
        .accessibilityLabel("Today")
        .accessibilityIdentifier("TodayBackToToday")
    }

    /// iPad: the previous and the next day as one toolbar item (one glass capsule), so they stay together. No long
    /// press menu (round 10, N2: at the accessibility sizes the system gives a bar item's long press to the large
    /// content viewer, so a hidden menu there never opened; "Today" and the Weekly Review are in the bar, the View
    /// menu and Search's Go To). The chevrons keep the size of the bar's other symbols
    /// (at most the `.large` text size). A custom view that does not fit the bar is not put into the overflow menu,
    /// it is left out, so the pair is narrow: 2 × 30 pt (the phone's halves are 38). In a window of 829 or 916 pt
    /// (list column 340 pt, the window's buttons and the sidebar button at its leading end) the bar had no room to
    /// spare at the standard size: sidebar button to 309, ‹ › 329–405, "+" 425–461, ⋯ 481–517 (20 pt gaps, 14 pt
    /// margin). With the accessibility sizes the system's sidebar button grows from 36 to 42.5 pt, the pair no longer
    /// fit by 6.5 pt and was left out ("+ ⋯", rounds 8 and 9). At 60 pt it fits with 9.5 pt to spare on today and
    /// about 3 pt on another day ("↺ ‹ › +", the symbol grown from 40 to 46.5 pt). Beyond `.large` the large
    /// content viewer shows a chevron big, as the system's bar buttons do.
    private var padDayPair: some View {
        HStack(spacing: 0) {
            dayButton(-1, inPill: true, width: 30)
                .accessibilityShowsLargeContentViewer()
            dayButton(1, inPill: true, width: 30)
                .accessibilityShowsLargeContentViewer()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    @ViewBuilder
    private func pageContent(_ shown: ListPage) -> some View {
        switch shown {
        case .bowls:
            bowlsList
        case .todos:
            OpenTodosList(notes: notes, projects: projects, selection: $selection) { remove($0) }
        case .project:
            if let project = project(on: shown) {
                ProjectPage(
                    project: project, notes: notes, selection: $selection, isSelecting: $isSelecting, chosen: $chosen,
                    onRemove: { remove($0) },
                    onRecord: { startRecording(for: $0) },
                    onNewNote: { addNote(for: $0) }
                )
                .id(project.id)
            } else {
                // Deleted on another device.
                EmptyStateView(title: "Bowl Deleted", message: "This bowl is gone.", systemImage: "folder")
            }
        case .inbox:
            InboxPlace(
                notes: notes, projects: projects, selection: $selection, isSelecting: $isSelecting, chosen: $chosen,
                onRemove: { remove($0) }
            )
        case .today:
            TodayPage(
                notes: notes, day: $todayDay, selection: $selection, onRemove: { remove($0) },
                onRecord: { startRecording(for: $0) },
                onNewNote: { addNote(for: $0) },
                onHint: { openHint($0) }
            )
        case .smartFilter(let id):
            if let filter = SmartFilterStore.shared.filter(id) {
                SmartFilterPage(filter: filter, notes: notes, selection: $selection) { remove($0) }
                    .id(filter.id)
            } else {
                // Deleted on another device.
                EmptyStateView(title: "Smart Filter Deleted", message: "This smart filter is gone.", systemImage: "line.3.horizontal.decrease")
            }
        case .search:
            searchPage
        case .chat:
            // iPad: the chats in the list column, the conversation in the entry column (`padDetail`).
            ChatPage(notes: notes, projects: projects, navigation: chatNavigation, part: usesSystemBars ? .list : .whole) {
                openNote($0)
            }
        case .archive:
            archive
        case .trash:
            trash
        case .weeklyReview:
            // A page of Today's stack with the back pill (owner revision 10; before, a sheet). An entry opens on top.
            WeeklyReviewView(notes: notes, bowls: projects, onOpen: { openNote($0) })
        case .settings:
            SettingsView(isEmbedded: true)
                .environment(\.openListPage, { go($0) })
        case .voices:
            VoicesView()
        case .acknowledgements:
            AcknowledgementsView()
        }
    }

    /// The switch on top of a phone's tab that shows two places (owner revision 13): the Inbox tab's "Inbox | To-dos"
    /// and the Search tab's "Search | Chat". Each side carries its count only when there is one (`Places.countedTitle`,
    /// as the tab's badge: no "0"). An iPad of regular width has the places side by side in its sidebar and no switch.
    @ViewBuilder
    private func tabSwitcher(_ shown: ListPage) -> some View {
        switch shown {
        case .inbox, .todos:
            TabSwitcher(selection: Binding(get: { shown == .todos ? InboxSide.todos : .inbox }, set: { place = $0.place }), options: [
                (value: InboxSide.inbox, title: Places.countedTitle(String(localized: "Inbox"), inboxCount)),
                (value: InboxSide.todos, title: Places.countedTitle(String(localized: "To-dos"), Todos.folder(notes).open)),
            ])
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .emptyStateBar()
            .accessibilityIdentifier("InboxSide")
            // While choosing several the selection bar stands for the tab bar: the side stays.
            .disabled(isSelecting)
        case .search, .chat:
            TabSwitcher(selection: Binding(get: { shown == .chat ? SearchSide.chat : .search }, set: { place = $0.place }), options: [
                (value: SearchSide.search, title: String(localized: "Search")),
                (value: SearchSide.chat, title: String(localized: "Chat")),
            ])
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .emptyStateBar()
            .accessibilityIdentifier("SearchSide")
        default:
            EmptyView()
        }
    }

    /// The bowls with the smart filters and the Archive row (owner revision 13: no switch; the open to-dos are the
    /// Inbox tab's To-dos side on a phone, a place of their own on an iPad). Archive and Recently Deleted are pages
    /// pushed from here.
    private var bowlsList: some View {
        BowlsPlace(
            notes: notes, projects: projects, order: bowlOrder,
            onOpen: { go($0) },
            onNewBowl: { showNewProject = true },
            onRename: { project in
                projectName = project.name
                renamingProject = project
            },
            onDelete: { deletingProject = $0 },
            onSelect: { project in
                go(.project(project.id))
                Task { withAnimation(.snappy) { isSelecting = true } }
            },
            onAsk: { askAbout(Projects.key($0)) },
            onNewSmartFilter: { smartFilterDraft = .new(from: SmartFilterCriteria()) },
            onEditFilter: { smartFilterDraft = .edit($0) },
            onRenameFilter: { filter in
                filterName = filter.name
                renamingFilter = filter
            },
            onDeleteFilter: { deletingFilter = $0 }
        )
    }


    /// Search & Ask, a page of its own: what is found opens from it, and going back returns to the results. The
    /// empty field shows the recent searches and the tags.
    private var searchPage: some View {
        let tags = TagToken.counts(notes.filter { !$0.isDeleted })
        return SearchPane(
            text: $search, tokens: $tagTokens, kind: $searchKind, scope: $searchScope,
            bowls: HomeList.bowls(projects, notes: notes, order: bowlOrder),
            allBowls: projects,
            tags: tags,
            hasQuery: hasQuery,
            recentSearches: recentSearches,
            onRecent: { line in
                let parsed = SearchAsk.RecentSearches.parse(line, known: tags.map(\.name))
                tagTokens = parsed.tags.map { TagToken(name: $0) }
                search = parsed.text
            },
            onClearRecent: {
                SearchAsk.RecentSearches.clear()
                recentSearches = []
            },
            onSubmit: { keepSearch() },
            usesSystemField: usesSystemBars
        ) {
            searchResults
        }
        // iPad: the system's search field at the top of the list column, the tags as its tokens.
        .modifier(SystemSearchField(isOn: usesSystemBars, text: $search, tokens: $tagTokens, focused: $searchFieldFocused) {
            keepSearch()
        })
    }

    /// What is searched for is kept as a recent search (Return in the field, or a result opened from it).
    private func keepSearch() {
        SearchAsk.RecentSearches.add(search, tags: tagTokens.map(\.name))
        recentSearches = SearchAsk.RecentSearches.all()
    }

    /// ✦ AI › Ask About This Bowl on an entry, or the bowl's ⋯: the Search tab opens on Chat with the chat about the bowl.
    private func askAbout(_ bowl: String) {
        selection = nil
        chatNavigation.open(from: bowl, threads: chatThreads)
        go(.chat)
    }

    /// "Ask Porridge: …" in the search: the tab switches to its Chat side, a new chat about the search's scope opens
    /// and the question is asked there. Asking is always this choice; typing never starts a chat.
    private func handOver(_ question: String) {
        // A question is kept as a chat (the Chat side's Recent Chats), not as a recent search.
        dismissKeyboard()
        selection = nil
        let thread = ChatService.startChat(about: searchScope, in: context)
        chatNavigation.project = searchScope.chatKey
        chatNavigation.newScope = searchScope.chatKey
        chatNavigation.showsList = false
        chatNavigation.openID = thread.id
        go(.chat)
        let (all, bowls) = (notes, projects)
        Task { await ChatService.shared.ask(question, in: thread, notes: all, projects: bowls, context: context) }
    }

    /// A Go To row of the search.
    private func goTo(_ target: SearchAsk.Target) {
        keepSearch()
        switch target.destination {
        case .today: go(.today)
        case .inbox: go(.inbox)
        case .bowls: go(.bowls)
        case .openTodos: goToTodos()
        case .weeklyReview: go(.weeklyReview)
        case .triage:
            go(.inbox)
            showTriage = !Inbox.notes(notes).isEmpty
        case .archive: go(.archive)
        case .trash: go(.trash)
        case .settings: go(.settings)
        case .allChats:
            chatNavigation.showsList = true
            go(.chat)
        case .smartFilter(let id): go(.smartFilter(id))
        case .bowl(let id): go(.project(id))
        }
    }

    /// Every open to-do: the place To-dos (owner revision 13), on a phone the Inbox tab on its To-dos side (owner
    /// revision 10 had them on the Bowls tab). Search's Go To, the hint about overdue to-dos, the quick action and the
    /// widgets come here.
    private func goToTodos() {
        go(.todos)
    }

    /// The hint of the day was tapped: what it is about opens.
    private func openHint(_ hint: DailyHint) {
        switch hint.kind {
        case .meetingTodos: if let id = hint.noteID { openNote(id) }
        case .overdue: goToTodos()
        case .inbox: go(.inbox)
        }
    }

    private func endSelecting() {
        withAnimation(.snappy) {
            isSelecting = false
            chosen = []
        }
    }

    /// The archive: archived bowls only. Notes are never archived.
    private var archive: some View {
        let folders = HomeList.archivedProjects(projects)
        let contents = ProjectContent.byProject(notes, appointments: AppointmentLinks.shared.appointmentCounts())
        return List(selection: $selection) {
            if !folders.isEmpty {
                Section {
                    ForEach(folders) { project in
                        ProjectRow(
                            project: project,
                            content: contents[Projects.key(project)] ?? ProjectContent(),
                            onOpen: { go(.project(project.id)) },
                            onRename: {
                                projectName = project.name
                                renamingProject = project
                            },
                            onDelete: { deletingProject = project },
                            onAsk: { askAbout(Projects.key(project)) }
                        )
                        .lastInSection(project.id == folders.last?.id)
                    }
                } header: {
                    ListHeader(title: String(localized: "Bowls"), tint: .brandProject, isFirst: true)
                }
            }
        }
        .cardList()
        .overlay {
            if folders.isEmpty {
                EmptyStateView(
                    title: "Nothing Archived",
                    message: "Archive a bowl from its ⋯ menu, with a swipe or a long press.",
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
                    ForEach(deleted) { note in
                        NoteListRow(note: note) { remove(note) }
                            .lastInSection(note.id == deleted.last?.id)
                    }
                } header: {
                    Text("Notes are deleted after \(NoteStore.trashDays) days.")
                        .font(.footnote)
                        .textCase(nil)
                }
            }
        }
        .cardList()
        .overlay {
            if deleted.isEmpty {
                EmptyStateView(title: "Nothing Deleted", message: "Deleted notes stay here for \(NoteStore.trashDays) days.", systemImage: "trash")
            }
        }
    }

    /// The results of Search & Ask, in the order of `SearchAsk`: "Ask Porridge: …" (with typed text), the places,
    /// smart filters and bowls that fit ("Go To"), then the entries by date (open to-dos by when they are due).
    private var searchResults: some View {
        let found = foundNotes
        let question = SearchAsk.question(search)
        let targets = question == nil ? [] : SearchAsk.goTo(
            search, in: SearchAsk.targets(bowls: projects, filters: SmartFilterStore.shared.filters, notes: notes)
        )
        let grouped = searchKind == .todos
            ? Todos.dueGroups(found).map { (title: $0.title, label: String($0.title.prefix(1)), notes: $0.notes) }
            : SearchAsk.dateGroups(found)
        return List {
            if let question {
                Section {
                    Button { handOver(question) } label: {
                        SearchAskRow(
                            title: SearchAsk.askTitle(question), subtitle: SearchAsk.askSubtitle(searchScope, bowls: projects),
                            systemImage: "sparkles", tint: .brandNavy
                        )
                    }
                    .buttonStyle(.plain)
                    .cardListRow()
                    .lastInSection(true)
                    // iPad: the first row right under the search field and its chips, without the line above it that
                    // ran across the column (on no other page under the bars).
                    .listRowSeparator(usesSystemBars ? .hidden : .automatic, edges: .top)
                    .accessibilityIdentifier("SearchAsk")
                    .accessibilityHint("Opens the chat and asks this question")
                }
            }
            if !targets.isEmpty {
                Section {
                    ForEach(targets) { target in
                        Button { goTo(target) } label: {
                            SearchAskRow(title: target.title, subtitle: target.subtitle, systemImage: target.symbol, tint: tint(of: target))
                        }
                        .buttonStyle(.plain)
                        .cardListRow()
                        .lastInSection(target.id == targets.last?.id)
                        .accessibilityIdentifier("GoTo")
                    }
                } header: {
                    ListHeader(title: String(localized: "Go To"), tint: .brandNavy, isFirst: question == nil)
                }
            }
            ForEach(grouped, id: \.title) { group in
                Section {
                    ForEach(group.notes) { note in
                        Button {
                            keepSearch()
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
                    ListHeader(title: group.title, tint: .brandSky, isFirst: question == nil && targets.isEmpty && group.title == grouped.first?.title)
                }
            }
            if found.isEmpty, question != nil {
                Section {
                    Text("No entries contain “\(search.trimmingCharacters(in: .whitespaces))”.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        // iPad: in line with the rows above (20 pt in), and no line under it as under a last row.
                        .listRowInsets(usesSystemBars ? EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20) : nil)
                        .listRowSeparator(usesSystemBars ? .hidden : .automatic)
                }
            }
        }
        .cardList()
        // iPad: a scroll of the results lets go of the keyboard at once (the docked keyboard covers half the column).
        .scrollDismissesKeyboard(usesSystemBars ? .immediately : .interactively)
        .overlay {
            if found.isEmpty, question == nil {
                // Only tags or a kind chosen, and nothing fits (with typed text "Ask Porridge" stays as a row).
                let tags = tagTokens.map { "#" + $0.name }.joined(separator: " ")
                EmptyStateView(
                    title: tags.isEmpty ? "No Results" : "No Results for “\(tags)”",
                    message: "Check the spelling or try a new search.",
                    systemImage: "magnifyingglass"
                )
            }
        }
        // iPad: the results end above the docked keyboard, so the last of them scrolls into view above it (the list
        // reached down under the keyboard as if it were not there: rows behind it, and a drag there was the keyboard's).
        .endsAboveKeyboard(usesSystemBars)
    }

    private func tint(of target: SearchAsk.Target) -> Color {
        switch target.destination {
        case .bowl: .brandProject
        case .smartFilter, .settings, .archive, .weeklyReview, .allChats: .brandNavy
        case .triage: .brandSky
        case .trash: .red
        case .openTodos: .brandTask
        case .today: .brandNavy
        case .inbox: .brandSky
        case .bowls: .brandProject
        }
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
        !search.trimmingCharacters(in: .whitespaces).isEmpty || !tagTokens.isEmpty || searchKind != nil || searchScope != .everywhere
    }

    /// Opens a note; the list stays where it is.
    private func openNote(_ id: UUID) {
        Task {
            selection = id
        }
    }

    // MARK: - The bar

    /// The actions of the one-row bar of each page (iOS), "+" last: what does not fit the row is the first row of
    /// the content (the Inbox tab's Inbox | To-dos, a bowl's sharing line) or in a menu (a bowl's ⋯).
    @ViewBuilder
    private func listActions(_ shown: ListPage) -> some View {
        switch shown {
        case .today:
            // Today pages a day back and on; a tap on the title (another day) goes back to today. The Weekly Review
            // (owner revision 9; before, the card at the top of the Inbox). The gear opens Settings on Today's own
            // stack.
            if usesSystemBars {
                // iPad: "Today", the day pair and the Weekly Review are items of their own (`pageToolbar`).
                EmptyView()
            } else {
                todayPager
                weeklyReviewButton
                settingsButton
            }
        case .inbox:
            if isSelecting {
                doneSelectingButton
            } else {
                let isEmpty = Inbox.notes(notes).isEmpty
                // One entry at a time, full screen: File, Skip, Delete (Done for to-dos).
                Button { showTriage = true } label: {
                    Label("Triage", systemImage: "bolt.fill")
                }
                .help("Triage")
                .disabled(isEmpty)
                .accessibilityIdentifier("InboxTriage")
                // Several entries of the Inbox at once: into a bowl, done, their kind or sender, merged.
                Button { withAnimation(.snappy) { isSelecting = true } } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .help("Select")
                .disabled(isEmpty)
            }
        case .bowls:
            // Recently Deleted (owner revision 10), Sort Bowls By and the gear.
            trashButton
            bowlSortMenu
            settingsButton
        case .todos:
            // No own "+ To-do" (owner, round 9): a new to-do comes from "+" › To-do (the tab bar's on a phone, the
            // blue toolbar item on an iPad) or File › New To-do ⇧⌘N.
            EmptyView()
        case .project:
            if isSelecting {
                doneSelectingButton
            } else if let project = project(on: shown) {
                // iPad: sharing the bowl as a toolbar item of its own (on a phone it is in ⋯).
                if usesSystemBars, BowlSharing.isAvailable {
                    Menu {
                        BowlShareMenuItems(project: project)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share")
                    .accessibilityIdentifier("BowlShare")
                }
                Menu {
                    BowlMenuItems(
                        project: project,
                        onSelect: { withAnimation(.snappy) { isSelecting = true } },
                        onRename: {
                            projectName = project.name
                            renamingProject = project
                        },
                        onAsk: { askAbout(Projects.key(project)) },
                        onDelete: { deletingProject = project }
                    )
                } label: {
                    Label("Bowl", systemImage: "ellipsis")
                }
                .menuStyle(.button)
                // Redrawn after the system's sharing sheet closed (its label can come back blank otherwise).
                .id(BowlShareController.shared.sheetClosings)
                .accessibilityLabel("Bowl")
                .accessibilityIdentifier("BowlMenu")
                .help("Bowl")
            }
        case .trash:
            deleteAllButton
        case .chat:
            // While a conversation is open: a new chat (back to the chat's start is the back pill).
            // iPad: the conversation is in the entry column, the chats in the list column.
            if chatNavigation.openID != nil, !chatNavigation.showsList || usesSystemBars {
                Button { withAnimation(.snappy) { chatNavigation.startNew() } } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat")
                .accessibilityIdentifier("ChatNewChat")
            }
        case .search:
            if hasQuery {
                // What was searched for, kept as a smart filter.
                Button {
                    let kind: SmartFilterKind? = switch searchKind {
                    case .todos?: .openTodos
                    case .meetings?: .meetings
                    case .notes?: .notes
                    case .links?: .links
                    case .images?: .images
                    case .files?: .files
                    case nil: nil
                    }
                    smartFilterDraft = .new(from: SmartFilterCriteria.fromSearch(text: search, tags: tagTokens.map(\.name), kind: kind))
                } label: {
                    Label("Save as Smart Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Save as Smart Filter")
                .accessibilityIdentifier("SaveAsSmartFilter")
            }
        case .smartFilter(let id):
            if let filter = SmartFilterStore.shared.filter(id) {
                Menu {
                    Button { smartFilterDraft = .edit(filter) } label: { Label("Edit…", systemImage: "slider.horizontal.3") }
                    Button {
                        filterName = filter.name
                        renamingFilter = filter
                    } label: { Label("Rename", systemImage: "pencil") }
                    Divider()
                    Button(role: .destructive) { deletingFilter = filter } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Label("Smart Filter", systemImage: "ellipsis")
                }
                .menuStyle(.button)
            }
        case .archive, .weeklyReview, .settings, .voices, .acknowledgements:
            EmptyView()
        }
    }

    /// What the menu bar's commands do (`PlaceCommands`): the same actions as the bars and the Add sheet.
    private var commandActions: PlaceCommandActions {
        let open = selectedNote
        return PlaceCommandActions(
            newNote: { addFromKeyboard(todo: false) },
            newTodo: { addFromKeyboard(todo: true) },
            recordMeeting: { showCalendar = true },
            search: {
                go(.search)
                // iPad: the system's search field takes the keyboard.
                if usesSystemBars { Task { searchFieldFocused = true } }
            },
            showPlace: { shown in
                if place != shown {
                    place = shown
                } else if shown == .today, todayDay != nil {
                    // ⌘1 on another day: back to today (in a narrow window "Today" is not in the bar).
                    withAnimation(.snappy) { todayDay = nil }
                }
            },
            weeklyReview: { go(.weeklyReview) },
            settings: { go(.settings) },
            deleteEntry: open.flatMap { note in
                note.modelContext == nil || note.isDeleted ? nil : { remove(note) }
            },
            toggleSidebar: usesSystemBars ? {
                columnVisibility = columnVisibility == .all ? .doubleColumn : .all
            } : nil,
            sidebarShown: usesSystemBars && columnVisibility == .all
        )
    }

    /// ⌘N, ⇧⌘N: a new note or to-do opens with the keyboard in its title; a search field that had it lets go.
    private func addFromKeyboard(todo: Bool) {
        addInto = nil
        searchFieldFocused = false
        addNote(todo: todo)
        typedDraftID = draft?.id
    }

    /// "+" of the tab bar: the Add sheet, into the open bowl, else the Inbox. A long press makes a note at once (the
    /// tap that ends the press opens nothing).
    private func tapAdd() {
        if plusLongPressed {
            plusLongPressed = false
            return
        }
        openAdd()
    }

    private func longPressAdd() {
        plusLongPressed = true
        addInto = nil
        addNote()
        // The tap that ends the press may land outside the button: the flag does not outlive it.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            plusLongPressed = false
        }
    }

    /// "+" where there is no tab bar (iPad of regular width): the last toolbar item of every page in the list column,
    /// the one prominent action (sky), never in the entry column; while choosing several it gives way to Done. It opens
    /// the Add sheet as a popover at the button; a long press makes a note at once. On a phone "+" is the middle of the
    /// tab bar.
    @ViewBuilder
    private func barAddButton(_ shown: ListPage) -> some View {
        if usesSystemBars, !(isSelecting && (shown == .inbox || shown.isProject)) {
            Button { tapAdd() } label: {
                Label("Add", systemImage: "plus")
                    .fontWeight(.semibold)
            }
            .prominentToolbarButton(tint: .brandSky)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in longPressAdd() })
            .help("Add")
            .accessibilityIdentifier("PlaceAdd")
            .accessibilityAction(named: "New Note") { addNote() }
            // Only the page in front presents it (pages below on the stack keep their items).
            .popover(isPresented: Binding(get: { showAddPopover && shown == page }, set: { if !$0 { showAddPopover = false } })) {
                addSheet(inPopover: true)
            }
        }
    }

    /// Recently Deleted (owner revision 10: the trash pill in the Bowls bar, before the Deleted side of the
    /// switch): a page pushed onto the Bowls stack. When something is in it the symbol is filled.
    private var trashButton: some View {
        let hasDeleted = notes.contains(where: \.isDeleted)
        return Button { go(.trash) } label: {
            Label("Recently Deleted", systemImage: hasDeleted ? "trash.fill" : "trash")
        }
        .help("Recently Deleted")
        .accessibilityLabel("Recently Deleted")
        .accessibilityValue(hasDeleted ? String(localized: "Has entries") : String(localized: "Empty"))
        .accessibilityIdentifier("BowlsTrash")
    }

    /// Recently Deleted: everything in it goes for good, after asking.
    @ViewBuilder
    private var deleteAllButton: some View {
        if notes.contains(where: \.isDeleted) {
            Button(role: .destructive) { confirmEmptyTrash = true } label: {
                Label("Delete All", systemImage: "trash")
            }
            .help("Delete All")
            .accessibilityIdentifier("TrashDeleteAll")
        }
    }

    /// The Weekly Review, in Today's bar: the week's new entries, open to-dos and bowls (`WeeklyReviewView`), a page
    /// pushed onto Today's stack (owner revision 10).
    private var weeklyReviewButton: some View {
        Button { go(.weeklyReview) } label: {
            Label("Weekly Review", systemImage: "calendar.badge.checkmark")
        }
        .help("Weekly Review")
        .accessibilityLabel("Weekly Review")
        .accessibilityIdentifier("TodayWeeklyReview")
    }

    /// The gear: Settings (Today and Bowls). On an iPad the sidebar has it.
    @ViewBuilder
    private var settingsButton: some View {
        if sizeClass == .compact {
            Button { go(.settings) } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
            .accessibilityIdentifier("PlaceSettings")
        }
    }

    @ViewBuilder
    private var doneSelectingButton: some View {
        if usesSystemBars {
            Button { endSelecting() } label: {
                Text("Done").fontWeight(.semibold)
            }
        } else {
            Button { endSelecting() } label: {
                Text("Done").fontWeight(.semibold).padding(.horizontal, 10)
            }
            .buttonStyle(ChromePillButtonStyle(fill: .brandSky))
            .labelStyle(.titleOnly)
        }
    }

    /// Sort Bowls By as a menu in the Bowls bar (the same setting as Settings › General, on this device).
    private var bowlSortMenu: some View {
        Menu {
            Picker("Sort Bowls By", selection: $bowlOrder) {
                ForEach(HomeList.BowlOrder.allCases, id: \.self) { order in
                    Text(order.title).tag(order)
                }
            }
        } label: {
            Label("Sort Bowls By", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .accessibilityIdentifier("BowlSort")
        .help("Sort Bowls By")
    }

    /// The Add sheet, with "Into:" the place it was opened from; on an iPad of regular width a popover at "+".
    private func openAdd() {
        addInto = nil
        if usesSystemBars { showAddPopover = true } else { showAdd = true }
    }

    /// The Add sheet's content (a sheet on a phone, a popover on an iPad).
    private func addSheet(inPopover: Bool = false) -> some View {
        AddSheet(
            into: defaultInto, projects: projects, inPopover: inPopover,
            // iPadOS lays the popover over "+", just under the status bar (y 32 of 834 pt in landscape), and it may
            // reach down to the home indicator's safe area: the 11-inch iPad in landscape has 770 pt for the sheet of
            // about 740 pt. Both from the window only (`AddSheet.popoverRoom`), never from the popover's own frame.
            popoverBottom: windowArea.size.height > 0 ? windowArea.size.height - windowArea.bottom : 0,
            expectedPopoverTop: windowArea.top + 8
        ) { choice, into in
            pendingAdd = choice
            addInto = .some(into)
            showAdd = false
            showAddPopover = false
        }
    }

    /// Where the Add sheet puts things at first: the open bowl (not one shared with me to view only), else the Inbox.
    private var defaultInto: String? {
        guard let project = openProject, !BowlSharing.shared.isReadOnly(project.id) else { return nil }
        return Projects.key(project)
    }

    /// What the Add sheet asked for, once it is gone.
    private func runPendingAdd() {
        guard let choice = pendingAdd else { return }
        pendingAdd = nil
        switch choice {
        case .note: addTyped(todo: false)
        case .todo: addTyped(todo: true)
        case .meeting: showCalendar = true
        case .link: showAddLink = true
        case .scan: showScanner = true
        case .file: showFileImporter = true
        case .audio: showAudioImporter = true
        case .template(let template):
            if template.needsTitle {
                templateTitle = ""
                askingTemplate = template
            } else {
                addFromTemplate(template, title: "")
            }
        case .bowl:
            projectName = ""
            showNewProject = true
        }
    }

    /// The Add sheet's Note or To-do: the new entry opens with the keyboard in its title, as after ⌘N, so typing goes
    /// into it (it had opened without any focus: "+" › To-do on an iPad, round 10, B1). Where new notes record
    /// (Settings › Record New Notes Automatically) the note records instead, as before. Runs once the sheet or the
    /// popover is gone (`runPendingAdd`), so nothing takes the focus back.
    private func addTyped(todo: Bool) {
        addNote(todo: todo)
        if !AppSettings.recordsNewNotes { typedDraftID = draft?.id }
    }

    /// The previous and next day of Today as one pill at the right of the bar (phone). The day is view state (nil is
    /// today).
    private var todayPager: some View {
        HStack(spacing: 0) {
            dayButton(-1, inPill: true)
            dayButton(1, inPill: true)
        }
        .buttonStyle(.plain)
        .font(.body.weight(.semibold))
        .foregroundStyle(listTint(.today).readable)
        .background(listTint(.today).readable.opacity(0.14), in: Capsule())
    }

    private var shownDay: Date { todayDay ?? TodayCalendar.shared.today }

    /// A day back (-1) or on (1): half of the phone's pill, or a toolbar item of its own (iPad).
    private func dayButton(_ days: Int, inPill: Bool, width: CGFloat = 38) -> some View {
        Button { stepToday(days) } label: {
            Group {
                if days < 0 {
                    Label("Previous Day", systemImage: "chevron.left")
                } else {
                    Label("Next Day", systemImage: "chevron.right")
                }
            }
            .frame(minWidth: inPill ? width : nil, minHeight: inPill ? 36 : nil)
            .contentShape(Rectangle())
        }
        .help(days < 0 ? "Previous Day" : "Next Day")
        .accessibilityValue(TodayDay.fullDate(TodayDay.step(shownDay, by: days)))
        .accessibilityIdentifier(days < 0 ? "TodayPreviousDay" : "TodayNextDay")
    }

    /// A day on or back; today is kept as nil.
    private func stepToday(_ days: Int) {
        let next = TodayDay.step(todayDay ?? TodayCalendar.shared.today, by: days)
        withAnimation(.snappy) { todayDay = TodayDay.isToday(next) ? nil : next }
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
        case .bowls: "Bowls"
        case .project: project(on: shown)?.name ?? "Bowl"
        case .inbox: "Inbox"
        // The phone's Inbox tab on its To-dos side is named after it (the tab says "To-dos" too), as Chat.
        case .todos: "To-dos"
        case .today: todayDay.map { TodayDay.title($0) } ?? "Today"
        case .smartFilter(let id): SmartFilterStore.shared.filter(id)?.name ?? "Smart Filter"
        case .search: "Search"
        case .chat: chatPageTitle
        case .archive: "Archive"
        case .trash: "Recently Deleted"
        case .weeklyReview: "Weekly Review"
        case .settings: "Settings"
        case .voices: "Known Voices"
        case .acknowledgements: "Acknowledgements"
        }
    }

    /// The head on the Chat side: "Chat" at the chat's start and in an open conversation (its question is the first
    /// bubble right below, the chat's title would only repeat it); on a phone All Chats is a page of its own. The iPad's
    /// list column always lists the chats ("Chat"), the conversation has the entry column with its own title.
    private var chatPageTitle: String {
        !usesSystemBars && chatNavigation.showsList ? String(localized: "All Chats") : String(localized: "Chat")
    }

    /// Color of the square in front of the title.
    private func listTint(_ shown: ListPage) -> Color {
        switch shown {
        case .project: project(on: shown) == nil ? .brandSky : .brandProject
        case .bowls: .brandProject
        case .archive, .chat, .search, .smartFilter, .weeklyReview: .brandNavy
        case .trash: .red
        case .today: .brandNavy
        case .todos: .brandTask
        default: .brandSky
        }
    }

    /// The back pill of the bar: on every page above the place's own.
    /// On the Chat side an open conversation and All Chats have one too: back to All Chats when the conversation was
    /// opened from it, else to the chat's start.
    private func barBack(_ shown: ListPage) -> (() -> Void)? {
        if shown == .chat, chatNavigation.openID != nil || chatNavigation.showsList {
            return { withAnimation(.snappy) { chatNavigation.back() } }
        }
        guard Place(root: shown) == nil else { return nil }
        return { if !currentPath.isEmpty { paths[activeStack]?.removeLast() } }
    }

    /// Symbol in the colored square in front of the title (the list icon of Things).
    private func listIcon(_ shown: ListPage) -> String {
        switch shown {
        case .bowls: Places.bowlsSymbol
        case .project: "folder.fill"
        case .inbox: "tray.fill"
        case .todos: Place.todos.tabSymbol
        case .today: "calendar"
        case .smartFilter: "line.3.horizontal.decrease"
        case .search: "magnifyingglass"
        case .chat: Places.chatSymbol
        case .archive: "archivebox.fill"
        case .trash: "trash.fill"
        case .weeklyReview: "calendar.badge.checkmark"
        case .settings: "gearshape.fill"
        case .voices: "person.2.fill"
        case .acknowledgements: "heart.text.square.fill"
        }
    }

    /// What the search finds among the notes, those in archived bowls included.
    private var foundNotes: [Note] {
        // The index knows the words of every passage (transcripts included) without decoding anything.
        _ = NoteIndex.shared.version
        let indexed = search.isEmpty ? nil : NoteIndex.shared.noteIDs(matching: search)
        return SearchAsk.entries(
            notes, query: search, tags: tagTokens.map(\.name), kind: searchKind.map { kind in { kind.matches($0) } },
            scope: searchScope, indexMatches: indexed
        )
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
    }

    /// The bowl new things go into: the Add sheet's "Into:", else the one that is open (not one shared with me to
    /// view only: then the Inbox).
    private var projectForNew: String? {
        if let addInto { return addInto }
        return defaultInto
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
    }

    /// A new note for an appointment: named after it, linked to it and in its bowl (else the one open).
    private func addNote(for appointment: CalendarAppointment) {
        let note = Note()
        note.source = .note
        note.title = appointment.title
        if let bowl = AppointmentLinks.shared.bowl(for: appointment) ?? projectForNew {
            note.projectIDs = [bowl]
        }
        AppointmentLinks.shared.link(note, to: appointment, in: nil)
        draft = note
        selection = note.id
    }

    /// A note or to-do made from a template, opened at once. Into the template's bowl, else the bowl chosen.
    private func addFromTemplate(_ template: NoteTemplate, title: String) {
        let note = NoteTemplates.create(from: template, title: title, fallbackBowl: projectForNew, in: context)
        selection = note.id
    }

    /// Opens the entry an entry link asked for, when this device has it. On a cold start the link comes before the
    /// entries are loaded: it waits until they are (`onChange` of the notes), and is not thrown away.
    private func openRequestedEntry() {
        guard let id = EntryLinkRouter.waiting, notes.contains(where: { $0.id == id }) else { return }
        _ = EntryLinkRouter.take()
        // Straight away, not in a later task: the tab's stack takes the entry in the same update.
        selection = id
    }

    private func runQuickAction() {
        guard let (action, fromLink) = QuickActionCenter.takeRequest() else { return }
        addInto = nil
        if action == .startMeeting, fromLink {
            if !showRecorder { confirmLinkMeeting = true }
            return
        }
        switch action {
        case .newNote:
            addNote()
        case .startMeeting:
            // Taken (and so cleared) first: a Record tapped while recording must not start a later meeting.
            let pending = MeetingAlertScheduler.shared.takePendingRecord()
            guard !showRecorder else { return }
            showCalendar = false
            // Record from the alert before a meeting: the recording is made for its appointment.
            if let event = pending {
                startRecording(for: event)
            } else {
                startRecording(titled: nil)
            }
        case .openToday:
            selection = nil
            go(.today)
        case .openInbox:
            selection = nil
            go(.inbox)
        case .openBowls:
            selection = nil
            go(.bowls)
        case .openChat:
            selection = nil
            go(.chat)
        case .openTodos:
            selection = nil
            goToTodos()
        case .search(let query):
            selection = nil
            go(.search)
            search = query
        case .openNote(let id):
            openNote(id)
        }
    }

    /// Records a meeting for a calendar appointment: the note gets its title.
    private func startRecording(for event: CalendarAppointment) {
        startRecording(titled: event.title)
        appointment = event
    }

    /// Opens the recorder once the sheet with the appointments is gone.
    private func startRecording(titled title: String?) {
        appointmentTitle = title
        appointment = nil
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
        if let appointment {
            MeetingLinks.remember(appointment, for: note.id)
            AppointmentLinks.shared.linkMeeting(note, to: appointment, in: context)
        }
        appointment = nil
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
        if let project = projectForNew { note.projectIDs = Projects.assigned(project) }
        context.insert(note)
        try? context.save()
        draft = nil
        selection = note.id
        processing.enqueue(.transcript(note.id))
    }

    /// Moves a note to the trash, or deletes it for good when it already is there.
    private func remove(_ note: Note) {
        if note.isDeleted {
            deletingNow = note
        } else {
            if selection == note.id { selection = nil }
            Undoable.trash([note], in: context)
        }
    }

    /// Puts the keyboard away, whichever field has it.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Closes the open note (after it was deleted or recovered).
    private func close(_ note: Note) {
        selection = nil
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
    /// In the Inbox's list: how long the entry has been waiting there.
    var showsInboxAge = false
    /// The suggested bowl of an Inbox entry: "✦ Bowl" at the end of the footer, a tap files it (`onFile`).
    var suggestion: NoteFolder?
    var onFile: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.modelContext) private var context
    @Environment(\.ticksLeaveList) private var ticksLeaveList

    var body: some View {
        // Plain notes are sky blue, recorded meetings navy, saved links orange, to-dos green.
        HStack(alignment: .top, spacing: 12) {
            ThingsRowIcon(systemImage: note.kindSymbol, tint: tint, isPinned: note.isPinned)
                .accessibilityLabel(note.kindName)
                .padding(.top, 1)
            // No picture with the largest text sizes: the text needs the width.
            let thumbnail = note.attachmentsData == nil || typeSize.isAccessibilitySize ? nil : note.attachments.first(where: { $0.kind != .file })
            VStack(alignment: .leading, spacing: 3) {
              VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle)
                    .font(.body)
                    .foregroundStyle(note.isDone ? .secondary : .primary)
                    .strikethrough(note.isDone, color: .secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                // A document says what it is: "Invoice · Telekom · 119,00 € · 2 Mar 2026".
                let document = note.isDocument ? note.documentInfo.flatMap { $0.isEmpty ? nil : $0.line } : nil
                if let document {
                    Text(document)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.brandNavy)
                        .lineLimit(1)
                }
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(document == nil ? 2 : 1)
                }
              }
              // The footer must start below the picture, which is beside the text above it.
              .frame(minHeight: thumbnail == nil ? 0 : 52, alignment: .top)
                // The full line when there is room (narrow sidebar on the Mac); otherwise without domain and speakers.
                // With the largest text sizes the parts wrap onto as many lines as they need: one line would push the
                // row wider than the screen (and cut off its start).
                Group {
                    if typeSize.isAccessibilitySize {
                        WrapLayout(spacing: 8, lineSpacing: 2) { footer(compact: false, wraps: true) }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { footer(compact: false) }
                            HStack(spacing: 8) { footer(compact: true) }
                        }
                        .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                // Under a picture the line runs on to its trailing edge (the picture, the gap before it and the
                // spacing around the spacer), so the status ends where it does in rows without one.
                .padding(.trailing, thumbnail == nil ? 0 : -76)
                // Someone else added or changed it in a shared bowl, and it was not opened here since.
                if let activity = BowlSharing.shared.activityLine(for: note) {
                    SharedActivityLabel(text: activity)
                }
            }
            // The first picture or PDF of the note, small.
            if let attachment = thumbnail {
                Spacer(minLength: 0)
                RowThumbnail(attachment: attachment)
            }
            // A to-do is ticked right in the list, with its box at the end of the row; a deleted one only shows it.
            if note.isTodo {
                Spacer(minLength: 0)
                TodoCheckbox(isDone: note.isDone, size: 26) {
                    withAnimation(.snappy) { Todos.tick(note, leavesList: ticksLeaveList, in: context) }
                }
                .disabled(note.isDeleted || BowlSharing.shared.isReadOnly(note))
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var tint: Color {
        note.isTodo ? .brandTask : note.isLink ? .brandLink : (note.isRecording || note.isStored ? .brandNavy : .brandSky)
    }

    /// The parts of the footer. `wraps`: laid out by a `WrapLayout` (largest text sizes), so no part keeps a width
    /// wider than the row and there is no spacer.
    @ViewBuilder
    private func footer(compact: Bool, wraps: Bool = false) -> some View {
        if let deletedAt = note.deletedAt {
            Text(daysLeft(deletedAt))
                .foregroundStyle(Color.brandDangerText)
        } else {
            // "30. Oct 10:52": day and time without the "at" in between, to fit a narrow sidebar. Where a to-do names
            // its bowls (the to-dos folder) its due day says more, and the date makes room for them.
            if buckets.isEmpty || !note.isTodo {
                Text(note.updatedAt.formatted(.dateTime.day().month(.abbreviated)) + " " + note.updatedAt.formatted(.dateTime.hour().minute()))
                    .keepsWidth(!wraps)
            }
            // In the Inbox, how long it has been waiting there.
            if showsInboxAge, !compact, note.isInInbox, let waiting = Inbox.waitingLabel(since: note.createdAt) {
                Label(waiting, systemImage: "hourglass")
                    .labelStyle(.tight)
            }
        }
        if note.isTodo {
            TodoDueLabel(note: note)
            TodoProgressLabel(progress: note.todoProgress)
        }
        // Where a list mixes bowls the row names its own; on a narrow row the names give way first.
        if !buckets.isEmpty {
            Label(buckets.joined(separator: ", "), systemImage: "folder")
                .labelStyle(.tight)
                .foregroundStyle(Color.brandProject.readable)
                .truncationMode(.tail)
                .layoutPriority(compact ? -1 : 0)
        }
        if let domain = note.domain, !compact {
            Label(domain, systemImage: "link")
                .labelStyle(.tight)
        }
        if note.isRecording, note.duration > 0 {
            Text(note.duration.durationText)
                .keepsWidth(!wraps)
            if note.speakers.count > 1, !compact {
                Label("\(note.speakers.count)", systemImage: "person.2.fill")
                    .labelStyle(.tight)
                    .keepsWidth(!wraps)
            }
        }
        if !wraps { Spacer(minLength: 8) }
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
        .keepsWidth(!wraps)
        // The suggested bowl as one violet word: a tap files the entry there (with Undo).
        if let suggestion {
            SuggestionWord(name: suggestion.name, onFile: onFile)
                .layoutPriority(1)
        }
    }

    private func daysLeft(_ deletedAt: Date) -> String {
        let passed = Calendar.current.dateComponents([.day], from: deletedAt, to: Date()).day ?? 0
        let left = max(0, NoteStore.trashDays - passed)
        return left <= 1 ? String(localized: "Deleted tomorrow") : String(localized: "\(left) days left")
    }
}

extension View {
    /// Keeps the ideal width (`fixedSize`) when `keep`, else only the height, so the text may wrap.
    @ViewBuilder
    func keepsWidth(_ keep: Bool) -> some View {
        if keep { fixedSize() } else { fixedSize(horizontal: false, vertical: true) }
    }
}

/// iPad: an entry pushed over the conversation in the entry column (Chat side).
struct DetailRoute: Hashable {
    let id: UUID
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

/// The places (owner revision 13: places per platform), the one state both layouts are drawn from. An iPad of regular
/// width lists all six in its sidebar, each with a stack of its own: Today · Inbox · To-dos · Bowls · Search · Chat. A
/// phone (and an iPad window of compact width) has room for four tabs (Today · Inbox · + · Bowls · Search, `TabSlot`):
/// To-dos is the Inbox tab on its To-dos side, Chat the Search tab on its Chat side (`tab`, `InboxSide`, `SearchSide`).
/// So a window made narrow on To-dos shows the Inbox tab on To-dos, and made wide again the sidebar's To-dos.
enum Place: String, CaseIterable {
    case today, inbox, todos, bowls, search, chat

    /// The phone's tabs, from left to right ("+" between Inbox and Bowls is no tab).
    static let tabs: [Place] = [.today, .inbox, .bowls, .search]

    /// The phone's tab that shows the place: To-dos is a side of the Inbox, Chat a side of Search.
    var tab: Place {
        switch self {
        case .todos: .inbox
        case .chat: .search
        default: self
        }
    }

    /// The page at the start of the place's stack.
    var root: ListPage {
        switch self {
        case .today: .today
        case .inbox: .inbox
        case .todos: .todos
        case .bowls: .bowls
        case .search: .search
        case .chat: .chat
        }
    }

    /// The place whose own page `page` is, nil for a page pushed onto a place.
    init?(root page: ListPage) {
        guard let place = Place.allCases.first(where: { $0.root == page }) else { return nil }
        self = place
    }
}

/// A slot of the phone's tab bar: a place, or "+" in the middle, which is no tab (it opens the Add sheet).
enum TabSlot: Hashable {
    case place(Place)
    case add

    /// The tab bar from left to right: Today · Inbox · + · Bowls · Search.
    static let bar: [TabSlot] = [.place(.today), .place(.inbox), .add, .place(.bowls), .place(.search)]
}

/// The two sides of the Search tab (phone), switched at its top; the last one chosen is kept on this device. An iPad
/// of regular width has Search and Chat as places of their own.
enum SearchSide: String, CaseIterable {
    case search, chat

    static let key = "searchSide"

    /// The place the side shows.
    var place: Place { self == .chat ? .chat : .search }
}

/// The two sides of the Inbox tab (phone, owner revision 13; before, the Bowls tab's Bowls · To-dos): what is in no
/// bowl, and every open to-do. Not kept: every launch starts on Inbox. An iPad of regular width has To-dos as a place
/// of its own.
enum InboxSide: String, CaseIterable {
    case inbox, todos

    /// The place the side shows.
    var place: Place { self == .todos ? .todos : .inbox }
}

/// What the list column shows.
enum ListPage: Hashable {
    /// Today: the day's appointments with their entries and the to-dos due (`TodayPage`). A place.
    case today
    /// The inbox: what is new or in no bowl. A place.
    case inbox
    /// Every open to-do (`OpenTodosList`): a place on an iPad, the Inbox tab's To-dos side on a phone (`InboxSide`).
    case todos
    /// Every bowl, the smart filters and the Archive row (`BowlsPlace`). A place.
    case bowls
    /// Search & Ask: the search through everything, the places, smart filters and bowls to go to, and "Ask
    /// Porridge: …", which hands the question over to the chat. The last tab.
    case search
    /// One project with everything in it.
    case project(UUID)
    /// A saved search (`SmartFilter`): the entries that fit it, wherever they are.
    case smartFilter(UUID)
    /// The chat with the notes: a place on an iPad, the Search tab's Chat side on a phone (`SearchSide`), also reached
    /// by Ask About This Bowl and the search's "Ask Porridge: …".
    case chat
    /// The archived bowls, pushed onto the Bowls stack from the Archive row.
    case archive
    /// Recently Deleted, pushed onto the Bowls stack from the trash pill of its bar.
    case trash
    /// The weekly review (`WeeklyReviewView`), pushed onto Today's stack from the pill of its bar.
    case weeklyReview
    case settings
    case voices
    case acknowledgements

    /// The stack a page is pushed onto when it is opened from elsewhere.
    var place: Place {
        switch self {
        case .today, .weeklyReview: .today
        case .inbox: .inbox
        case .todos: .todos
        case .search: .search
        case .chat: .chat
        case .bowls, .project, .smartFilter, .archive, .trash, .settings, .voices, .acknowledgements: .bowls
        }
    }

    var isProject: Bool {
        if case .project = self { true } else { false }
    }

    var isSettings: Bool {
        switch self {
        case .settings, .voices, .acknowledgements: true
        default: false
        }
    }
}

extension EnvironmentValues {
    /// What the phone's tab bar (`PlaceTabBar`) and its raised "+" take at the bottom of a page, above the home
    /// indicator; 0 where there is no such bar, while choosing several and with the keyboard up.
    @Entry var tabBarRoom: CGFloat = 0
    /// Goes to another page of the list column; for the subpages of Settings.
    @Entry var openListPage: (ListPage) -> Void = { _ in }
    /// Opens a note by its id; for the way from a to-do back to the note it was made from.
    @Entry var openNote: (UUID) -> Void = { _ in }
    /// ✦ AI › Ask About This Bowl: the chat about a bowl (`Projects.key`), the last one about it taken up again.
    @Entry var askAboutBowl: (String) -> Void = { _ in }
    /// iPad: the entry open in the entry column; its row stands out (`ListRowLink`).
    @Entry var highlightedEntry: UUID?
    /// iPad of regular width: the pages use the system's navigation bar and toolbar items, not the app's own bar
    /// (`ChromeBar`, iPhone and compact width).
    @Entry var usesSystemBars = false
    /// Every note of the list, for views that look up others (the to-dos made from a summary).
    @Entry var allNotes: [Note] = []
    /// The list shows only open to-dos (Today): a to-do ticked done leaves it, so the tick offers Undo.
    @Entry var ticksLeaveList = false
}

extension View {
    /// Keeps the room of the phone's tab bar free at the bottom of a page: lists and scroll views scroll under the
    /// bar, their last rows (and the chat's field) end above it.
    func keepsTabBarRoom() -> some View {
        modifier(TabBarRoomPadding())
    }
}

private struct TabBarRoomPadding: ViewModifier {
    @Environment(\.tabBarRoom) private var room

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, room)
    }
}

/// Opens the entry of a `porridge://entry/<UUID>` link (`EntryLinkRouter`), now or once the list is on screen.
private struct EntryLinkOpening: ViewModifier {
    let open: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .porridgeOpenEntry)) { _ in open() }
            .onAppear { open() }
    }
}

/// Files come into the list through a picker ("Photo or File") or by dropping them on it (Mac, iPad).
/// The hint of the day kept up with the entries, the setting and the day.
private struct DailyHintRefresh: ViewModifier {
    let notes: [Note]
    let signature: Int
    let hintsEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: signature) { DailyHints.shared.refresh(notes: notes) }
            .onChange(of: hintsEnabled) { DailyHints.shared.refresh(notes: notes) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { DailyHints.shared.refresh(notes: notes) }
            }
    }
}

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

/// iPad: the window's whole size and the safe-area insets at its top and bottom (`NotesView.windowArea`).
struct WindowArea: Equatable {
    var size: CGSize = .zero
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}
