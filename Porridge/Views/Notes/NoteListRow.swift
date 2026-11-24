import SwiftData
import SwiftUI

/// A note, meeting or link in a list, with its swipes and long press: pin, projects, share, delete. Notes are never
/// archived, only bowls are. In the Inbox the swipes file and put away: right "File" (into the suggested bowl, a full
/// swipe files) and "Bowl…", left "Delete" and "Later" (the times at once); each is also a VoiceOver action and in
/// the long press.
struct NoteListRow: View {
    let note: Note
    /// The names of the note's bowls, shown in its row where a list mixes bowls (the to-dos folder).
    var buckets: [String] = []
    /// The row is in the Inbox's list: it says how long it has been waiting, and swipes to file or put away.
    var inInbox = false
    /// The bowl suggested for an Inbox entry (`EntryMeta.suggestion`): "✦ Bowl" in the row, "File" in the swipe.
    var suggestion: NoteFolder?
    /// Moves the note to the trash, or deletes it when it already is there.
    var onRemove: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.ticksLeaveList) private var ticksLeaveList
    @Environment(ProcessingService.self) private var processing
    @State private var pickingDue = false
    @State private var choosingLater = false
    @State private var pickingLater = false
    @State private var choosingBowl = false

    var body: some View {
        // In a bowl shared with me to view only: the pin (my own) and sharing the text, nothing that changes it.
        let readOnly = !note.isDeleted && BowlSharing.shared.isReadOnly(note)
        let files = inInbox && offersLater
        ListRowLink(value: note.id) {
            NoteRow(
                note: note, stage: processing.stages[note.id], buckets: buckets, showsInboxAge: inInbox,
                suggestion: files ? suggestion : nil, onFile: fileIntoSuggestion
            )
        }
        .swipeActions(edge: .leading) {
            if files {
                // Into the suggested bowl (a full swipe files), or the bowl list.
                if let suggestion {
                    Button(action: fileIntoSuggestion) { Label(suggestion.name, systemImage: "sparkles") }
                        .tint(.brandProject)
                        .accessibilityLabel("File into \(suggestion.name)")
                }
                Button { choosingBowl = true } label: { Label("Bowl…", systemImage: "folder") }
                    .tint(.brandNavy)
            } else if note.isDeleted {
                Button { NoteStore.restore(note, in: context) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                    .tint(.brandSky)
            } else {
                if note.isTodo, !readOnly {
                    doneButton.tint(.brandTask)
                }
                Button { togglePin() } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                    .tint(.brandNavy)
            }
        }
        .swipeActions(edge: .trailing) {
            if !readOnly {
                Button(role: .destructive, action: onRemove) {
                    Label(note.isDeleted ? "Delete Now" : "Delete", systemImage: "trash")
                }
                // An Inbox entry away until later (`InboxSnooze`).
                if offersLater {
                    Button { choosingLater = true } label: { Label("Later", systemImage: "clock") }
                        .tint(.brandNavy)
                }
            }
        }
        .accessibilityActions {
            if files {
                if let suggestion {
                    Button("File into \(suggestion.name)", action: fileIntoSuggestion)
                }
                Button("Bowl…") { choosingBowl = true }
                Button("Later…") { choosingLater = true }
                Button("Delete", action: onRemove)
            }
        }
        .contextMenu {
            if note.isDeleted {
                Button { NoteStore.restore(note, in: context) } label: { Label("Recover", systemImage: "arrow.uturn.backward") }
                Button(role: .destructive, action: onRemove) { Label("Delete Now", systemImage: "trash") }
            } else if readOnly {
                Button { togglePin() } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                ShareLink(item: note.exportText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } else {
                if note.isTodo {
                    doneButton
                    Menu {
                        DueDateMenuItems(note: note) { pickingDue = true }
                    } label: {
                        Label(note.todoDue.map { "Due \(Todos.dueLabel($0))" } ?? "Due Date", systemImage: "calendar")
                    }
                }
                // A bill: paid or not, without opening it.
                if note.isDocument, note.documentInfo?.offersPaid == true {
                    PaidButton(notes: [note])
                }
                Button { togglePin() } label: { Label(note.isPinned ? "Unpin" : "Pin", systemImage: note.isPinned ? "pin.slash" : "pin") }
                if offersLater {
                    Menu {
                        LaterMenuItems(notes: [note]) { pickingLater = true }
                    } label: {
                        Label("Later", systemImage: "clock")
                    }
                    if note.isSnoozed() {
                        Button { withAnimation(.snappy) { InboxSnooze.unsnooze([note], in: context) } } label: {
                            Label("Back to Inbox Now", systemImage: "tray.and.arrow.down")
                        }
                    }
                }
                if files, let suggestion {
                    Button(action: fileIntoSuggestion) { Label("File into \(suggestion.name)", systemImage: "sparkles") }
                    Button { withAnimation(.snappy) { Inbox.dismissSuggestions(note, in: context) } } label: {
                        Label("Drop Suggestion", systemImage: "xmark")
                    }
                }
                ProjectMenu(assigned: note.projectIDs) { Undoable.toggle($0, on: note, in: context) }
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
        .sheet(isPresented: $pickingLater) { LaterPickerSheet(notes: [note]) }
        .sheet(isPresented: $choosingLater) { LaterSheet(notes: [note]) }
        .sheet(isPresented: $choosingBowl) { BowlPickerSheet(notes: [note]) }
    }

    /// "✦ Bowl", the swipe "File": into the suggested bowl, with the one undo toast.
    private func fileIntoSuggestion() {
        guard let suggestion else { return }
        withAnimation(.snappy) { Undoable.move([note], toBowl: Projects.key(suggestion), named: suggestion.name, in: context) }
    }

    /// "Later" is for entries of the Inbox.
    private var offersLater: Bool {
        note.isInInbox && !note.isDeleted && !BowlSharing.shared.isReadOnly(note)
    }

    private var doneButton: some View {
        Button {
            withAnimation(.snappy) { Todos.tick(note, leavesList: ticksLeaveList, in: context) }
        } label: {
            Label(note.isDone ? "Mark as Not Done" : "Mark as Done", systemImage: note.isDone ? "square" : "checkmark.square")
        }
    }

    private func togglePin() {
        note.isPinned.toggle()
        try? context.save()
    }
}
