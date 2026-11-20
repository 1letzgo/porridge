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

    /// An audio or video file from outside becomes a meeting that is transcribed. `save: false` leaves saving to
    /// the caller (the share import saves once per share, then takes it out of the inbox).
    @discardableResult
    @MainActor
    static func importAudio(
        from url: URL, title: String? = nil, source: NoteSource = .audioImport, save: Bool = true,
        context: ModelContext, processing: ProcessingService
    ) throws -> Note {
        let fileName = try AudioStore.importFile(from: url)
        let note = Note()
        note.title = title.map { ($0 as NSString).deletingPathExtension } ?? url.deletingPathExtension().lastPathComponent
        note.titleIsCustom = true
        note.statusRaw = ProcessingStatus.recorded.rawValue
        note.audioFileName = fileName
        note.inputName = "Import"
        note.source = source
        if let info = AudioStore.audioInfo(for: fileName) {
            note.duration = info.duration
            note.channelCount = info.channels
        }
        context.insert(note)
        if save { try? context.save() }
        // Imported here: this device summarizes it once it is transcribed (`AutoSummary`).
        AutoSummary.markOrigin(note.id)
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
        note.storedFileNames.forEach(AudioStore.delete)
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
