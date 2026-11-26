import SwiftUI

/// The iPad's sidebar (regular width), the first column of the system's split view: only the places Today · Inbox ·
/// Bowls · Search (with the counts of the phone's tab badges, only when there are any), as a sidebar list with the
/// system's selection. Single bowls and the smart filters are not listed here: they open from the Bowls page in the
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
                    Text(shown.tabTitle)
                } icon: {
                    // The place's symbol in its color (the bowl for Bowls).
                    SymbolImage(shown.tabSymbol)
                        .foregroundStyle(tint(of: shown).readable)
                }
                .badge(count(of: shown))
                .tag(shown)
                .accessibilityIdentifier("Sidebar" + shown.tabTitle)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Porridge")
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

    /// The count of a place as its tab badge shows it: Today the to-dos due, the Inbox what waits.
    private func count(of shown: Place) -> Int {
        switch shown {
        case .today: Places.todayCount(notes)
        case .inbox: Places.inboxCount(notes)
        case .bowls, .search: 0
        }
    }

    /// The colors of the places' heads on the phone.
    private func tint(of shown: Place) -> Color {
        switch shown {
        case .today, .search: .brandNavy
        case .inbox: .brandSky
        case .bowls: .brandProject
        }
    }
}
