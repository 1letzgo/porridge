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

    /// A paper kept in the app: a PDF or office document brought in (scanned, shared, dropped, picked), or an
    /// image that was read as one (a photographed receipt). A note with a file attached stays a note.
    var isDocument: Bool {
        guard isStored, let first = attachments.first else { return false }
        if first.isDocumentFile { return true }
        return first.document?.isMeaningful ?? false
    }

    /// A document of the kind the word names, in German or English: "Rechnung", "Verträge", "receipts".
    func isDocument(named word: String) -> Bool {
        guard attachmentsData != nil, let kind = DocumentKind.named(word), isDocument else { return false }
        return (documentInfo?.kind ?? .other) == kind
    }

    /// The date on the document, or when it came in.
    var documentDate: Date { documentInfo?.date ?? createdAt }

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
    /// Every document that is not deleted, newest document date first.
    static func all(_ notes: [Note]) -> [Note] {
        sorted(notes.filter { !$0.isDeleted && $0.isDocument })
    }

    static func sorted(_ documents: [Note]) -> [Note] {
        documents
            .map { (note: $0, date: $0.documentDate) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.note.createdAt > $1.note.createdAt }
            .map(\.note)
    }

    /// The documents of one kind and one sender (by `DocumentExtractor.correspondentKey`); nil lets any through.
    static func filtered(_ documents: [Note], kind: DocumentKind?, correspondent: String?) -> [Note] {
        let key = correspondent.map(DocumentExtractor.correspondentKey)
        return documents.filter { note in
            let info = note.documentInfo
            if let kind, (info?.kind ?? .other) != kind { return false }
            if let key, info?.correspondent.map(DocumentExtractor.correspondentKey) != key { return false }
            return true
        }
    }

    /// How many documents there are of each kind, in the order of `DocumentKind`; kinds with none are left out.
    /// A document whose kind is not known counts as "Other".
    static func kindCounts(_ documents: [Note]) -> [(kind: DocumentKind, count: Int)] {
        var counts: [DocumentKind: Int] = [:]
        for note in documents { counts[note.documentInfo?.kind ?? .other, default: 0] += 1 }
        return DocumentKind.allCases.compactMap { kind in counts[kind].map { (kind, $0) } }
    }

    /// The senders with how many documents each sent, by name. Spellings of the same sender count together, under
    /// the name used most.
    static func correspondents(_ documents: [Note]) -> [(name: String, count: Int)] {
        var names: [String: [String: Int]] = [:]
        for note in documents {
            guard let name = note.documentInfo?.correspondent else { continue }
            let key = DocumentExtractor.correspondentKey(name)
            guard !key.isEmpty else { continue }
            names[key, default: [:]][name, default: 0] += 1
        }
        return names.values
            .map { spellings in
                let name = spellings.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
                return (name: name, count: spellings.values.reduce(0, +))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Documents under the year of their date, newest year first; the order within a year is kept.
    static func yearGroups(_ documents: [Note], calendar: Calendar = DocumentInfo.calendar) -> [(title: String, notes: [Note])] {
        var result: [(title: String, notes: [Note])] = []
        for note in documents {
            let title = String(calendar.component(.year, from: note.documentDate))
            if result.last?.title == title {
                result[result.count - 1].notes.append(note)
            } else if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].notes.append(note)
            } else {
                result.append((title, [note]))
            }
        }
        return result
    }

    /// The search's words name the document's kind ("Rechnung", "Verträge") and the other words are in it: found
    /// even when the kind's word is not in its text. At least one word has to name the kind.
    static func matches(_ note: Note, query: String) -> Bool {
        let words = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard note.isStored, words.contains(where: note.isDocument(named:)) else { return false }
        return words.allSatisfy { word in note.isDocument(named: word) || note.matches(word) }
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
        let guess = DocumentExtractor.extract(from: text, name: first.name, now: now)
        let before = note.documentInfo
        note.documentInfo = before.map { guess.merged(with: $0) } ?? guess
        return before != note.documentInfo
    }

    /// What the summary's model found (`DocumentLine`): it replaces the device's guess where it knows something.
    /// Nothing changes what the user set by hand.
    static func apply(_ found: DocumentInfo, to note: Note) {
        guard note.isStored, !note.attachments.isEmpty else { return }
        let current = note.documentInfo ?? DocumentInfo()
        guard !current.edited else { return }
        note.documentInfo = current.merged(with: found)
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

    /// Stored files read before documents were looked at get their first guess; each only once (an empty
    /// `DocumentInfo` marks one with nothing found). Returns how many were read.
    @discardableResult
    static func backfill(in context: ModelContext, now: Date = Date()) -> Int {
        let notes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.attachmentsData != nil && $0.pageText != nil && $0.deletedAt == nil }))) ?? []
        var count = 0
        for note in notes where note.isStored {
            guard let first = note.attachments.first, first.document == nil else { continue }
            note.documentInfo = DocumentExtractor.extract(from: note.pageText ?? "", name: first.name, now: now)
            count += 1
        }
        if count > 0 { try? context.save() }
        return count
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
