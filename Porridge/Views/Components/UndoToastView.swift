import SwiftUI

/// The undo toast at the bottom of the screen (iOS): what just happened and "Undo". It goes by itself after a few
/// seconds (`UndoToast.duration`); a swipe down closes it at once.
struct UndoToastView: View {
    var toast = UndoToast.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let offer = toast.current {
                HStack(spacing: 12) {
                    Image(systemName: offer.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(offer.message)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        withAnimation(.snappy) { toast.undo() }
                    } label: {
                        Text("Undo")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.brandSkyText)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .frame(minHeight: 52)
                .frame(maxWidth: 520)
                .background(colorScheme == .dark ? Color.appSecondaryBackground : Color.appBackground, in: Capsule())
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .padding(.horizontal, 22)
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
