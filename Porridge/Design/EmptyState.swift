import SwiftUI

/// What an empty view says (iPhone, iPad and the Mac's SwiftUI windows): the bowl from the app icon, a title, a line of
/// explanation and, where there is one, a button. The words wrap at every text size. Placed by `EmptyStateView`; the
/// chat's start takes it as it is, in its own scroll view.
struct EmptyStateLabel<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image("Bowl")
                .resizable()
                .scaledToFit()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, 6)
                .accessibilityHidden(true)
            if !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            if !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
                .padding(.top, 8)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }
}

/// An empty view: the message in the middle of the page, across and up and down, laid over an empty list or in its
/// place, never as a row of it. Up and down the middle is always that of the room between the page's head (the bar
/// with title and pills) and the tab bar (its room is the safe area's: `keepsTabBarRoom`), whether bars stand between
/// head and list or not (a switch, a bowl's chips, the search field, the week's head): their height comes as
/// `emptyStateLift` (`emptyStateBar`, `emptyStateArea`) and the message moves up by it, so it stands at the same place on
/// every page. It never goes up under such a bar: when the words need more than the room (the largest text sizes) it
/// starts below it and scrolls. With a refresh action (`refreshable`, Today) it can always be pulled. A sheet centers
/// in its own room (its root sets the lift to 0).
struct EmptyStateView<Actions: View>: View {
    let title: String
    let message: String
    /// Kept for call sites; the bowl from the app icon is shown instead.
    var systemImage = "tray"
    @ViewBuilder var actions: Actions

    @Environment(\.refresh) private var refresh
    @Environment(\.emptyStateLift) private var lift

    init(title: String, message: String, systemImage: String = "tray", @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { room in
            ScrollView {
                // The lift as room below the message: its middle moves up by half of it, to the middle of the room
                // from the head on; a message too tall for that starts at the top of its own room.
                EmptyStateLabel(title: title, message: message) { actions }
                    .padding(.bottom, lift)
                    .frame(maxWidth: .infinity, minHeight: room.size.height)
            }
            .scrollBounceBehavior(refresh == nil ? .basedOnSize : .always)
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(title: String, message: String, systemImage: String = "tray") {
        self.init(title: title, message: message, systemImage: systemImage) { EmptyView() }
    }
}

extension EnvironmentValues {
    /// The height of the bars between a page's head and its content (`emptyStateBar`), for `EmptyStateView`.
    @Entry var emptyStateLift: CGFloat = 0
}

/// The bars of a page below its head, added up.
private struct EmptyStateLiftKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

/// Reads the bars of the page inside it and hands their height to its empty views.
private struct EmptyStateArea: ViewModifier {
    @State private var lift: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.emptyStateLift, lift)
            .onPreferenceChange(EmptyStateLiftKey.self) { lift = $0 }
            // Not counted again by a page around it.
            .transformPreference(EmptyStateLiftKey.self) { $0 = 0 }
    }
}

extension View {
    /// A bar between a page's head and its content (with its own spacing): an empty view below moves up by its height
    /// (`EmptyStateView`).
    func emptyStateBar() -> some View {
        background(GeometryReader { Color.clear.preference(key: EmptyStateLiftKey.self, value: $0.size.height) })
    }

    /// The content of a page below its head: the bars in it lift its empty views.
    func emptyStateArea() -> some View {
        modifier(EmptyStateArea())
    }

    /// A sheet's root: its empty views center in the sheet, whatever page opened it.
    func emptyStateSheet() -> some View {
        environment(\.emptyStateLift, 0)
    }
}
