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

/// An empty view: the message in the middle of the room it is given, across and up and down (between the page's head
/// or switch and the tab bar, whose room is the safe area's: `keepsTabBarRoom`). Laid over an empty list or in its
/// place, never as a row of it. When the words need more than the room (the largest text sizes) it scrolls; with a
/// refresh action (`refreshable`, Today) it can always be pulled.
struct EmptyStateView<Actions: View>: View {
    let title: String
    let message: String
    /// Kept for call sites; the bowl from the app icon is shown instead.
    var systemImage = "tray"
    @ViewBuilder var actions: Actions

    @Environment(\.refresh) private var refresh

    init(title: String, message: String, systemImage: String = "tray", @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        GeometryReader { room in
            ScrollView {
                EmptyStateLabel(title: title, message: message) { actions }
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
