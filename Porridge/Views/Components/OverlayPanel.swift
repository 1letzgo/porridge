import SwiftUI

/// A card over the current view: a small bar with symbol, title and close, then the content.
struct OverlayPanel<Content: View, Actions: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    var onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint.readable)
                Text(title)
                    .font(.headline)
                Spacer()
                actions
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Close")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(tint.readable)
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            Rectangle().fill(Look.hairline).frame(height: 0.5)
            content
        }
        .background(Color.appBackground)
    }
}

extension OverlayPanel where Actions == EmptyView {
    init(title: LocalizedStringKey, systemImage: String, tint: Color, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, tint: tint, onClose: onClose, content: content, actions: { EmptyView() })
    }
}
