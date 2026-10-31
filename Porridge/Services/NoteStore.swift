import Foundation
import SwiftData

/// Moving notes to "Recently Deleted", restoring and deleting them.
enum NoteStore {
    /// Days a note stays in "Recently Deleted".
    static let trashDays = 30

    static func trash(_ note: Note, in context: ModelContext) {
        // A new note that was never saved just disappears.
        guard note.modelContext != nil else { return }
        note.deletedAt = Date()
        note.isPinned = false
        try? context.save()
    }

    static func restore(_ note: Note, in context: ModelContext) {
        note.deletedAt = nil
        if let folderID = note.folderID {
            let exists = ((try? context.fetchCount(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == folderID }))) ?? 0) > 0
            if !exists { note.folderID = nil }
        }
        try? context.save()
    }

    static func deletePermanently(_ note: Note, in context: ModelContext) {
        note.audioFileNames.forEach(AudioStore.delete)
        AudioStore.delete(note.pendingAudioFileName)
        ActionItems.remove(of: note.id, in: context)
        context.delete(note)
        try? context.save()
    }

    /// Deletes notes that were in the trash longer than `trashDays`.
    static func purgeExpired(in context: ModelContext) {
        guard let limit = Calendar.current.date(byAdding: .day, value: -trashDays, to: Date()) else { return }
        let old = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt != nil }))) ?? []
        for note in old where (note.deletedAt ?? .distantFuture) < limit {
            deletePermanently(note, in: context)
        }
    }

}
