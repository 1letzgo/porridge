import SwiftUI

/// The iPad's sidebar (regular width): only the places Today · Inbox · Bowls · Search (with the counts of the phone's
/// tab badges, only when there are any). Single bowls and the smart filters are not listed here: they open from the
/// Bowls page in the main view, as on the phone. Its head holds Settings (the gear) and the pill that hides it. The
/// pages themselves open right of it (`NotesView`), with their own bar.
struct PadSidebar: View {
    let notes: [Note]
    @Binding var selection: Place?
    var onSettings: () -> Void
    var onHide: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(Place.allCases, id: \.self) { shown in
                Label {
                    Text(shown.tabTitle)
                } icon: {
                    SymbolImage(shown.tabSymbol)
                }
                .badge(count(of: shown))
                .tag(shown)
                .accessibilityIdentifier("Sidebar" + shown.tabTitle)
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
