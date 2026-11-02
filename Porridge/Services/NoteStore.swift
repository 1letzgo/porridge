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
        note.updatedAt = Date()
        try? context.save()
    }

    /// An audio or video file from outside becomes a meeting that is transcribed.
    @discardableResult
    @MainActor
    static func importAudio(from url: URL, context: ModelContext, processing: ProcessingService) throws -> Note {
        let fileName = try AudioStore.importFile(from: url)
        let note = Note()
        note.title = url.deletingPathExtension().lastPathComponent
        note.titleIsCustom = true
        note.statusRaw = ProcessingStatus.recorded.rawValue
        note.audioFileName = fileName
        note.inputName = "Import"
        if let info = AudioStore.audioInfo(for: fileName) {
            note.duration = info.duration
            note.channelCount = info.channels
        }
        context.insert(note)
        try? context.save()
        processing.enqueue(.transcript(note.id))
        return note
    }

    static func restore(_ note: Note, in context: ModelContext) {
        note.deletedAt = nil
        note.updatedAt = Date()
        if let folderID = note.folderID {
            let exists = ((try? context.fetchCount(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == folderID }))) ?? 0) > 0
            if !exists { note.folderID = nil }
        }
        try? context.save()
    }

    static func deletePermanently(_ note: Note, in context: ModelContext) {
        note.audioFileNames.forEach(AudioStore.delete)
        AudioStore.delete(note.pendingAudioFileName)
        AudioStore.delete(note.audioFileName)
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
