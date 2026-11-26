import SwiftUI

/// Where the parts of the phone's tab bar go (owner revision 6). The system's floating tab bar gives its five slots
/// the same width and draws the selection capsule wider than a slot, so a big "+" in the middle ran into the Inbox's
/// badge and capsule. This bar is drawn by the app: the middle slot is as wide as the circle and a gap on each side,
/// the four tabs share the rest, and the circle rises above the bar's top edge.
struct TabBarLayout: Equatable {
    /// The screen's width.
    let width: CGFloat

    /// The bar's height, like the system's floating tab bar.
    static let height: CGFloat = 62
    /// From the bar's bottom edge to the screen's bottom edge (iPhone with a home indicator and iPhone SE alike).
    static let bottomGap: CGFloat = 21
    /// Inside the bar, before the first and after the last tab.
    static let padding: CGFloat = 4
    /// Room above the circle for the last row of a list.
    static let contentGap: CGFloat = 6

    /// Beside the bar; narrower on the iPhone SE so the tabs keep their room.
    var margin: CGFloat { width < 390 ? 14 : 20 }
    /// The whole bar; in landscape no wider than a phone's portrait bar.
    var barWidth: CGFloat { min(width - 2 * margin, 420) }
    var diameter: CGFloat { TabBarAddButton.diameter(screenWidth: width) }
    /// The middle slot: the circle and a gap on each side, so a neighbour's badge and selection capsule end before it.
    var middleWidth: CGFloat { diameter + (width < 390 ? 26 : 28) }
    /// Each of the four tabs.
    var tabWidth: CGFloat { (barWidth - 2 * Self.padding - middleWidth) / 4 }
    /// How far the circle reaches above the bar's top edge.
    var rise: CGFloat { width < 390 ? 10 : 12 }
    /// From the screen's bottom edge to the middle of the bar.
    static var barCenterFromBottom: CGFloat { bottomGap + height / 2 }
    /// From the screen's bottom edge to the middle of the circle.
    var circleCenterFromBottom: CGFloat { Self.bottomGap + Self.height + rise - diameter / 2 }
    /// From the screen's bottom edge to the top of the circle.
    var circleTopFromBottom: CGFloat { Self.bottomGap + Self.height + rise }
    /// What the pages keep free at the bottom: the bar, the circle above it and a small gap. Lists scroll under it.
    var contentInset: CGFloat { circleTopFromBottom + Self.contentGap }

    /// The middle of slot `index` (0…4, "+" is 2) from the bar's middle; negative is left of it.
    func slotCenter(_ index: Int) -> CGFloat {
        switch index {
        case 0: -(middleWidth / 2 + tabWidth * 1.5)
        case 1: -(middleWidth / 2 + tabWidth / 2)
        case 3: middleWidth / 2 + tabWidth / 2
        case 4: middleWidth / 2 + tabWidth * 1.5
        default: 0
        }
    }

    /// Where the Inbox's selection capsule ends, from the bar's middle (its slot's inner edge).
    var capsuleEndFromCenter: CGFloat { middleWidth / 2 }

    /// The badge starts this far right of its tab's middle (over the symbol's top right corner).
    static let badgeLead: CGFloat = 2

    /// Where a badge of `width` on the Inbox ends, from the bar's middle.
    func inboxBadgeEnd(width badge: CGFloat) -> CGFloat {
        -(slotCenter(1) + Self.badgeLead + badge)
    }

    /// A badge "120": three digits of the badge font and its padding.
    static let threeDigitBadge: CGFloat = 36
}

/// The phone's tab bar, drawn by the app: Today · Inbox · + · Bowls · Search (Chat on its Chat side) on a floating bar of glass, the selected
/// tab in a soft capsule, badges on Today and the Inbox, and the raised "+" (`TabBarAddButton`) in a wide middle
/// slot. Its symbols and words keep their size at every text size (a long press shows them in the large content
/// viewer), as in the system's tab bar. Tapping the tab in front takes its stack back to its start.
struct PlaceTabBar: View {
    let layout: TabBarLayout
    let selection: Place
    var badges: [Place: Int] = [:]
    /// The Search place's chosen side is Chat: its tab says "Chat" with the chat's symbol (also while another tab is in
    /// front, so the tab does not change on coming back).
    var searchShowsChat = false
    var onSelect: (Place) -> Void
    var onAdd: () -> Void
    var onAddLongPress: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(TabSlot.bar, id: \.self) { slot in
                    switch slot {
                    case .place(let place):
                        item(place)
                    case .add:
                        Spacer(minLength: 0).frame(width: layout.middleWidth)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, TabBarLayout.padding)
            .frame(width: layout.barWidth, height: TabBarLayout.height)
            .background { barBackground }

            TabBarAddButton(diameter: layout.diameter, onTap: onAdd, onLongPress: onAddLongPress)
                .offset(y: -(layout.circleCenterFromBottom - TabBarLayout.barCenterFromBottom))
        }
        .frame(width: layout.barWidth, height: TabBarLayout.height)
        // The bar's sizes do not follow the text size (as the system's tab bar).
        .dynamicTypeSize(.large)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .accessibilityIdentifier("PlaceTabBar")
    }

    @ViewBuilder
    private var barBackground: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.bar)
                .overlay(Capsule().strokeBorder(Look.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
    }

    private func item(_ place: Place) -> some View {
        let chosen = place == selection
        let count = badges[place] ?? 0
        let showsChat = place == .search && searchShowsChat
        let title = place.tabTitle(showsChat: showsChat)
        return Button { onSelect(place) } label: {
            VStack(spacing: 3) {
                place.tabIcon(chosen: chosen, showsChat: showsChat)
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 30, height: 27)
                    .overlay(alignment: .topLeading) {
                        if count > 0 { badge(count) }
                    }
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(chosen ? Color.accentColor : Color.primary)
            .frame(width: layout.tabWidth, height: TabBarLayout.height - 2 * TabBarLayout.padding)
            .background {
                if chosen {
                    Capsule().fill(Color.primary.opacity(0.08))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One element per tab: its name and badge, not the symbol, badge and name as parts of their own.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(title)
        .accessibilityValue(count > 0 ? "\(count)" : "")
        .accessibilityAddTraits(chosen ? [.isSelected] : [])
        // The identifier keeps the place's own name ("TabSearch" on the Chat side too).
        .accessibilityIdentifier("Tab" + place.tabTitle)
        .accessibilityShowsLargeContentViewer {
            Label { Text(title) } icon: { place.tabIcon(chosen: true) }
        }
    }

    /// A red badge over the symbol's top right corner; it grows to the right, toward the middle slot, which has room
    /// for three digits before the circle.
    private func badge(_ count: Int) -> some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.red, in: Capsule())
            .fixedSize()
            // From the symbol's middle (its frame is 30 pt wide) a little to the right, and above its top edge.
            .offset(x: 15 + TabBarLayout.badgeLead, y: -7)
            .accessibilityHidden(true)
    }
}

extension Place {
    /// The tab's name in the bar.
    var tabTitle: String {
        switch self {
        case .today: String(localized: "Today")
        case .inbox: String(localized: "Inbox")
        case .bowls: String(localized: "Bowls")
        case .search: String(localized: "Search")
        }
    }

    /// The name in the tab bar, the iPad's sidebar and the menu: the Search place on its Chat side is "Chat".
    func tabTitle(showsChat: Bool) -> String {
        self == .search && showsChat ? String(localized: "Chat") : tabTitle
    }

    /// The symbol, the chat's on the Chat side of the Search place.
    func tabSymbol(showsChat: Bool) -> String {
        self == .search && showsChat ? Places.chatSymbol : tabSymbol
    }

    /// The tab's symbol: an SF Symbol, for Bowls a bowl of the app's own (`BowlPlace`, `BowlPlaceFill` when chosen:
    /// SF Symbols has no bowl), drawn as large as the folder it replaces.
    @ViewBuilder
    func tabIcon(chosen: Bool, showsChat: Bool = false) -> some View {
        if self == .bowls {
            Image(chosen ? Places.bowlsSymbol : "BowlPlace")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: tabSymbol(showsChat: showsChat))
        }
    }

    var tabSymbol: String {
        switch self {
        case .today: "calendar"
        case .inbox: "tray.fill"
        case .bowls: Places.bowlsSymbol
        case .search: "magnifyingglass"
        }
    }
}
