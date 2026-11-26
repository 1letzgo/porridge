import SwiftUI

/// The one undo toast at the bottom of the screen (iOS): a navy capsule with what just happened and "Undo", the same
/// for deleting, moving, bundling, splitting, enhancing and the chat's changes. It goes by itself after a few seconds
/// (`UndoToast.duration`); a swipe down closes it at once.
struct UndoToastView: View {
    var toast = UndoToast.shared
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            if let offer = toast.current {
                let large = typeSize.isAccessibilitySize
                // With the largest text sizes "Undo" goes under the message, which keeps the whole width.
                (large ? AnyLayout(VStackLayout(alignment: .trailing, spacing: 2)) : AnyLayout(HStackLayout(spacing: 10))) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: offer.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .accessibilityHidden(true)
                        // The message wraps instead of being cut ("2 chan…"); "Undo" keeps its one line.
                        Text(offer.message)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .lineLimit(large ? 8 : 3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, large ? 10 : 0)
                    Button {
                        withAnimation(.snappy) { toast.undo() }
                    } label: {
                        Text("Undo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.white.opacity(0.16), in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .layoutPriority(1)
                }
                .padding(.leading, 16)
                .padding(.trailing, 8)
                .frame(minHeight: 50)
                .frame(maxWidth: 520)
                .padding(.vertical, large ? 4 : 0)
                // A capsule on one line; with more lines its ends stay round instead of bulging.
                .background(Color.toastFill, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 15, y: 10)
                .padding(.horizontal, 16)
                .id(offer.id)
                .transition(Motion.slide(.move(edge: .bottom).combined(with: .opacity)))
                .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                    if value.translation.height > 20 { withAnimation(.snappy) { toast.dismiss() } }
                })
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "Undo") { toast.undo() }
                .onAppear { UIAccessibility.post(notification: .announcement, argument: offer.message) }
            }
        }
        .animation(.snappy, value: toast.current)
    }
}

/// The hint of the day above the Inbox's list: one quiet line, opened with a tap, closed with the cross.
struct DailyHintBanner: View {
    let hint: DailyHint
    var onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                DailyHints.shared.open()
                onOpen()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: hint.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandSkyText)
                        .accessibilityHidden(true)
                    Text(hint.message)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.snappy) { DailyHints.shared.close() }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Hint")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.brandSky.opacity(0.12), in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

/// The selection bar (Move, Done, More) stands at the bottom: the undo toast keeps above it instead of lying over it
/// (an iPad of regular width, where the toast otherwise sits close to the bottom edge).
struct SelectionBarShownKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Where the selection bar stands (global coordinates): on an iPad of regular width the undo toast centers over it, in
/// the list column, instead of in the middle of the window across the list and the entry.
struct SelectionBarFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = nextValue() ?? value }
}
