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

        var errorDescription: String? {
            switch self {
            case .entryGone: "The entry is no longer there."
            case .bowlGone: "The bowl is no longer there."
            case .emptyName: "A name is missing."
            case .bowlExists(let name): "A bowl named “\(name)” already exists."
            case .cannotBeTodo: "Links, saved files and meetings cannot be to-dos."
            case .notADocument: "This entry is not a document."
            case .nothingToChange: "Nothing to change: it already is that way."
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
                && now.text == text && now.labels == labels && now.attachmentsData == attachmentsData
        }

        func restore(on note: Note) {
            note.projectIDs = projectIDs
            note.filedAt = filedAt
            note.suggestedProjectIDs = suggestedProjectIDs
            note.todoStateRaw = todoStateRaw
            note.todoDoneAt = todoDoneAt
            note.todoDueDay = todoDueDay
            note.text = text
            note.labels = labels
            if note.attachmentsData != attachmentsData { note.attachmentsData = attachmentsData }
            note.updatedAt = updatedAt
        }
    }

    /// The way back from one or several changes; taken back newest first.
    struct Undo {
        enum Step {
            case restore(Snapshot)
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
        return Undo(steps: [.restore(before)])
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
        return Undo(steps: [.restore(before)])
    }

    /// Adds and removes tags (the tag field; `#words` written in the text stay where they are).
    @discardableResult
    static func setTags(_ note: Note, add: [String], remove: [String], in context: ModelContext, now: Date = Date()) throws -> Undo {
        guard !note.isDeleted else { throw Failure.entryGone }
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
        return Undo(steps: [.restore(before)])
    }

    /// Corrects what a document is, the way an edit by hand does (`Documents.set`): reading it again never replaces it.
    @discardableResult
    static func setDocumentInfo(_ note: Note, _ change: DocumentChange, in context: ModelContext) throws -> Undo {
        guard !note.isDeleted else { throw Failure.entryGone }
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
        return Undo(steps: [.restore(before)])
    }

    /// A new note (or to-do) with this title and text, in a bowl or the Inbox.
    static func createNote(
        title: String, text: String, bowl: String? = nil, todo: Bool = false, due: String? = nil,
        in context: ModelContext, now: Date = Date()
    ) throws -> (note: Note, undo: Undo) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !text.isEmpty else { throw Failure.emptyName }
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

    // MARK: Taking back

    /// Takes the changes back, newest first.
    static func undo(_ undo: Undo, in context: ModelContext) {
        for step in undo.steps.reversed() {
            switch step {
            case .restore(let snapshot):
                let id = snapshot.noteID
                if let note = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })))?.first {
                    snapshot.restore(on: note)
                }
            case .removeNote(let id):
                if let note = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })))?.first {
                    context.delete(note)
                }
            case .removeBowl(let id):
                guard let bowl = folder(id, in: context) else { continue }
                let key = Projects.key(bowl)
                let used = ((try? context.fetch(FetchDescriptor<Note>())) ?? []).contains { $0.projectIDs.contains(key) }
                if !used { context.delete(bowl) }
            }
        }
        try? context.save()
    }
}
