import Foundation
import SwiftData

/// Images inserted into a note's text (`NoteEditorController.attachImage`): an attachment of the note like any
/// other file (synced through iCloud Drive, its text read for the search); the text shows it where it was
/// inserted (`NoteImageRef`). Links and shared files keep what they came with.
@MainActor
enum NoteImageAttaching {
    static func attach(_ url: URL, to note: Note, context: ModelContext, processing: ProcessingService) -> Attachment? {
        guard !note.isSaved, !note.isDeleted,
              AttachmentStore.kind(ofExtension: url.pathExtension.lowercased()) == .image,
              let attachment = try? AttachmentStore.add(url, name: url.lastPathComponent) else { return nil }
        note.attachments += [attachment]
        note.updatedAt = Date()
        if note.modelContext == nil { context.insert(note) }
        try? context.save()
        processing.enqueue(.attachment(note.id))
        return attachment
    }
}
