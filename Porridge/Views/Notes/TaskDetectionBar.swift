import SwiftData
import SwiftUI

/// A small bar under the editor of a plain note: "2 possible to-dos". It looks at the text a moment after typing
/// stopped (`TaskDetection`); a tap offers to make the note a to-do with those lines as subtasks, or to turn the lines
/// into checklist lines. Never on links, saved files or meetings.
struct TaskDetectionBar: View {
    let note: Note
    /// Called before the note's text is changed from here, so typing still on its way is handed over first.
    var beforeChange: () -> Void = {}

    @Environment(\.modelContext) private var context
    @State private var tasks: [DetectedTask] = []
    @State private var asking = false

    var body: some View {
        Group {
            if !tasks.isEmpty {
                HStack(spacing: 8) {
                    Button { asking = true } label: {
                        Label(TaskDetection.label(count: tasks.count), systemImage: "checklist")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.brandTaskText)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Offers to turn these lines into to-dos")
                    .accessibilityIdentifier("TaskDetectionBar")
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.snappy) {
                            TaskDetection.dismiss(tasks, for: note)
                            tasks = []
                        }
                    } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            .contentShape(Rectangle().inset(by: -8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.brandTask.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity)
                .confirmationDialog(TaskDetection.label(count: tasks.count), isPresented: $asking, titleVisibility: .visible) {
                    if note.isTodo {
                        Button(tasks.count == 1 ? "Add as Subtask" : "Add as \(tasks.count) Subtasks") { addAsSubtasks() }
                    } else {
                        if note.canBeTodo {
                            Button(tasks.count == 1 ? "Make To-do with 1 Subtask" : "Make To-do with \(tasks.count) Subtasks") { makeTodo() }
                        }
                        Button("Add as Subtasks") { addAsSubtasks() }
                    }
                    Button("Not To-dos", role: .destructive) {
                        withAnimation(.snappy) {
                            TaskDetection.dismiss(tasks, for: note)
                            tasks = []
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(tasks.map { "• " + $0.text }.joined(separator: "\n"))
                }
            }
        }
        // Cheap, and only once typing rests.
        .task(id: note.text) {
            try? await Task.sleep(for: TaskDetection.debounce)
            guard !Task.isCancelled else { return }
            let found = TaskDetection.pending(for: note)
            withAnimation(.snappy) { tasks = found }
        }
    }

    private func makeTodo() {
        beforeChange()
        let current = TaskDetection.pending(for: note)
        withAnimation(.snappy) {
            TaskDetection.makeTodo(note, with: current, in: context)
            tasks = []
        }
    }

    private func addAsSubtasks() {
        beforeChange()
        let current = TaskDetection.pending(for: note)
        withAnimation(.snappy) {
            TaskDetection.addAsSubtasks(note, current, in: context)
            tasks = []
        }
    }
}
