import SwiftData
import SwiftUI

/// One task as a page of its own, shown like a note in the detail column (pushed with a back button on the
/// iPhone): title, done, who is responsible, where it comes from, and its own text (the same editor as notes).
struct TaskDetailView: View {
    @Bindable var item: ActionItem
    /// The note the task comes from, if it still exists.
    let note: Note?
    /// Opens the note of the task.
    var onOpenNote: (UUID) -> Void = { _ in }
    /// Called after the task was deleted, so the list can close it.
    var onClose: () -> Void = {}

    @Environment(\.modelContext) private var context
    @State private var editor = NoteEditorController()
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        Button { toggleDone() } label: {
                            Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                                .font(.title2)
                                .foregroundStyle(Color.brandTask)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.isDone ? "Mark as Open" : "Mark as Done")
                        TextField("Task", text: $item.text, axis: .vertical)
                            .font(.title3.weight(.semibold))
                            .textFieldStyle(.plain)
                            .strikethrough(item.isDone, color: .secondary)
                            .focused($titleFocused)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "person")
                            .foregroundStyle(Color.brandTask)
                            .frame(width: 30)
                        TextField("Responsible", text: Binding(
                            get: { item.owner ?? "" },
                            set: { item.owner = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                        ))
                        .textFieldStyle(.plain)
                    }
                    .font(.subheadline)

                    ScrollView(.horizontal, showsIndicators: false) {
                        ProjectPills(assigned: item.projectIDs, inherited: note?.projectIDs ?? []) { project in
                            Projects.toggle(project, on: item, in: context)
                        }
                    }

                    if let note {
                        Button { onOpenNote(note.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "note.text")
                                    .frame(width: 30)
                                Text(note.displayTitle).lineLimit(1)
                                Text("·")
                                Text(note.createdAt.formatted(.dateTime.day().month(.abbreviated)))
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open Note")
                    }

                    Rectangle().fill(Look.hairline).frame(height: 0.5)

                    NoteBodyEditor(text: $item.details, controller: editor, placeholder: "Notes")
                        .frame(minHeight: 280)
                }
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
        }
        .background(Color.appBackground)
        .navigationTitle("")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Delete Task", systemImage: "trash")
                }
                .accessibilityLabel("Delete Task")
            }
        }
        .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                editor.blur()
                ActionItems.delete(item, in: context)
                onClose()
            }
        }
        .onAppear { if item.text.isEmpty { titleFocused = true } }
        .onDisappear {
            editor.blur()
            try? context.save()
        }
        .onChange(of: item.text) { item.updatedAt = Date() }
        .onChange(of: item.details) { item.updatedAt = Date() }
        .onChange(of: item.owner) { item.updatedAt = Date() }
    }

    private func toggleDone() {
        withAnimation(.snappy) { ActionItems.setDone(item, !item.isDone, note: note, in: context) }
    }
}
