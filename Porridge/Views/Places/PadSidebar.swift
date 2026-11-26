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
