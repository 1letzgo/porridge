import Foundation
import SwiftData
import UniformTypeIdentifiers

/// A mail as the text of an inbox entry, and back: the header lines the entry starts with say who sent it and when,
/// which the document recognition takes as a hint (`DocumentExtractor.extract`). Pure, so it is tested without a store.
enum MailNote {
    static let fromLabel = "**From:** "
    static let toLabel = "**To:** "
    static let ccLabel = "**Cc:** "
    static let dateLabel = "**Date:** "

    /// The mail as Markdown: From, To, Cc and Date as lines on top, then its text. The subject is the entry's title.
    static func text(for message: MailMessage, timeZone: TimeZone = .current) -> String {
        var header: [String] = []
        if let from = message.from { header.append(fromLabel + from.display) }
        if !message.to.isEmpty { header.append(toLabel + message.to.map(\.display).joined(separator: ", ")) }
        if !message.cc.isEmpty { header.append(ccLabel + message.cc.map(\.display).joined(separator: ", ")) }
        if let date = message.date { header.append(dateLabel + dateText(date, timeZone: timeZone)) }
        let body = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = header.joined(separator: "\n")
        return [lines, body].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// "2026-03-03 10:15": readable, and read back as the document's day.
    static func dateText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// The title of the entry: the subject, or who it is from.
    static func title(for message: MailMessage) -> String {
        if !message.subject.isEmpty { return String(message.subject.prefix(300)) }
        if let from = message.from { return "Mail from \(from.senderName)" }
        return "Mail"
    }

    /// The header line of an entry made from a mail; nil for any other text.
    private static func headerValue(_ label: String, in text: String) -> String? {
        guard text.hasPrefix(fromLabel) || text.hasPrefix(toLabel) || text.hasPrefix(dateLabel) else { return nil }
        for line in text.components(separatedBy: "\n").prefix(6) {
            let clean = line.trimmingCharacters(in: .whitespaces)
            if clean.hasPrefix(label) { return String(clean.dropFirst(label.count)).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// Who sent the mail an entry was made from: "Telekom", or the domain of the address ("telekom.de").
    static func sender(in text: String) -> String? {
        guard let value = headerValue(fromLabel, in: text), let address = MIMEHeader.address(value) else { return nil }
        let name = address.senderName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The day the mail an entry was made from was sent, "2026-03-03".
    static func day(in text: String) -> String? {
        headerValue(dateLabel, in: text).flatMap { DocumentExtractor.dates(in: $0).first }
    }

    /// Whether a file is a mail (.eml).
    static func isMail(_ url: URL) -> Bool { isMail(name: url.lastPathComponent) }

    static func isMail(name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "eml" { return true }
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .emailMessage)
    }

    /// The files of a mail in the order they are attached: PDFs first, then office documents, pictures and the rest,
    /// each in the mail's order. What the entry is as a document is read from its first file.
    static func ordered(_ files: [MailMessage.Attachment]) -> [MailMessage.Attachment] {
        func rank(_ file: MailMessage.Attachment) -> Int {
            let ext = (fileName(for: file) as NSString).pathExtension.lowercased()
            if ext == "pdf" { return 0 }
            if Attachment.documentExtensions.contains(ext) { return 1 }
            if file.mimeType.lowercased().hasPrefix("image/") || UTType(filenameExtension: ext)?.conforms(to: .image) == true { return 2 }
            return 3
        }
        return files.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    /// The name a file is saved under: its own, with the extension its type has when the name has none.
    static func fileName(for file: MailMessage.Attachment) -> String {
        // The sender chooses the name: no ".", "..", path marks or names too long for the file system.
        let given = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (given as NSString).pathExtension
        let base = (given as NSString).deletingPathExtension
        var name = FullExport.safeName(base, fallback: "Attachment")
        let cleanExt = FullExport.safeName(ext, fallback: "")
        if !cleanExt.isEmpty, cleanExt.count <= 16 { name += "." + cleanExt }
        if (name as NSString).pathExtension.isEmpty,
           let ext = UTType(mimeType: file.mimeType)?.preferredFilenameExtension ?? (file.mimeType == "message/rfc822" ? "eml" : nil) {
            name += "." + ext
        }
        return name
    }
}

/// Mails brought into the app (shared from a mail app, dropped, opened) become one inbox entry each: the mail as its
/// text, its files as its attachments. PDFs and pictures are read like any shared document (`ShareImport.attach`),
/// so the document's kind, sender, date and amount are filled in.
@MainActor
enum MailImport {
    /// Saves the mail in the file as an entry; nil when it is no mail that can be read.
    static func save(_ url: URL, project: String? = nil, date: Date = Date(), context: ModelContext, processing: ProcessingService) -> Note? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let message = try? MailMessage.parse(contentsOf: url) else { return nil }
        return save(message, project: project, date: date, context: context, processing: processing)
    }

    @discardableResult
    static func save(_ message: MailMessage, project: String? = nil, date: Date = Date(), context: ModelContext, processing: ProcessingService) -> Note {
        let note = Note()
        note.source = .share
        note.title = MailNote.title(for: message)
        note.text = MailNote.text(for: message)
        note.createdAt = date
        note.updatedAt = date
        if let project {
            note.projectIDs = Projects.assigned(project)
            note.filedAt = date
        }
        context.insert(note)

        var attachments: [Attachment] = []
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MailImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, file) in MailNote.ordered(message.files).enumerated() where !file.data.isEmpty {
            let name = MailNote.fileName(for: file)
            // Each in a folder of its own: two attachments may have the same name.
            let place = folder.appendingPathComponent("\(index)", isDirectory: true)
            try? FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let source = place.appendingPathComponent(name)
            guard (try? file.data.write(to: source)) != nil, let attachment = try? AttachmentStore.add(source, name: name) else { continue }
            attachments.append(attachment)
        }
        if attachments.isEmpty {
            // Only text: summarized on this device like a shared text.
            AutoSummary.markOrigin(note.id)
        } else {
            ShareImport.attach(attachments, to: note, processing: processing)
        }
        return note
    }
}
