import Foundation
import PDFKit
import SwiftData

/// Changes the PDF of a document: its text layer (`PDFTextLayer`), its pages (`PDFPages`), several merged into one.
///
/// A changed file is written under a new name and the attachment is pointed at it. The new file starts on this device
/// and moves into iCloud like any new file (`CloudFiles`); the other devices fetch it by its name once the note's list
/// of attachments synced, so no device keeps a stale copy of a file that changed under the same name, and no write has
/// to wait for a download. The old file is not deleted right away: another device may still point at it (its sync not
/// arrived yet, or a change of its own to the attachments written at the same time). It is remembered on this device
/// (`ReplacedFiles`, not synced) and deleted after a grace period, and only when no entry points at it any more.
/// The attachment keeps its id and what the document is (`Attachment.document`); the note's text is read again from
/// the new file (`ProcessingService`), which only needs Vision for pages that have no text yet.
@MainActor
enum DocumentFiles {
    enum EditError: LocalizedError {
        case notAPDF
        case unreadable
        case notWritten
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .notAPDF: "This document is no PDF."
            case .unreadable: "The PDF could not be opened."
            case .notWritten: "The PDF could not be saved."
            case .notLoaded: "The PDF changed or was not opened completely, so nothing was saved. Please open it again."
            }
        }
    }

    /// Merging or splitting is running: a second one waits until it is done.
    private(set) static var isBusy = false

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
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw EditError.unreadable }
        return document
    }

    /// Writes `data` as the attachment's new file (a new name, see above), saves the note, and remembers the old file
    /// for deletion later.
    static func replace(_ attachmentID: String, of note: Note, with data: Data, context: ModelContext? = nil) throws {
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
        try? (context ?? note.modelContext)?.save()
        ReplacedFiles.remember(old)
    }

    /// Saves an edited copy as the document's PDF and has its text read again; pages without text get their text
    /// layer on the way (`ProcessingService.processAttachments`). What the document is stays. `loadedFrom` is the
    /// file name the copy was loaded from (`load`): nothing is saved when it was never loaded or the file changed
    /// meanwhile, so a failed load can never overwrite the document with only the pages added to it.
    static func save(
        _ document: PDFDocument, as attachment: Attachment, loadedFrom fileName: String?, of note: Note,
        context: ModelContext, processing: ProcessingService
    ) throws {
        guard let fileName, let current = note.attachments.first(where: { $0.id == attachment.id }),
              current.fileName == fileName else { throw EditError.notLoaded }
        guard document.pageCount > 0, let data = document.dataRepresentation() else { throw EditError.notWritten }
        // Waiting to be read: the new file stays on this device until then (`CloudFiles.filesToUpload`).
        note.status = .recorded
        try replace(attachment.id, of: note, with: data, context: context)
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

    /// Deletes the files replaced on this device whose grace period is over and that no entry points at (the trash
    /// included). Run once per launch.
    static func purgeReplaced(in context: ModelContext, now: Date = Date()) {
        guard ReplacedFiles.hasDue(now: now) else { return }
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let referenced = Set(notes.flatMap(\.storedFileNames))
        ReplacedFiles.purge(referenced: referenced, now: now) { AudioStore.delete($0) }
    }

    // MARK: Splitting

    /// Moves pages of the note's PDF into new documents, one per group (`PDFPages.groups`), each in the same bowls
    /// (or the inbox) as the original. The original keeps the other pages. The new documents are read like a fresh
    /// import (text, document info, summary); a kind and sender the user set on the original come along as a start.
    /// Returns the new notes.
    @discardableResult
    static func split(_ note: Note, _ split: PDFPages.Split, context: ModelContext, processing: ProcessingService) async throws -> [Note] {
        guard !isBusy else { return [] }
        isBusy = true
        defer { isBusy = false }
        guard let file = pdf(of: note) else { throw EditError.notAPDF }
        let document = try await load(file)
        let groups = PDFPages.groups(for: split, pageCount: document.pageCount)
        guard !groups.isEmpty else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Split/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = String(note.displayTitle.prefix(80))
        var made: [Note] = []
        for group in groups {
            guard let data = PDFPages.extract(document, pages: group).dataRepresentation() else { throw EditError.notWritten }
            let title = "\(base) (\(PDFPages.label(group)))"
            // The file has a plain name; the name shown is passed on its own (a long title is no file name).
            let url = folder.appendingPathComponent(UUID().uuidString + ".pdf")
            try data.write(to: url)
            var attachment = try AttachmentStore.add(url, name: title.replacingOccurrences(of: "/", with: "-") + ".pdf")
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
        try save(kept, as: file, loadedFrom: file.fileName, of: note, context: context, processing: processing)
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

    /// Of the notes merged into another, those that hold nothing but that PDF: only they may be deleted afterwards.
    /// One with more files or with text of its own keeps them (only its first PDF was merged).
    static func deletableAfterMerge(_ notes: [Note]) -> [Note] {
        notes.filter { note in
            note.attachments.count == 1 && pdf(of: note) != nil
                && note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !note.isRecording && note.url == nil
        }
    }

    /// Puts the pages of `others` after those of `target`, in the order given, into the target's PDF (the first PDF of
    /// each). The target keeps what it is; what it does not know yet is taken from the others (the first that knows
    /// it). The others stay as they are: deleting them is asked for separately (`deletableAfterMerge`).
    static func merge(_ others: [Note], into target: Note, context: ModelContext, processing: ProcessingService) async throws {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard let targetFile = pdf(of: target) else { throw EditError.notAPDF }
        var documents = [try await load(targetFile)]
        for note in others {
            guard let file = pdf(of: note) else { throw EditError.notAPDF }
            documents.append(try await load(file))
        }
        let merged = PDFPages.merged(documents)
        target.documentInfo = mergedInfo(target: target.documentInfo, others: others.map(\.documentInfo))
        try save(merged, as: targetFile, loadedFrom: targetFile.fileName, of: target, context: context, processing: processing)
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

/// The files this device replaced with a new version (`DocumentFiles.replace`), with when. Kept on this device only:
/// they are deleted after `grace`, and only when no entry points at them any more, so a device whose sync still names
/// the old file can read it meanwhile.
enum ReplacedFiles {
    static let key = "replacedAttachmentFiles"
    /// Long enough for every device to have synced the new name.
    static let grace: TimeInterval = 7 * 86_400

    static func remember(_ name: String, now: Date = Date(), defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[name] = now.timeIntervalSince1970
        defaults.set(all, forKey: key)
    }

    static func pending(defaults: UserDefaults = .standard) -> [String: Date] {
        (defaults.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }

    static func hasDue(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        pending(defaults: defaults).values.contains { now.timeIntervalSince($0) >= grace }
    }

    /// Deletes (through `delete`) the files whose grace period is over and that are not `referenced`; a file still
    /// named by an entry is forgotten without deleting it. Returns the deleted names.
    @discardableResult
    static func purge(referenced: Set<String>, now: Date = Date(), defaults: UserDefaults = .standard, delete: (String) -> Void) -> [String] {
        var all = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        var deleted: [String] = []
        for (name, at) in all where now.timeIntervalSince1970 - at >= grace {
            all[name] = nil
            guard !referenced.contains(name) else { continue }
            delete(name)
            deleted.append(name)
        }
        defaults.set(all, forKey: key)
        return deleted.sorted()
    }
}
