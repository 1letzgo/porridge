import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Turns what was shared into the app (`ShareInbox`), or dropped onto it, into what waits in the inbox: links,
/// notes, recordings, and an image or a file for each image, PDF or document (`Note.isImage`, `Note.isFile`).
@MainActor
enum ShareImport {
    /// Takes what the share sheet left behind and saves it as notes.
    static func importInbox(context: ModelContext, processing: ProcessingService) {
        let entries = ShareInbox.pending()
        guard !entries.isEmpty else { return }
        let folders = Set(((try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []).map(\.id.uuidString))
        var known = LinkImport.knownAddresses(in: context)
        var saved: [ShareInbox.Entry] = []
        for entry in entries {
            // A bucket deleted since the share: the note waits in the inbox instead.
            let project = entry.projectID.flatMap { folders.contains($0) ? $0 : nil }
            let notes = save(entry, known: &known, context: context, processing: processing)
            for note in notes {
                if let project, !note.projectIDs.contains(project) {
                    note.projectIDs.append(project)
                    note.filedAt = note.filedAt ?? Date()
                }
            }
            saved.append(entry)
        }
        // Not saved: everything stays in the inbox for the next time (a link saved twice only moves to the top).
        do {
            try context.save()
            saved.forEach(ShareInbox.finish)
        } catch {
            print("[share] not saved, kept in the inbox: \(error)")
        }
    }

    /// What one share becomes: a link or a note with its text, a file per image, PDF or document, and a recording
    /// per audio file. Text shared along with files describes the first of them.
    private static func save(
        _ entry: ShareInbox.Entry, known: inout [String: Note], context: ModelContext, processing: ProcessingService
    ) -> [Note] {
        var notes: [Note] = []
        var attachments: [Attachment] = []
        for file in entry.files {
            guard let source = ShareInbox.url(of: file, in: entry), FileManager.default.fileExists(atPath: source.path) else { continue }
            if file.kind == .audio {
                if let note = try? NoteStore.importAudio(from: source, title: file.name, source: .share, context: context, processing: processing) {
                    notes.append(note)
                }
            } else if let attachment = try? AttachmentStore.add(source, name: file.name) {
                attachments.append(attachment)
            }
        }
        let text = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !attachments.isEmpty {
            for (index, attachment) in attachments.enumerated() {
                let note = Note()
                note.source = .share
                if index == 0 { note.text = text }
                // A title shared along names a single file; several keep their own names.
                if attachments.count == 1 { note.title = entry.title ?? "" }
                note.createdAt = entry.date
                note.updatedAt = entry.date
                context.insert(note)
                attach([attachment], to: note, processing: processing)
                notes.append(note)
            }
        } else if entry.url == nil, !text.isEmpty {
            let note = Note()
            note.source = .share
            note.text = text
            note.title = entry.title ?? ""
            note.createdAt = entry.date
            note.updatedAt = entry.date
            context.insert(note)
            notes.append(note)
        } else if let url = entry.url {
            let note = LinkImport.save(url, title: entry.title, date: entry.date, known: &known, context: context, processing: processing)
            known[LinkImport.normalized(url)] = note
            notes.append(note)
        }
        return notes
    }

    /// Files picked or dropped in the app: audio becomes a recording, everything else a file each.
    /// Returns the one to open.
    @discardableResult
    static func add(files: [URL], project: String?, context: ModelContext, processing: ProcessingService) -> Note? {
        var attachments: [Attachment] = []
        var first: Note?
        for url in files {
            let type = UTType(filenameExtension: url.pathExtension)
            if let type, type.conforms(to: .audio) || type.conforms(to: .movie) {
                let note = try? NoteStore.importAudio(from: url, context: context, processing: processing)
                if let project, let note { note.projectIDs = [project] }
                first = first ?? note
            } else if let attachment = try? AttachmentStore.add(url, name: url.lastPathComponent) {
                attachments.append(attachment)
            }
        }
        for attachment in attachments {
            let note = Note()
            note.source = .share
            if let project { note.projectIDs = [project] }
            context.insert(note)
            attach([attachment], to: note, processing: processing)
            first = first ?? note
        }
        try? context.save()
        return first
    }

    /// Puts the attachments on the note and has their text read (`ProcessingService.processAttachments`).
    static func attach(_ attachments: [Attachment], to note: Note, processing: ProcessingService) {
        guard !attachments.isEmpty else { return }
        note.attachments += attachments
        if note.title.isEmpty, let first = attachments.first {
            note.title = (first.name as NSString).deletingPathExtension
        }
        // Read again with the new file; until then the note is being worked on.
        note.pageText = nil
        note.statusRaw = ProcessingStatus.recorded.rawValue
        processing.enqueue(.attachment(note.id))
    }
}
