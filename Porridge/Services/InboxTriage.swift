import Foundation
import SwiftData

/// Going through the Inbox one entry at a time (iPhone Triage, the Mac's triage keys): what is new, in the Inbox's
/// order, taken when triage starts. An entry that left the Inbox meanwhile (filed, later, deleted, on another device)
/// is passed over; one that stays (skipped, a to-do done) is passed by moving on. Pure, so it is testable.
@MainActor
struct InboxTriage {
    /// The entries at the start, newest first (`Inbox.notes`).
    private(set) var ids: [UUID]
    /// Where triage stands in `ids`.
    private(set) var position = 0

    init(notes: [Note], now: Date = Date()) {
        ids = Inbox.notes(notes, now: now).map(\.id)
    }

    var total: Int { ids.count }

    /// The entry in front: the first from `position` on that still waits in the Inbox, with its index; nil when all
    /// are through.
    func current(in notes: [Note], now: Date = Date()) -> (note: Note, index: Int)? {
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var index = position
        while index < ids.count {
            if let note = byID[ids[index]], note.isWaitingInInbox(now: now) { return (note, index) }
            index += 1
        }
        return nil
    }

    /// The next entries after the one in front ("Next" under the card).
    func upcoming(in notes: [Note], count: Int = 2, now: Date = Date()) -> [Note] {
        guard let current = current(in: notes, now: now) else { return [] }
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids[(current.index + 1)...].lazy.compactMap { byID[$0] }.filter { $0.isWaitingInInbox(now: now) }.prefix(count).map { $0 }
    }

    /// "Entry 2 of 12": the number of the entry in front (counted from 1).
    func number(in notes: [Note], now: Date = Date()) -> Int? {
        current(in: notes, now: now).map { $0.index + 1 }
    }

    /// On to the entry after the one in front (Skip, a to-do done, or after it was filed, put away or deleted).
    mutating func advance(in notes: [Note], now: Date = Date()) {
        if let current = current(in: notes, now: now) {
            position = current.index + 1
        } else {
            position = ids.count
        }
    }

    func isFinished(in notes: [Note], now: Date = Date()) -> Bool {
        current(in: notes, now: now) == nil
    }

    // MARK: Actions

    /// The bowl "File" puts an entry into: its first suggestion that can take it (`EntryMeta.suggestion`).
    static func suggestion(for note: Note, bowls: [NoteFolder]) -> NoteFolder? {
        EntryMeta.suggestion(for: note, bowls: bowls)
    }

    /// "File": into the suggested bowl, with the one undo toast. Returns false when there is none (the bowl list
    /// opens then).
    @discardableResult
    static func file(_ note: Note, bowls: [NoteFolder], in context: ModelContext) -> Bool {
        guard let bowl = suggestion(for: note, bowls: bowls) else { return false }
        Undoable.move([note], toBowl: Projects.key(bowl), named: bowl.name, in: context)
        return true
    }
}
