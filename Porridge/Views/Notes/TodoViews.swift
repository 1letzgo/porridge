import SwiftData
import SwiftUI

/// The box of a to-do: in a list row it takes the place of the kind's icon (as high as the row's two lines), in
/// its page it stands before the title. Green squares are tasks (`DESIGN.md`); circles are the subtasks in the text.
struct TodoCheckbox: View {
    let isDone: Bool
    /// The row's icon size; the page uses a smaller one.
    var size: CGFloat = 44
    var isPinned = false
    let toggle: () -> Void

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = min(size * scale, size * 1.27)
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: side / 4, style: .continuous)
                    .fill(isDone ? Color.brandTask : Color.brandTask.opacity(0.10))
                RoundedRectangle(cornerRadius: side / 4, style: .continuous)
                    .strokeBorder(Color.brandTask.opacity(isDone ? 1 : 0.75), lineWidth: 1.5)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: side * 0.42, weight: .bold))
                        // Symbols on a full fill of green are navy.
                        .foregroundStyle(Color.brandOnFill)
                }
            }
            .frame(width: side, height: side)
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.brandOnNavy)
                        .frame(width: 18, height: 18)
                        .background(Color.brandNavy, in: Circle())
                        .overlay(Circle().strokeBorder(Color.appBackground, lineWidth: 1.5))
                        .offset(x: 6, y: -6)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("To-do")
        .accessibilityValue(isDone ? "Done" : "Not Done")
        .accessibilityAddTraits(.isToggle)
        .sensoryFeedback(.success, trigger: isDone) { _, done in done }
    }
}

/// "2/5" with a checklist symbol: how many subtasks of a to-do are ticked.
struct TodoProgressLabel: View {
    let progress: Todos.Progress

    var body: some View {
        if progress.total > 0 {
            HStack(spacing: 3) {
                Image(systemName: "checklist")
                Text(progress.label).monospacedDigit()
            }
                .foregroundStyle(progress.isComplete ? Color.brandTaskText : .secondary)
                .fixedSize()
                .accessibilityLabel("\(progress.done) of \(progress.total) subtasks done")
        }
    }
}

/// The way from a to-do back to the note whose summary it was taken from.
struct TodoSourcePill: View {
    let source: Note

    @Environment(\.openNote) private var openNote

    var body: some View {
        Button { openNote(source.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: source.isRecording ? "waveform" : "text.alignleft")
                Text(source.displayTitle).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.brandNavy)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.brandNavy.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("From \(source.displayTitle)")
    }
}
