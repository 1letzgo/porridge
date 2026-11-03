import SwiftData
import SwiftUI

/// A note, meeting or link in a list, with its swipes and long press: pin, projects, archive, share, delete.
struct NoteListRow: View {
    let note: Note
    /// Moves the note to the trash, or deletes it when it already is there.
    var onRemove: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing

    var body: some View {
        ListRowLink(value: note.id) {
            NoteRow(note: note, stage: processing.stages[note.id])
        }
        .swipeActions(edge: .leading) {
            if note.isDeleted {
                Button { NoteStore.restore(note, in: context) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                    .tint(.brandSky)
            } else if !note.isArchived {
                Button { togglePin() } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                    .tint(.orange)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onRemove) {
                Label(note.isDeleted ? "Delete Now" : "Delete", systemImage: "trash")
            }
            if !note.isDeleted {
                archiveButton.tint(.brandNavy)
            }
        }
        .contextMenu {
            if note.isDeleted {
                Button { NoteStore.restore(note, in: context) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                Button(role: .destructive, action: onRemove) { Label("Delete Now", systemImage: "trash") }
            } else {
                if !note.isArchived {
                    Button { togglePin() } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                }
                ProjectMenu(assigned: note.projectIDs) { Projects.toggle($0, on: note, in: context) }
                archiveButton
                ShareLink(item: note.exportText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive, action: onRemove) { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private var archiveButton: some View {
        Button {
            withAnimation(.snappy) { Archive.set(!note.isArchived, note, in: context) }
        } label: {
            Label(note.isArchived ? "Unarchive" : "Archive", systemImage: note.isArchived ? "tray.and.arrow.up" : "archivebox")
        }
    }

    private func togglePin() {
        note.isPinned.toggle()
        try? context.save()
    }
}
