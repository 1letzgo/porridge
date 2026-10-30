import SwiftData
import SwiftUI

/// One task as a page of its own: title, done, who is responsible, where it comes from, and its own text
/// (the same editor as notes).
struct TaskDetailView: View {
    @Bindable var item: ActionItem
    /// The note the task comes from, if it still exists.
    let note: Note?
    /// Opens the note of the task.
    var onOpenNote: (UUID) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editor = NoteEditorController()
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
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
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(Color.appBackground)
            .brandNavigationTitle("Task")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        editor.blur()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .confirmationDialog("Delete this task?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    ActionItems.delete(item, in: context)
                    dismiss()
                }
            }
        }
        .onAppear { if item.text.isEmpty { titleFocused = true } }
        .onChange(of: item.text) { item.updatedAt = Date() }
        .onChange(of: item.details) { item.updatedAt = Date() }
        .onChange(of: item.owner) { item.updatedAt = Date() }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }

    private func toggleDone() {
        withAnimation(.snappy) { ActionItems.setDone(item, !item.isDone, note: note, in: context) }
    }
}
