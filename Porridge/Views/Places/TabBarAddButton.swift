import SwiftUI

/// "+" in the middle of the phone's tab bar (Today · Inbox · + · Bowls · Search, `PlaceTabBar`): a big round raised
/// button, taller than the bar and rising above its top edge, in a deeper sky with a navy "+". A tap opens the Add
/// sheet for where one is (in a bowl "Into: <bowl>", else the Inbox); a long press makes a note at once. Its size does
/// not follow the text size, like the tab bar's symbols; with the largest text sizes a long press shows it in the
/// large content viewer.
struct TabBarAddButton: View {
    let diameter: CGFloat
    var onTap: () -> Void
    var onLongPress: () -> Void

    /// The circle: about 64 pt, 58 pt on screens narrower than 390 pt (the iPhone SE), clearly the bar's middle. The
    /// bar gives it a slot of its own (`TabBarLayout.middleWidth`), so the Inbox's badge and selection capsule end
    /// before it.
    static func diameter(screenWidth: CGFloat) -> CGFloat {
        screenWidth < 390 ? 58 : 64
    }

    /// The brand sky, deeper toward the bottom: stronger than the sky of the pills, the navy "+" stays readable.
    static let fill = LinearGradient(
        colors: [Color.brandSky, Color(red: 0.05, green: 0.6, blue: 0.86)], startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "plus")
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundStyle(Color.brandSky.onFill)
                .frame(width: diameter, height: diameter)
                .background(Self.fill, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: Color(red: 0.05, green: 0.45, blue: 0.7).opacity(0.35), radius: 10, y: 5)
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
}

private struct TabBarAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}
