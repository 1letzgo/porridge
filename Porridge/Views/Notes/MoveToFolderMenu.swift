import SwiftData
import SwiftUI

/// "Move to" submenu with all folders.
struct MoveToFolderMenu: View {
    let note: Note
    @Query(sort: \NoteFolder.name) private var folders: [NoteFolder]
    @Environment(\.modelContext) private var context

    var body: some View {
        Menu {
            Button { move(nil) } label: { Label("Notes", systemImage: current == nil ? "checkmark" : "folder") }
            ForEach(folders.tree, id: \.folder.id) { entry in
                Button { move(entry.folder.id) } label: {
                    Label(folders.path(of: entry.folder), systemImage: current == entry.folder.id ? "checkmark" : "folder")
                }
            }
        } label: {
            Label("Move to", systemImage: "folder")
        }
    }

    /// The folder of the note, or nil when it has none (or the folder is gone).
    private var current: UUID? {
        note.folderID.flatMap { id in folders.contains { $0.id == id } ? id : nil }
    }

    private func move(_ id: UUID?) {
        note.folderID = id
        try? context.save()
    }
}
