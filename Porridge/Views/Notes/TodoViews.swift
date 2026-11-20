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

// MARK: - Due day

extension Todos {
    /// The color of a due day: red when an open to-do is late, green for today, otherwise quiet. A done to-do
    /// is never marked.
    static func dueTint(_ note: Note) -> Color {
        guard let due = note.todoDue, !note.isDone else { return .secondary }
        switch dueStatus(due) {
        case .overdue?: return .brandDangerText
        case .today?: return .brandTaskText
        default: return .secondary
        }
    }
}

/// The due day in a list row: a calendar symbol and "Today", "Fri", "12 Dec".
struct TodoDueLabel: View {
    let note: Note

    var body: some View {
        if let due = note.todoDue {
            let label = Todos.dueLabel(due)
            HStack(spacing: 3) {
                Image(systemName: note.isOverdue ? "calendar.badge.exclamationmark" : "calendar")
                Text(label)
            }
            .foregroundStyle(Todos.dueTint(note))
            .fontWeight(note.isOverdue || Todos.dueStatus(due) == .today && !note.isDone ? .semibold : nil)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(note.isOverdue ? "Overdue, due \(label)" : "Due \(label)")
        }
    }
}

/// The choices for a due day, as buttons of a menu: Today, Tomorrow, Next Week, Pick Date…, and Clear.
struct DueDateMenuItems: View {
    let note: Note
    /// Opens the date picker.
    let pickDate: () -> Void

    @Environment(\.modelContext) private var context

    var body: some View {
        ForEach(Todos.DueChoice.allCases, id: \.self) { choice in
            Button {
                withAnimation(.snappy) { Todos.setDue(Todos.dueKey(for: choice), note, in: context) }
            } label: {
                Label(choice.title, systemImage: choice.systemImage)
            }
        }
        Button(action: pickDate) { Label("Pick Date…", systemImage: "calendar") }
        if note.todoDue != nil {
            Divider()
            Button(role: .destructive) {
                withAnimation(.snappy) { Todos.setDue(nil, note, in: context) }
            } label: {
                Label("Clear Due Date", systemImage: "calendar.badge.minus")
            }
        }
    }
}

/// The due day on a to-do's page, in the row of its buckets and tags: a menu with the choices.
struct DueDateChip: View {
    let note: Note
    @Binding var isPicking: Bool

    var body: some View {
        Menu {
            DueDateMenuItems(note: note) { isPicking = true }
        } label: {
            HStack(spacing: 6) {
                if let due = note.todoDue {
                    Image(systemName: note.isOverdue ? "calendar.badge.exclamationmark" : "calendar")
                    Text(Todos.dueLabel(due))
                } else {
                    Image(systemName: "plus")
                    Text("Due Date")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(note.todoDue == nil ? Color.brandNavy : note.isOverdue ? Color.brandDangerText : Color.brandTaskText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .chunkyPill(fill: note.todoDue == nil ? .gray : note.isOverdue ? .red : .brandTask)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(note.todoDue.map { "Due \(Todos.dueLabel($0))" } ?? "Add Due Date")
    }
}

/// The system's calendar to pick a due day, in a sheet.
struct DueDatePickerSheet: View {
    let note: Note

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()

    var body: some View {
        NavigationStack {
            DatePicker("Due Date", selection: $day, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(.brandTask)
                .padding()
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Due Date")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Todos.setDue(Todos.dueKey(day), note, in: context)
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onAppear { day = note.todoDue.flatMap { Todos.dueDate($0) } ?? Date() }
    }
}
