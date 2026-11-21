import SwiftData
import SwiftUI

/// A note, meeting or link in a list, with its swipes and long press: pin, projects, share, delete. Notes are never
/// archived, only bowls are.
struct NoteListRow: View {
    let note: Note
    /// The names of the note's bowls, shown in its row where a list mixes bowls (the to-dos folder).
    var buckets: [String] = []
    /// Moves the note to the trash, or deletes it when it already is there.
    var onRemove: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @State private var pickingDue = false

    var body: some View {
        ListRowLink(value: note.id) {
            NoteRow(note: note, stage: processing.stages[note.id], buckets: buckets)
        }
        .swipeActions(edge: .leading) {
            if note.isDeleted {
                Button { NoteStore.restore(note, in: context) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                    .tint(.brandSky)
            } else {
                if note.isTodo {
                    doneButton.tint(.brandTask)
                }
                Button { togglePin() } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                    .tint(.brandNavy)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onRemove) {
                Label(note.isDeleted ? "Delete Now" : "Delete", systemImage: "trash")
            }
        }
        .contextMenu {
            if note.isDeleted {
                Button { NoteStore.restore(note, in: context) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                Button(role: .destructive, action: onRemove) { Label("Delete Now", systemImage: "trash") }
            } else {
                if note.isTodo {
                    doneButton
                    Menu {
                        DueDateMenuItems(note: note) { pickingDue = true }
                    } label: {
                        Label(note.todoDue.map { "Due \(Todos.dueLabel($0))" } ?? "Due Date", systemImage: "calendar")
                    }
                }
                Button { togglePin() } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                ProjectMenu(assigned: note.projectIDs) { Projects.toggle($0, on: note, in: context) }
                if note.canBeTodo {
                    Button { withAnimation(.snappy) { Todos.setTodo(!note.isTodo, note, in: context) } } label: {
                        Label(note.isTodo ? "Convert to Note" : "Convert to To-do", systemImage: note.isTodo ? "text.alignleft" : "checklist")
                    }
                }
                ShareLink(item: note.exportText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive, action: onRemove) { Label("Delete", systemImage: "trash") }
            }
        }
        .sheet(isPresented: $pickingDue) { DueDatePickerSheet(note: note) }
    }

    private var doneButton: some View {
        Button {
            withAnimation(.snappy) { Todos.setDone(!note.isDone, note, in: context) }
        } label: {
            Label(note.isDone ? "Mark as Not Done" : "Mark as Done", systemImage: note.isDone ? "square" : "checkmark.square")
        }
    }

    private func togglePin() {
        note.isPinned.toggle()
        try? context.save()
    }
}
