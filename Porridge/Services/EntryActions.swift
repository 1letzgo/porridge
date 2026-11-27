import Foundation
import SwiftData

/// Small changes to entries made on the user's behalf (the chat's actions, and whatever else wants them): file an
/// entry into a bowl, make a bowl, make an entry a to-do or tick it, set tags, correct what a document is, write a
/// note. Each change returns the way back (`Undo`). Nothing here deletes or archives what the user has: an undo only
/// takes back what the change itself made.
@MainActor
enum EntryActions {
    enum Failure: LocalizedError, Equatable {
        case entryGone
        case bowlGone
        case emptyName
        case bowlExists(String)
        case cannotBeTodo
        case notADocument
        case nothingToChange
        case viewOnly

        var errorDescription: String? {
            switch self {
            case .entryGone: "The entry is no longer there."
            case .bowlGone: "The bowl is no longer there."
            case .emptyName: "A name is missing."
            case .bowlExists(let name): "A bowl named “\(name)” already exists."
            case .cannotBeTodo: "Links, saved files and meetings cannot be to-dos."
            case .notADocument: "This entry is not a document."
            case .nothingToChange: "Nothing to change: it already is that way."
            case .viewOnly: "The bowl is shared with you to view only."
            }
        }
    }

    /// The fields of an entry these changes touch, as they were before.
    struct Snapshot: Equatable {
        let noteID: UUID
        let projectIDs: [String]
        let filedAt: Date?
        let suggestedProjectIDs: [String]
        let todoStateRaw: String?
        let todoDoneAt: Date?
        let todoDueDay: String?
        /// Holds the repeat rule of a to-do (`Note.todoRepeat`).
        let todoSuggestionsRaw: String?
        let text: String
        let labels: [String]
        let attachmentsData: Data?
        let updatedAt: Date

        init(_ note: Note) {
            noteID = note.id
            projectIDs = note.projectIDs
            filedAt = note.filedAt
            suggestedProjectIDs = note.suggestedProjectIDs
            todoStateRaw = note.todoStateRaw
            todoDoneAt = note.todoDoneAt
            todoDueDay = note.todoDueDay
            todoSuggestionsRaw = note.todoSuggestionsRaw
            text = note.text
            labels = note.labels
            attachmentsData = note.attachmentsData
            updatedAt = note.updatedAt
        }

        /// The entry is as it was (the time of the change aside).
        func matches(_ note: Note) -> Bool {
            let now = Snapshot(note)
            return now.projectIDs == projectIDs && now.filedAt == filedAt && now.suggestedProjectIDs == suggestedProjectIDs
                && now.todoStateRaw == todoStateRaw && now.todoDoneAt == todoDoneAt && now.todoDueDay == todoDueDay
                && now.todoSuggestionsRaw == todoSuggestionsRaw && now.text == text && now.labels == labels && now.attachmentsData == attachmentsData
        }

        /// Puts back what the change changed (`after`: the entry right after it). A field changed again since then,
        /// here or on another device, keeps that later change. Without `after` everything is put back.
        func restore(on note: Note, after: Snapshot? = nil) {
            var restored = false
            var keptLater = false
            func put<T: Equatable>(_ key: ReferenceWritableKeyPath<Note, T>, _ before: T, _ later: T?) {
                let current = note[keyPath: key]
                if let later {
                    guard before != later else { return }
                    guard current == later else { keptLater = true; return }
                }
                guard current != before else { return }
                note[keyPath: key] = before
                restored = true
            }
            put(\.projectIDs, projectIDs, after?.projectIDs)
            put(\.filedAt, filedAt, after.map(\.filedAt))
            put(\.suggestedProjectIDs, suggestedProjectIDs, after?.suggestedProjectIDs)
            put(\.todoStateRaw, todoStateRaw, after.map(\.todoStateRaw))
            put(\.todoDoneAt, todoDoneAt, after.map(\.todoDoneAt))
            put(\.todoDueDay, todoDueDay, after.map(\.todoDueDay))
            put(\.todoSuggestionsRaw, todoSuggestionsRaw, after.map(\.todoSuggestionsRaw))
            put(\.text, text, after?.text)
            put(\.labels, labels, after?.labels)
            put(\.attachmentsData, attachmentsData, after.map(\.attachmentsData))
            guard restored else { return }
            // As it was when nothing else happened to it; otherwise it was just changed.
            note.updatedAt = keptLater ? Date() : updatedAt
        }
    }

    /// The way back from one or several changes; taken back newest first.
    struct Undo {
        enum Step {
            case restore(Snapshot, after: Snapshot?)
            /// An entry the change wrote: it goes again.
            case removeNote(UUID)
            /// A bowl the change made: it goes again while nothing is in it.
            case removeBowl(UUID)
        }

        var steps: [Step] = []

        var isEmpty: Bool { steps.isEmpty }

        mutating func append(_ other: Undo) { steps += other.steps }
    }

    /// A day of a to-do: set it, or take it away.
    enum DueChange: Equatable {
        case set(String)
        case clear
    }

    /// What is corrected about a document; nil leaves a field as it is.
    struct DocumentChange: Equatable {
        var kind: DocumentKind?
        var day: String?
        var sender: String?
        var amount: String?

        var isEmpty: Bool { kind == nil && day == nil && sender == nil && amount == nil }
    }

    // MARK: Finding

    static func note(_ id: UUID, in context: ModelContext) -> Note? {
        let found = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id }))) ?? []
        return found.first { !$0.isDeleted }
    }

    static func folder(_ id: UUID, in context: ModelContext) -> NoteFolder? {
        (try? context.fetch(FetchDescriptor<NoteFolder>(predicate: #Predicate { $0.id == id })))?.first
    }

    /// A bowl name as it is compared: no case, no accents, single spaces.
    nonisolated static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The bowls (archived ones too) with this name.
    static func bowls(named name: String, in context: ModelContext) -> [NoteFolder] {
        let key = nameKey(name)
        guard !key.isEmpty else { return [] }
        return ((try? context.fetch(FetchDescriptor<NoteFolder>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { nameKey($0.name) == key }
    }

    // MARK: Changes

    /// Into one bowl (out of the one it was in: an entry is in one bowl at most), or into the Inbox (nil).
    @discardableResult
    static func move(_ note: Note, toBowl key: String?, in context: ModelContext, now: Date = Date()) throws -> Undo {
        guard !note.isDeleted else { throw Failure.entryGone }
        try writable(note, bowl: key)
        let target = key.map(Projects.assigned) ?? []
        guard note.projectIDs != target else { throw Failure.nothingToChange }
        if let key, let id = UUID(uuidString: key), folder(id, in: context) == nil { throw Failure.bowlGone }
        let before = Snapshot(note)
        note.projectIDs = target
        if key != nil {
            note.filedAt = note.filedAt ?? now
            note.suggestedProjectIDs = []
        }
        note.updatedAt = now
        try? context.save()
        return Undo(steps: [.restore(before, after: Snapshot(note))])
    }

    /// A new bowl with this name. A bowl of the same name that is there already is not made twice.
    static func createBowl(named name: String, in context: ModelContext) throws -> (bowl: NoteFolder, undo: Undo) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw Failure.emptyName }
        if let existing = bowls(named: name, in: context).first { throw Failure.bowlExists(existing.name) }
        guard let bowl = Projects.create(name, in: context) else { throw Failure.emptyName }
        return (bowl, Undo(steps: [.removeBowl(bowl.id)]))
    }

    /// The active bowl of this name, or a new one: for filing into a bowl named in the same breath.
    static func bowl(named name: String, in context: ModelContext) throws -> (bowl: NoteFolder, undo: Undo) {
        if let existing = bowls(named: name, in: context).first(where: { !$0.isArchived }) { return (existing, Undo()) }
        return try createBowl(named: name, in: context)
    }

    /// Makes the entry a to-do (open) or ticks it (done), and sets or takes away its due day. Links, saved files and
    /// meetings never become to-dos.
    @discardableResult
    static func setTodo(_ note: Note, done: Bool, due: DueChange? = nil, in context: ModelContext) throws -> Undo {
        guard !note.isDeleted else { throw Failure.entryGone }
        try writable(note)
        guard note.isTodo || note.canBeTodo else { throw Failure.cannotBeTodo }
        let before = Snapshot(note)
        if !note.isTodo { Todos.setTodo(true, note, in: context) }
        if done != note.isDone { Todos.setDone(done, note, in: context) }
        switch due {
        case .set(let key): Todos.setDue(key, note, in: context)
        case .clear: if note.todoDue != nil { Todos.setDue(nil, note, in: context) }
        case nil: break
        }
        guard !before.matches(note) else { throw Failure.nothingToChange }
        try? context.save()
        return Undo(steps: [.restore(before, after: Snapshot(note))])
    }

    /// Adds and removes tags (the tag field; `#words` written in the text stay where they are).
    @discardableResult
    static func setTags(_ note: Note, add: [String], remove: [String], in context: ModelContext, now: Date = Date()) throws -> Undo {
        guard !note.isDeleted else { throw Failure.entryGone }
        try writable(note)
        let before = Snapshot(note)
        let removing = Set(remove.map(Note.cleanTag).filter { !$0.isEmpty }.map { $0.lowercased() })
        var labels = note.labels.filter { !removing.contains($0.lowercased()) }
        for tag in add.map(Note.cleanTag) where !tag.isEmpty {
            let lower = tag.lowercased()
            guard !removing.contains(lower), !labels.contains(where: { $0.lowercased() == lower }),
                  !NoteText.tags(in: note.text).contains(where: { $0.lowercased() == lower }) else { continue }
            labels.append(tag)
        }
        guard labels != note.labels else { throw Failure.nothingToChange }
        note.labels = labels
        note.updatedAt = now
        try? context.save()
        return Undo(steps: [.restore(before, after: Snapshot(note))])
    }

    /// Corrects what a document is, the way an edit by hand does (`Documents.set`): reading it again never replaces it.
    @discardableResult
    static func setDocumentInfo(_ note: Note, _ change: DocumentChange, in context: ModelContext) throws -> Undo {
        guard !note.isDeleted else { throw Failure.entryGone }
        try writable(note)
        guard note.isStored, !note.attachments.isEmpty else { throw Failure.notADocument }
        let current = note.documentInfo ?? DocumentInfo()
        var info = current
        if let kind = change.kind { info.kind = kind }
        if let day = change.day { info.day = day }
        if let sender = change.sender { info.correspondent = sender }
        if let amount = change.amount { info.amount = amount }
        info.isEdited = current.isEdited
        guard info != current else { throw Failure.nothingToChange }
        let before = Snapshot(note)
        Documents.set(info, on: note, in: context)
        return Undo(steps: [.restore(before, after: Snapshot(note))])
    }

    /// A new note (or to-do) with this title and text, in a bowl or the Inbox.
    static func createNote(
        title: String, text: String, bowl: String? = nil, todo: Bool = false, due: String? = nil,
        in context: ModelContext, now: Date = Date()
    ) throws -> (note: Note, undo: Undo) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !text.isEmpty else { throw Failure.emptyName }
        if let bowl, BowlSharing.shared.isReadOnly(UUID(uuidString: bowl)) { throw Failure.viewOnly }
        let note = Note()
        note.source = .note
        note.title = title
        note.titleIsCustom = !title.isEmpty
        note.text = text
        note.createdAt = now
        note.updatedAt = now
        if todo {
            note.todoState = .open
            if let due, Todos.isDueKey(due) { note.todoDueDay = due }
        }
        if let bowl {
            note.projectIDs = Projects.assigned(bowl)
            note.filedAt = now
        }
        context.insert(note)
        try? context.save()
        return (note, Undo(steps: [.removeNote(note.id)]))
    }

    /// Entries in a bowl shared with me to view only stay as they are, and nothing goes into such a bowl.
    private static func writable(_ note: Note, bowl key: String? = nil) throws {
        if BowlSharing.shared.isReadOnly(note) { throw Failure.viewOnly }
        if let key, BowlSharing.shared.isReadOnly(UUID(uuidString: key)) { throw Failure.viewOnly }
    }

    // MARK: Taking back

    /// Takes the changes back, newest first.
    static func undo(_ undo: Undo, in context: ModelContext) {
        for step in undo.steps.reversed() {
            switch step {
            case .restore(let snapshot, let after):
                let id = snapshot.noteID
                if let note = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })))?.first {
                    snapshot.restore(on: note, after: after)
                }
            case .removeNote(let id):
                if let note = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })))?.first {
                    context.delete(note)
                }
            case .removeBowl(let id):
                guard let bowl = folder(id, in: context) else { continue }
                let key = Projects.key(bowl)
                let used = ((try? context.fetch(FetchDescriptor<Note>())) ?? []).contains { $0.projectIDs.contains(key) }
                if !used {
                    context.delete(bowl)
                    ReminderLists.shared.bowlWasDeleted(key)
                }
            }
        }
        try? context.save()
    }
}
