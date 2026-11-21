import Foundation
import PDFKit
import SwiftData

/// Changes the PDF of a document: its text layer (`PDFTextLayer`), its pages (`PDFPages`), several merged into one.
///
/// A changed file is written under a new name and the attachment is pointed at it; the old file is deleted (here and
/// in iCloud, coordinated). The new file starts on this device and moves into iCloud like any new file (`CloudFiles`),
/// and the other devices fetch it by its name once the note's list of attachments synced: no device ever keeps a
/// stale copy of a file that changed under the same name, and no write has to wait for a download. The attachment
/// keeps its id and what the document is (`Attachment.document`); the note's text is read again from the new file
/// (`ProcessingService`), which only needs Vision for pages that have no text yet.
@MainActor
enum DocumentFiles {
    enum EditError: LocalizedError {
        case notAPDF
        case unreadable
        case notWritten

        var errorDescription: String? {
            switch self {
            case .notAPDF: "This document is no PDF."
            case .unreadable: "The PDF could not be opened."
            case .notWritten: "The PDF could not be saved."
            }
        }
    }

    /// The PDF of a note whose pages can be edited: its first PDF.
    static func pdf(of note: Note) -> Attachment? {
        guard note.attachmentsData != nil else { return nil }
        return note.attachments.first { $0.kind == .pdf }
    }

    /// The PDF in memory, downloaded from iCloud first when it is only there. Read whole, so the file can be
    /// replaced while the copy is edited.
    static func load(_ attachment: Attachment) async throws -> PDFDocument {
        guard attachment.kind == .pdf else { throw EditError.notAPDF }
        let url = try await AttachmentStore.download(attachment)
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        guard let document = PDFDocument(data: data) else { throw EditError.unreadable }
        return document
    }

    /// Writes `data` as the attachment's new file (a new name, see above) and deletes the old one.
    static func replace(_ attachmentID: String, of note: Note, with data: Data) throws {
        var list = note.attachments
        guard let index = list.firstIndex(where: { $0.id == attachmentID }) else { throw EditError.notWritten }
        let old = list[index].fileName
        let ext = (old as NSString).pathExtension.isEmpty ? "pdf" : (old as NSString).pathExtension
        let name = AudioStore.newFileName(extension: ext)
        try data.write(to: AudioStore.localURL(for: name), options: .atomic)
        list[index].fileName = name
        list[index].bytes = Int64(data.count)
        note.attachments = list
        note.updatedAt = Date()
        AudioStore.delete(old)
    }

    /// Saves an edited copy (`load`) as the document's PDF and has its text read again; pages without text get
    /// their text layer on the way (`ProcessingService.processAttachments`). What the document is stays.
    static func save(_ document: PDFDocument, as attachment: Attachment, of note: Note, context: ModelContext, processing: ProcessingService) throws {
        guard let data = document.dataRepresentation() else { throw EditError.notWritten }
        try replace(attachment.id, of: note, with: data)
        // Waiting to be read: the new file stays on this device until then (`CloudFiles.filesToUpload`).
        note.status = .recorded
        try? context.save()
        processing.enqueue(.attachment(note.id))
    }

    /// Gives the note's PDFs a text layer where pages have none (scans, pictures saved as PDF). Only files on this
    /// device; the work runs in the background. Returns whether a file changed.
    static func makeSearchable(_ note: Note) async -> Bool {
        guard note.isStored else { return false }
        var changed = false
        for attachment in note.attachments where attachment.kind == .pdf && AttachmentStore.exists(attachment) {
            let url = AttachmentStore.url(for: attachment)
            let layered = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return PDFTextLayer.searchableData(of: data)
            }.value
            // Gone or changed meanwhile: nothing is written over it.
            guard let layered, note.modelContext != nil, note.attachments.contains(where: { $0.id == attachment.id && $0.fileName == attachment.fileName }) else { continue }
            do {
                try replace(attachment.id, of: note, with: layered)
                changed = true
            } catch {
                print("[pdf] text layer not saved: \(error.localizedDescription)")
            }
        }
        return changed
    }

    // MARK: Splitting

    /// Moves pages of the note's PDF into new documents, one per group (`PDFPages.groups`), each in the same bowls
    /// (or the inbox) as the original. The original keeps the other pages. The new documents are read like a fresh
    /// import (text, document info, summary); a kind and sender the user set on the original come along as a start.
    /// Returns the new notes.
    @discardableResult
    static func split(_ note: Note, _ split: PDFPages.Split, context: ModelContext, processing: ProcessingService) async throws -> [Note] {
        guard let file = pdf(of: note) else { throw EditError.notAPDF }
        let document = try await load(file)
        let groups = PDFPages.groups(for: split, pageCount: document.pageCount)
        guard !groups.isEmpty else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Split/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = note.displayTitle
        var made: [Note] = []
        for group in groups {
            guard let data = PDFPages.extract(document, pages: group).dataRepresentation() else { throw EditError.notWritten }
            let title = "\(base) (\(PDFPages.label(group)))"
            let url = folder.appendingPathComponent(title.replacingOccurrences(of: "/", with: "-") + ".pdf")
            try data.write(to: url)
            var attachment = try AttachmentStore.add(url, name: url.lastPathComponent)
            attachment.document = carriedInfo(note.documentInfo)
            let part = Note()
            part.source = .share
            part.title = title
            part.projectIDs = note.projectIDs
            part.filedAt = note.projectIDs.isEmpty ? nil : Date()
            context.insert(part)
            ShareImport.attach([attachment], to: part, processing: processing)
            made.append(part)
        }
        let kept = PDFPages.extract(document, pages: Array(Set(0..<document.pageCount).subtracting(groups.flatMap { $0 })))
        try save(kept, as: file, of: note, context: context, processing: processing)
        try? context.save()
        return made
    }

    /// What a split-off part starts with: only the kind and sender the user set by hand on the original; its date
    /// and amount are read from its own pages.
    nonisolated static func carriedInfo(_ info: DocumentInfo?) -> DocumentInfo? {
        guard let info, info.edited, info.kind != nil || info.correspondent != nil else { return nil }
        return DocumentInfo(kind: info.kind, correspondent: info.correspondent)
    }

    // MARK: Merging

    /// The notes that can be merged: documents with a PDF.
    static func mergeable(_ notes: [Note]) -> [Note] {
        notes.filter { !$0.isDeleted && $0.isStored && pdf(of: $0) != nil }
    }

    /// Puts the pages of `others` after those of `target`, in the order given, into the target's PDF. The target
    /// keeps what it is; what it does not know yet is taken from the others (the first that knows it). The others
    /// stay as they are: deleting them is asked for separately.
    static func merge(_ others: [Note], into target: Note, context: ModelContext, processing: ProcessingService) async throws {
        guard let targetFile = pdf(of: target) else { throw EditError.notAPDF }
        var documents = [try await load(targetFile)]
        for note in others {
            guard let file = pdf(of: note) else { throw EditError.notAPDF }
            documents.append(try await load(file))
        }
        let merged = PDFPages.merged(documents)
        try save(merged, as: targetFile, of: target, context: context, processing: processing)
        target.documentInfo = mergedInfo(target: target.documentInfo, others: others.map(\.documentInfo))
        try? context.save()
    }

    /// The target's info, gaps filled from the others in order. Never marked as set by hand unless it was.
    nonisolated static func mergedInfo(target: DocumentInfo?, others: [DocumentInfo?]) -> DocumentInfo? {
        var result = target
        for other in others.compactMap({ $0 }) {
            var filled = other
            filled.isEdited = nil
            result = filled.merged(with: result ?? DocumentInfo())
            if let target { result?.isEdited = target.isEdited }
        }
        return result
    }
}
