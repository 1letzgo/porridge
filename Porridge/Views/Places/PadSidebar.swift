import SwiftUI

/// The iPad's sidebar (regular width), the first column of the system's split view: the six places Today · Inbox ·
/// To-dos · Bowls · Search · Chat (owner revision 13: the phone's two switches are places of their own here), with
/// counts only when there are any (Today the to-dos due, the Inbox what waits, To-dos the open ones), as a sidebar
/// list with the system's selection. Single bowls and the smart filters are not listed here: they open from the Bowls page in the
/// list column, as on the phone. Settings is the gear in the sidebar's bottom bar. The system's sidebar button, the
/// edge swipe and ⌃⌘S show and hide it.
struct PadSidebar: View {
    let notes: [Note]
    @Binding var selection: Place?
    var onSettings: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(Place.allCases, id: \.self) { shown in
                Label {
                    // One line: with the largest text sizes the narrow column broke the word ("To-/day",
                    // "To-do/s"); a word too long for the row gets a little smaller instead.
                    Text(shown.tabTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } icon: {
                    // The place's symbol in its color (the bowl for Bowls: the outlined one, as wide as the
                    // symbols beside it; the bowl's own drawing leaves room above it, so it is drawn a size larger).
                    Group {
                        if shown == .bowls {
                            SymbolImage("BowlPlace", textStyle: .title2)
                        } else {
                            SymbolImage(shown.tabSymbol)
                        }
                    }
                    .foregroundStyle(tint(of: shown).readable)
                }
                .badge(count(of: shown))
                .tag(shown)
                // SidebarToday, SidebarInbox, SidebarTodos, SidebarBowls, SidebarSearch, SidebarChat.
                .accessibilityIdentifier("Sidebar" + shown.rawValue.capitalized)
            }
        }
        .listStyle(.sidebar)
        // The rows grow with the text size up to AX2 (33 pt body), so "To-dos 5" stays one line with its count in the
        // sidebar's column (AX5 broke "Today" and "To-dos" inside the word).
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .navigationTitle("Porridge")
        // No title in the sidebar's bar: in a window (Stage Manager, not full screen) the window's buttons left it
        // "Porrid…", and the places speak for themselves. The title stays the column's name (VoiceOver, the app
        // switcher).
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button(action: onSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
                .accessibilityIdentifier("SidebarSettings")
            }
        }
    }

    /// The count of a place: Today the to-dos due, the Inbox what waits (as the phone's tab badges), To-dos the open
    /// ones (as the phone's Inbox | To-dos switch).
    private func count(of shown: Place) -> Int {
        switch shown {
        case .today: Places.todayCount(notes)
        case .inbox: Places.inboxCount(notes)
        case .todos: Todos.folder(notes).open
        case .bowls, .search, .chat: 0
        }
    }

    /// The colors of the places' heads on the phone; To-dos in the to-dos' green.
    private func tint(of shown: Place) -> Color {
        switch shown {
        case .today, .search, .chat: .brandNavy
        case .inbox: .brandSky
        case .todos: .brandTask
        case .bowls: .brandProject
        }
    }
}

/// iPad: the entry column while no entry is open. Quiet, as Mail's "No Message Selected": a grey title and a line in
/// the middle of the column, without the bowl of the empty views, so it never stands beside an empty list's message
/// as a second one of the same weight.
struct PadNoEntry: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
