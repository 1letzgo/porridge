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
        for entry in entries {
            // A bowl deleted since the share: the note waits in the inbox instead.
            let project = entry.projectID.flatMap { folders.contains($0) ? $0 : nil }
            let notes = save(entry, known: &known, context: context, processing: processing)
            for note in notes {
                if let project, note.projectIDs != [project] {
                    note.projectIDs = Projects.assigned(project)
                    note.filedAt = note.filedAt ?? Date()
                }
            }
            // Each share leaves the inbox once its notes are saved, so nothing comes in twice. Not saved: it and
            // the ones after it stay in the inbox for the next time (a link saved twice only moves to the top).
            do {
                try context.save()
                ShareInbox.finish(entry)
            } catch {
                print("[share] not saved, kept in the inbox: \(error)")
                return
            }
        }
    }

    /// What one share becomes: a link or a note with its text, a file per image, PDF or document, and a recording
    /// per audio file. Text shared along with files describes the first of them.
    private static func save(
        _ entry: ShareInbox.Entry, known: inout [String: Note], context: ModelContext, processing: ProcessingService
    ) -> [Note] {
        var notes: [Note] = []
        var attachments: [Attachment] = []
        var mails = 0
        for file in entry.files {
            guard let source = ShareInbox.url(of: file, in: entry), FileManager.default.fileExists(atPath: source.path) else { continue }
            // A mail (shared from a mail app as .eml) is an entry of its own: its text, its files attached.
            if MailNote.isMail(name: file.name) || MailNote.isMail(source),
               let note = MailImport.save(source, date: entry.date, context: context, processing: processing) {
                notes.append(note)
                mails += 1
                continue
            }
            if file.kind == .audio {
                if let note = try? NoteStore.importAudio(from: source, title: file.name, source: .share, save: false, context: context, processing: processing) {
                    notes.append(note)
                }
            } else if let attachment = try? AttachmentStore.add(source, name: file.name) {
                attachments.append(attachment)
            }
        }
        let text = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // What a mail app shares along with the mail (its subject, a link to it) is in the mail's entry already.
        if mails > 0, attachments.isEmpty { return notes }
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
            AutoSummary.markOrigin(note.id)
            notes.append(note)
        } else if let url = entry.url {
            // Text shared along with the address (audio and a link, say) is kept on the link unless it only repeats it.
            let extra = text.isEmpty || text == entry.title || text == url ? nil : text
            let note = LinkImport.save(url, title: entry.title, text: extra, date: entry.date, known: &known, context: context, processing: processing)
            known[LinkImport.normalized(url)] = note
            notes.append(note)
        }
        return notes
    }

    /// Files picked or dropped in the app: audio becomes a recording, a mail (.eml) an entry with its text and its
    /// files, everything else a file each.
    /// Returns the one to open.
    @discardableResult
    static func add(files: [URL], project: String?, context: ModelContext, processing: ProcessingService) -> Note? {
        var attachments: [Attachment] = []
        var first: Note?
        for url in files {
            let type = UTType(filenameExtension: url.pathExtension)
            if MailNote.isMail(url), let note = MailImport.save(url, project: project, context: context, processing: processing) {
                first = first ?? note
                continue
            }
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
        // Shared or dropped files came in here: this device summarizes them once their text is read (`AutoSummary`).
        if note.source == .share { AutoSummary.markOrigin(note.id) }
        processing.enqueue(.attachment(note.id))
    }
}
