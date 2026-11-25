import SwiftUI

/// "+" in the middle of the phone's tab bar (Today · Inbox · + · Bowls · Search): a big round sky button drawn over
/// the tab bar's middle slot, which is no tab (`TabSlot.add`). A tap opens the Add sheet for where one is (in a bowl
/// "Into: <bowl>", else the Inbox); a long press makes a note at once. Its size does not follow the text size, like
/// the tab bar's symbols; with the largest text sizes a long press shows it in the large content viewer.
struct TabBarAddButton: View {
    var onTap: () -> Void
    var onLongPress: () -> Void

    /// The circle: clearly bigger than the tab symbols (about 26 pt), and clear of its neighbours. A badge "120" on
    /// the Inbox reaches to 21 pt from the bar's middle on the 375 pt iPhone SE and to 24 pt on a 390 pt iPhone; the
    /// Inbox's selection capsule about as far. So the circle is 36 pt on screens narrower than 390 pt and 40 pt on the
    /// others, with a short glow; it takes touches on `touchSize` (a full touch target) either way.
    static func diameter(screenWidth: CGFloat) -> CGFloat {
        screenWidth < 390 ? 36 : 40
    }

    static let touchSize: CGFloat = 48

    var body: some View {
        // Over the safe area (the reader takes no touches itself); the circle is put below its bottom edge, on the bar's
        // middle, counted from the screen's bottom. The keyboard covers both instead of lifting it.
        GeometryReader { proxy in
            button(diameter: Self.diameter(screenWidth: proxy.size.width))
                .position(x: proxy.size.width / 2, y: proxy.size.height + proxy.safeAreaInsets.bottom - Self.centerFromBottom)
        }
        .ignoresSafeArea(.keyboard)
    }

    private func button(diameter: CGFloat) -> some View {
        Button(action: onTap) {
            Image(systemName: "plus")
                .font(.system(size: diameter / 2, weight: .bold))
                .foregroundStyle(Color.brandSky.onFill)
                .frame(width: diameter, height: diameter)
                .background(Color.brandSky, in: Circle())
                .overlay(Circle().strokeBorder(Look.hairline, lineWidth: 0.5))
                .shadow(color: Color.brandSky.opacity(0.3), radius: 2, y: 1)
                .frame(width: Self.touchSize, height: Self.touchSize)
                .contentShape(Circle())
        }
        .buttonStyle(TabBarAddButtonStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in onLongPress() })
        .accessibilityLabel("Add")
        .accessibilityHint("Adds a note, to-do, meeting, link or file")
        .accessibilityIdentifier("PlaceAdd")
        .accessibilityAction(named: "New Note") { onLongPress() }
        .accessibilityShowsLargeContentViewer {
            Label("Add", systemImage: "plus")
        }
        .help("Add")
    }

    /// Where the middle of the floating tab bar is, from the bottom of the screen: 52 pt on a phone with a home
    /// indicator (iPhone 16e) and on one with a home button (iPhone SE) alike, at every text size (the bar does not
    /// grow with it). `TabBarFlowTests.testPlusSitsOnTheMiddleOfTheTabBar` checks it against the bar's middle slot.
    static let centerFromBottom: CGFloat = 52
}

private struct TabBarAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
