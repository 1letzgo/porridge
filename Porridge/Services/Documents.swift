import Foundation
import SwiftData

extension Attachment {
    /// Extensions of files that are papers to keep: PDFs and office and text documents (not archives or audio).
    static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "docm", "dotx", "odt", "rtf", "txt", "md", "pages", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key",
    ]

    /// A PDF or an office or text document.
    var isDocumentFile: Bool {
        if kind == .pdf { return true }
        guard kind == .file else { return false }
        return Attachment.documentExtensions.contains((name as NSString).pathExtension.lowercased())
            || Attachment.documentExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }
}

extension Note {
    /// What the note's file is as a document; kept on its first attachment (`Attachment.document`).
    var documentInfo: DocumentInfo? {
        get { attachmentsData == nil ? nil : attachments.first?.document }
        set {
            var list = attachments
            guard !list.isEmpty, list[0].document != newValue else { return }
            list[0].document = newValue
            attachments = list
        }
    }

    /// A paper kept in the app: a PDF or office document brought in (scanned, shared, dropped, picked), or another
    /// file (a photographed receipt, a screenshot) that was read as one or marked as one by hand. A note with a file
    /// attached stays a note.
    var isDocument: Bool {
        guard isStored, let first = attachments.first else { return false }
        if first.isDocumentFile { return true }
        guard let info = first.document else { return false }
        return info.isMeaningful || (info.edited && !info.isEmpty)
    }

    /// A document of the kind the word names, in German or English: "Rechnung", "Verträge", "receipts".
    func isDocument(named word: String) -> Bool {
        guard attachmentsData != nil, let kind = DocumentKind.named(word), isDocument else { return false }
        return (documentInfo?.kind ?? .other) == kind
    }

    /// The date on the document, or when it came in.
    var documentDate: Date { documentInfo?.date ?? createdAt }

    /// Open, overdue or paid for a document whose payment is followed (`DocumentInfo.paymentStatus`); nil otherwise.
    /// For filters: `note.paymentStatus() == .overdue`.
    func paymentStatus(now: Date = Date()) -> DocumentInfo.PaymentStatus? {
        guard attachmentsData != nil, isDocument else { return nil }
        return documentInfo?.paymentStatus(now: now)
    }

    /// Takes a file off the note. What the document is lives on the first file: when that one goes, it moves to the
    /// file that is first now, so nothing read or set by hand is lost.
    func removeAttachment(id: String) {
        var list = attachments
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        let removed = list.remove(at: index)
        if index == 0, let info = removed.document, !list.isEmpty, list[0].document == nil {
            list[0].document = info
        }
        attachments = list
    }
}

/// The documents of the app as a small document management: every PDF, scan and office file across the inbox and
/// the bowls, what each is (kind, date, sender, amount), and where it should be filed. Only a view over the notes:
/// the documents stay where they are.
@MainActor
enum Documents {
    /// Documents by the date on them, newest first (the order several are merged in).
    static func sorted(_ documents: [Note]) -> [Note] {
        documents
            .map { (note: $0, date: $0.documentDate) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.note.createdAt > $1.note.createdAt }
            .map(\.note)
    }

    /// The search's words name the document's kind ("Rechnung", "Verträge") and the other words are in it: found
    /// even when the kind's word is not in its text. At least one word has to name the kind.
    /// A word naming a state of payment ("offene", "unbezahlt", "überfällig", "paid") counts like a kind's word: the
    /// document has to be in that state.
    static func matches(_ note: Note, query: String, now: Date = Date()) -> Bool {
        let words = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard note.isStored, words.contains(where: { note.isDocument(named: $0) || DocumentInfo.paymentStatus(named: $0) != nil }) else { return false }
        return words.allSatisfy { word in
            if let status = DocumentInfo.paymentStatus(named: word) {
                return note.isDocument && (note.documentInfo?.matches(status, now: now) ?? false)
            }
            return note.isDocument(named: word) || note.matches(word)
        }
    }

    // MARK: Reading

    /// After the file's text was read: a first guess on the device. It only fills what is not known yet: what the
    /// model found or the user set (here or on another device) is never replaced by it. Nothing read (a file iCloud
    /// did not deliver yet) changes nothing. A note that is not a stored file is left alone. Returns whether
    /// anything changed.
    @discardableResult
    static func read(_ note: Note, text: String, now: Date = Date()) -> Bool {
        guard note.isStored, let first = note.attachments.first, first.document?.edited != true,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A document that came with a mail: the mail's sender and day help where the document names none.
        let guess = DocumentExtractor.extract(
            from: text, name: first.name, senderHint: MailNote.sender(in: note.text), dayHint: MailNote.day(in: note.text), now: now
        )
        let before = note.documentInfo
        note.documentInfo = before.map { guess.merged(with: $0) } ?? guess
        return before != note.documentInfo
    }

    /// What the summary's model found (`DocumentLine`): it replaces the device's guess where it knows something.
    /// Nothing changes what the user set by hand.
    static func apply(_ found: DocumentInfo, to note: Note, now: Date = Date()) {
        guard note.isStored, !note.attachments.isEmpty else { return }
        let current = note.documentInfo ?? DocumentInfo()
        guard !current.edited else { return }
        var merged = current.merged(with: found.droppingStaleDueDay(now: now))
        // A kind the model corrected to one that is not paid (a contract) has no due day.
        if !merged.canBePaid { merged.dueDay = nil }
        note.documentInfo = merged
    }

    /// Set by hand on the document's page: kept from now on.
    static func set(_ info: DocumentInfo, on note: Note, in context: ModelContext) {
        var info = info
        info.correspondent = info.correspondent?.trimmingCharacters(in: .whitespacesAndNewlines)
        if info.correspondent?.isEmpty == true { info.correspondent = nil }
        info.isEdited = true
        note.documentInfo = info
        note.updatedAt = Date()
        // A sender filed before somewhere: the document in the inbox is offered that bowl.
        if note.isInInbox, note.suggestedProjectIDs.isEmpty, let bowl = suggestedBowl(for: note, in: context) {
            note.suggestedProjectIDs = [bowl]
        }
        try? context.save()
    }

    /// Takes what the document is away by hand (the cross on its chip). That is a decision: kept as an empty info set
    /// by hand, so no reading (on the device, by the model, the backfill, after a page edit) brings it back. Setting it by
    /// hand again works as always. A PDF stays a document (with nothing known), another file is a file again.
    static func clear(_ note: Note, in context: ModelContext) {
        guard note.isStored, !note.attachments.isEmpty else { return }
        note.documentInfo = DocumentInfo(isEdited: true)
        note.updatedAt = Date()
        try? context.save()
    }

    /// Stored files read before documents were looked at get their first guess; each only once (an empty
    /// `DocumentInfo` marks one with nothing found). Returns how many were read.
    @discardableResult
    static func backfill(in context: ModelContext, now: Date = Date()) -> Int {
        let notes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.attachmentsData != nil && $0.pageText != nil && $0.deletedAt == nil }))) ?? []
        var count = 0
        for note in notes where note.isStored {
            guard let first = note.attachments.first, first.document == nil else { continue }
            note.documentInfo = DocumentExtractor.extract(
                from: note.pageText ?? "", name: first.name, senderHint: MailNote.sender(in: note.text), dayHint: MailNote.day(in: note.text), now: now
            )
            count += 1
        }
        if count > 0 { try? context.save() }
        return count
    }

    // MARK: Changing several at once

    /// One change for several selected entries.
    enum BulkChange: Equatable {
        /// Into one bowl (out of the others), or out of all into the inbox (nil).
        case move(toBowl: String?)
        /// The document kind; nil takes it away. Only documents (stored files) change.
        case kind(DocumentKind?)
        /// The sender; nil or empty takes it away. Only documents change.
        case sender(String?)
        /// Marked as paid (today) or as not paid. Only documents that can be paid change (`DocumentInfo.canBePaid`);
        /// it is not a correction of what was read, so reading the document later still fills what is missing.
        case paid(Bool)
    }

    /// The documents among `notes` that the paid mark applies to.
    static func payable(_ notes: [Note]) -> [Note] {
        notes.filter { !$0.isDeleted && $0.isStored && !$0.attachments.isEmpty && ($0.documentInfo ?? DocumentInfo()).canBePaid }
    }

    /// Applies the change to every note and saves once. A kind or sender set this way counts as set by hand
    /// (never overwritten by reading). Returns how many notes changed.
    @discardableResult
    static func apply(_ change: BulkChange, to notes: [Note], in context: ModelContext, now: Date = Date()) -> Int {
        var changed = 0
        for note in notes where !note.isDeleted {
            switch change {
            case .move(let bowl):
                let target = bowl.map { [$0] } ?? []
                guard note.projectIDs != target else { continue }
                note.projectIDs = target
                if bowl != nil {
                    note.filedAt = note.filedAt ?? now
                    note.suggestedProjectIDs = []
                }
            case .kind(let kind):
                guard note.isStored, !note.attachments.isEmpty else { continue }
                var info = note.documentInfo ?? DocumentInfo()
                info.kind = kind
                info.isEdited = true
                guard info != note.documentInfo else { continue }
                note.documentInfo = info
            case .sender(let sender):
                guard note.isStored, !note.attachments.isEmpty else { continue }
                var info = note.documentInfo ?? DocumentInfo()
                let clean = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
                info.correspondent = clean?.isEmpty == false ? clean : nil
                info.isEdited = true
                guard info != note.documentInfo else { continue }
                note.documentInfo = info
            case .paid(let paid):
                guard note.isStored, !note.attachments.isEmpty else { continue }
                var info = note.documentInfo ?? DocumentInfo()
                guard info.canBePaid, info.paid != paid else { continue }
                info.setPaid(paid, now: now)
                note.documentInfo = info
            }
            note.updatedAt = now
            changed += 1
        }
        if changed > 0 { try? context.save() }
        return changed
    }

    // MARK: Filing

    /// The bowl documents of the same sender were filed into most often: where this one most likely belongs.
    /// Only active bowls, only for a document still in the inbox.
    static func suggestedBowl(for note: Note, among notes: [Note], bowls: Set<String>) -> String? {
        guard note.isInInbox, let name = note.documentInfo?.correspondent else { return nil }
        let key = DocumentExtractor.correspondentKey(name)
        guard !key.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for other in notes where other.id != note.id && !other.isDeleted && !other.projectIDs.isEmpty && other.isStored {
            guard let sender = other.documentInfo?.correspondent, DocumentExtractor.correspondentKey(sender) == key else { continue }
            for id in other.projectIDs where bowls.contains(id) { counts[id, default: 0] += 1 }
        }
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
    }

    static func suggestedBowl(for note: Note, in context: ModelContext?) -> String? {
        guard let context, note.isInInbox, note.documentInfo?.correspondent != nil else { return nil }
        let bowls = Set(((try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []).filter { !$0.isArchived }.map(Projects.key))
        guard !bowls.isEmpty else { return nil }
        let notes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.attachmentsData != nil && $0.deletedAt == nil }))) ?? []
        return suggestedBowl(for: note, among: notes, bowls: bowls)
    }
}
