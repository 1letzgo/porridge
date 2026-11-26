import SwiftUI

/// The iPad's sidebar (regular width), as the Mac's main window: the places Today · Inbox · Bowls · Search (with the
/// counts of the phone's tab badges, only when there are any), then the pinned and all bowls and the smart filters to
/// go to straight away. Its head holds Settings (the gear) and the pill that hides it. The pages themselves open right
/// of it (`NotesView`), with their own bar.
struct PadSidebar: View {
    let notes: [Note]
    let projects: [NoteFolder]
    let order: HomeList.BowlOrder
    @Binding var selection: SidebarItem?
    var onSettings: () -> Void
    var onHide: () -> Void

    var body: some View {
        let bowls = HomeList.bowls(projects, notes: notes, order: order)
        let pinned = bowls.filter(\.isPinned)
        let others = bowls.filter { !$0.isPinned }
        let filters = SmartFilterStore.shared.filters
        List(selection: $selection) {
            Section {
                ForEach(Place.allCases, id: \.self) { shown in
                    Label {
                        Text(shown.tabTitle)
                    } icon: {
                        SymbolImage(shown.tabSymbol)
                    }
                    .badge(count(of: shown))
                    .tag(SidebarItem.place(shown))
                    .accessibilityIdentifier("Sidebar" + shown.tabTitle)
                }
            }
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { bowl in
                        Label(bowl.name, systemImage: "folder").tag(SidebarItem.bowl(bowl.id))
                    }
                }
            }
            if !others.isEmpty {
                Section("All Bowls") {
                    ForEach(others) { bowl in
                        Label(bowl.name, systemImage: "folder").tag(SidebarItem.bowl(bowl.id))
                    }
                }
            }
            if !filters.isEmpty {
                Section("Smart Filters") {
                    ForEach(filters) { filter in
                        Label(filter.name, systemImage: "line.3.horizontal.decrease").tag(SidebarItem.smartFilter(filter.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { head }
    }

    /// The count of a place as its tab badge shows it: Today the to-dos due, the Inbox what waits.
    private func count(of shown: Place) -> Int {
        switch shown {
        case .today: Places.todayCount(notes)
        case .inbox: Places.inboxCount(notes)
        case .bowls, .search: 0
        }
    }

    private var head: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings")
            .accessibilityIdentifier("SidebarSettings")
            Button(action: onHide) {
                Label("Hide Sidebar", systemImage: "sidebar.left")
            }
            .help("Hide Sidebar")
            .accessibilityIdentifier("HideSidebar")
        }
        .labelStyle(.iconOnly)
        .font(.body.weight(.medium))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .buttonStyle(ChromePillButtonStyle())
        .avoidsWindowControls()
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
