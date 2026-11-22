import Foundation
import SwiftData

/// What a "new bowl" action did (splitting a note into a bowl, bundling inbox entries), so it can be taken back:
/// the bowl it made (or found), the entries it made, and where the entries it moved were before.
struct BowlChange {
    struct Moved {
        var noteID: UUID
        var projectIDs: [String]
        var filedAt: Date?
        var suggestedProjectIDs: [String]
    }

    var bowlID: UUID
    var bowlName: String
    /// The bowl is new: undo deletes it (when nothing else went into it meanwhile).
    var createdBowl: Bool
    /// Entries made by the action: undo deletes them.
    var createdNoteIDs: [UUID]
    /// Entries put into the bowl: undo puts them back where they were.
    var moved: [Moved]
    /// When it was done: entries it made and that were changed after it go to Recently Deleted on undo, not for good.
    var madeAt = Date()
}

extension BowlChange {
    /// "Bowl “Garden” made with 4 entries", "3 entries moved into “Garden”".
    var summary: String {
        let made = createdNoteIDs.count
        let movedCount = moved.count
        let verb = createdBowl ? "Bowl “\(bowlName)” made" : "Into bowl “\(bowlName)”"
        if made > 0 { return verb + " with \(made) " + (made == 1 ? "entry" : "entries") }
        return verb + ": \(movedCount) " + (movedCount == 1 ? "entry" : "entries")
    }
}

@MainActor
enum BowlMaking {
    /// The active bowl of that name (case and accents ignored), or a new one. A second bowl of the same name would
    /// only confuse; an archived one of that name is not reused.
    static func findOrCreate(_ name: String, in context: ModelContext) -> (bowl: NoteFolder, created: Bool)? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        // A bowl shared with me to view only takes nothing in: a bowl of my own is made instead.
        if let existing = all.first(where: {
            !$0.isArchived && !BowlSharing.shared.isReadOnly($0.id)
                && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return (existing, false)
        }
        guard let bowl = Projects.create(name, in: context) else { return nil }
        return (bowl, true)
    }

    /// Puts the note into the bowl (in place of the one it was in) and remembers where it was.
    static func move(_ note: Note, into bowl: NoteFolder, in context: ModelContext) -> BowlChange.Moved {
        let before = BowlChange.Moved(noteID: note.id, projectIDs: note.projectIDs, filedAt: note.filedAt, suggestedProjectIDs: note.suggestedProjectIDs)
        Inbox.file(note, into: Projects.key(bowl), in: context)
        return before
    }

    /// How long the way back is offered after the change (like the undo toast, a little longer: it is in the note).
    static let undoLifetime: Duration = .seconds(30)

    /// Takes the change back: the entries it made are deleted (to Recently Deleted when they were changed since),
    /// the moved ones go back, and a bowl it made is deleted when nothing else is in it now.
    static func undo(_ change: BowlChange, in context: ModelContext) {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = Set<UUID>()
        for id in change.createdNoteIDs {
            guard let note = byID[id] else { continue }
            if note.updatedAt.timeIntervalSince(change.madeAt) > 1 {
                // Worked on since: kept in Recently Deleted, where it can come back.
                if !note.isDeleted { NoteStore.trash(note, in: context) }
                kept.insert(id)
            } else {
                context.delete(note)
            }
        }
        for moved in change.moved {
            guard let note = byID[moved.noteID] else { continue }
            note.projectIDs = moved.projectIDs
            note.filedAt = moved.filedAt
            note.suggestedProjectIDs = moved.suggestedProjectIDs
            note.updatedAt = Date()
        }
        if change.createdBowl {
            let key = change.bowlID.uuidString
            let undone = Set(change.createdNoteIDs).subtracting(kept)
            let stillUsed = notes.contains { !undone.contains($0.id) && $0.projectIDs.contains(key) }
            let bowls = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
            if !stillUsed, let bowl = bowls.first(where: { $0.id == change.bowlID }) { context.delete(bowl) }
        }
        try? context.save()
    }
}
