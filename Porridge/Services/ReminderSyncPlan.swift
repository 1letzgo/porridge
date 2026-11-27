import Foundation

/// What the sync with Reminders remembers of a linked to-do on this device (`ReminderSyncState`): the reminder and the
/// fields as they were when both sides last agreed, the base of the three-way comparison.
struct ReminderBase: Codable, Equatable {
    /// `calendarItemExternalIdentifier`: the same on every device.
    var reminderID: String
    /// `calendarItemIdentifier` on this device.
    var localID: String?
    var fields: ReminderFields
    /// The bowl (`Projects.key`) or `inbox` whose list the reminder was in.
    var listKey: String
}

/// A reminder as it is now.
struct ReminderNow: Equatable {
    var fields: ReminderFields
    /// The bowl or `inbox` whose list it is in; nil: a list that takes no part (another account, an unlinked list).
    var listKey: String?
}

/// The to-do's side.
enum ReminderPorridgeSide: Equatable {
    /// A to-do (open or done), with the list it belongs in.
    case todo(ReminderFields, listKey: String)
    /// In Recently Deleted.
    case trashed
    /// Turned back into a note.
    case notTodo
    /// Not in the store (deleted for good, or not there at all).
    case missing
}

enum ReminderSyncDirection: Equatable {
    /// Both ways (from stage 3 on).
    case both
    /// Porridge writes into Reminders only; what changed in Reminders is not taken over (stage 2).
    case toReminders
}

/// Why the sync stopped by itself. Nothing is deleted while it is paused.
enum ReminderPause: Codable, Equatable {
    /// The notes could not be opened (`AppContainer.storeError`).
    case storeUnavailable
    /// Reminders has no default list or no lists at all (no account).
    case noAccount
    /// There is no bowl at all, while lists are linked to bowls.
    case noBowls
    /// Several linked lists disappeared at once.
    case listsGone(Int)
    /// Many linked open reminders disappeared at once.
    case remindersGone(Int)
    /// Many linked to-dos are gone from Porridge at once.
    case todosMissing(Int)

    /// The status line's words after "Paused: ".
    var message: String {
        switch self {
        case .storeUnavailable: String(localized: "your notes could not be opened")
        case .noAccount: String(localized: "Reminders has no lists on this device")
        case .noBowls: String(localized: "no bowls were found")
        case .listsGone(let n): String(localized: "\(n) lists disappeared from Reminders")
        case .remindersGone(let n): String(localized: "\(n) reminders disappeared from Reminders")
        case .todosMissing(let n): String(localized: "\(n) to-dos are missing in Porridge")
        }
    }

    /// Paused over a count of things gone: "Resume" goes on with them once. The others hold until their cause is gone.
    var canResume: Bool {
        switch self {
        case .listsGone, .remindersGone, .todosMissing: true
        case .storeUnavailable, .noAccount, .noBowls: false
        }
    }
}

/// The three-way sync of one to-do with its reminder: what changed on which side since the base, who wins, and what
/// is written where. Porridge wins where both changed, except that ticks of subtasks made in Reminders join
/// (`Todos.mergeTicks`). Pure: the coordinator (`ReminderSyncEngine`) carries the decisions out.
enum ReminderSyncPlan {
    struct Input: Equatable {
        var porridge: ReminderPorridgeSide
        /// The reminder found (by the base, `@reminder` or its URL); nil: none.
        var reminder: ReminderNow?
        var base: ReminderBase?
        /// The list of the to-do's bowl is known on this device.
        var targetReady = true
        /// The to-do's bowl does not sync now: archived, its list unlinked, or the bowl not in the store.
        var targetPaused = false
        /// A bowl shared with me to view only: Porridge always wins, nothing comes back.
        var porridgeWins = false
        /// The to-do names a reminder (`@reminder`, made by another device) that is not here (yet).
        var waitForOtherDevice = false
        var direction: ReminderSyncDirection = .both
    }

    /// Changes for the to-do (the way back, stage 3).
    struct PorridgeChange: Equatable {
        var title: String?
        /// Ticks made in Reminders: merge them into the to-do's text (`Todos.mergeTicks(base:winner:loser:)` with the
        /// to-do's text as winner). Both in the form of a to-do's text.
        var ticks: Ticks?
        /// The text as Reminders has it, where only Reminders changed it.
        var text: String?
        var isDone: Bool?
        var dueChanged = false
        var dueDay: String?
        /// Into this bowl (or `inbox`: out of its bowl).
        var listKey: String?

        struct Ticks: Equatable {
            var base: String
            var theirs: String
        }
    }

    struct Update: Equatable {
        /// The reminder's fields when they change.
        var toReminder: ReminderFields?
        /// Into the list of this bowl (or `inbox`).
        var moveTo: String?
        var toPorridge: PorridgeChange?
        /// The new base.
        var base: ReminderFields
        var baseListKey: String
    }

    enum Decision: Equatable {
        /// Both sides agree with the base.
        case nothing
        /// The to-do's bowl does not sync now: nothing is changed on either side.
        case skip
        /// The list is not there yet, or another device's reminder is not here yet.
        case wait
        /// A new reminder in the list of this bowl (or `inbox`).
        case create(ReminderFields, listKey: String)
        case update(Update)
        /// The to-do went to Recently Deleted, was turned back into a note, or is gone (`missingNote`).
        case deleteReminder(missingNote: Bool)
        /// The open reminder was deleted in Reminders: the to-do goes to Recently Deleted (stage 3).
        case trashTodo
        /// The done reminder was deleted in Reminders: the to-do stays, the link goes.
        case unlink
        /// Neither side is there any more: the base goes.
        case forget
    }

    static func decide(_ input: Input) -> Decision {
        switch input.porridge {
        case .missing:
            if input.targetPaused, input.reminder != nil { return .skip }
            if input.reminder != nil { return .deleteReminder(missingNote: true) }
            return input.base == nil ? .nothing : .forget
        case .trashed, .notTodo:
            // In an archived bowl nothing is deleted either.
            if input.targetPaused, input.reminder != nil { return .skip }
            if input.reminder != nil { return .deleteReminder(missingNote: false) }
            return input.base == nil ? .nothing : .forget
        case .todo(let fields, let listKey):
            if input.targetPaused { return .skip }
            guard let reminder = input.reminder else {
                if let base = input.base {
                    // The reminder disappeared from Reminders.
                    if base.fields.isDone || fields.isDone { return .unlink }
                    if input.porridgeWins { return input.targetReady ? .create(fields, listKey: listKey) : .wait }
                    return .trashTodo
                }
                if input.waitForOtherDevice { return .wait }
                // Only open to-dos are brought into Reminders; done ones stay as they are.
                guard !fields.isDone else { return .nothing }
                return input.targetReady ? .create(fields, listKey: listKey) : .wait
            }
            return merge(fields, listKey: listKey, reminder: reminder, input: input)
        }
    }

    private static func merge(_ p: ReminderFields, listKey: String, reminder r: ReminderNow, input: Input) -> Decision {
        let pull = input.direction == .both && !input.porridgeWins
        guard let base = input.base else {
            // Linked for the first time here (found by `@reminder` or its URL): Porridge's fields hold.
            let move = r.listKey != listKey && input.targetReady ? listKey : nil
            let update = Update(
                toReminder: r.fields == p ? nil : p, moveTo: move, toPorridge: nil,
                base: p, baseListKey: move == nil ? (r.listKey ?? listKey) : listKey
            )
            return .update(update)
        }
        let b = base.fields
        var change = PorridgeChange()

        let title = resolve(p.title, r.fields.title, b.title, pull: pull, porridgeWins: input.porridgeWins)
        if let value = title.porridge { change.title = value }

        // The notes: where both changed, Porridge's text with the ticks made in Reminders.
        var notes = resolve(p.notes, r.fields.notes, b.notes, pull: pull, porridgeWins: input.porridgeWins)
        if let value = notes.porridge { change.text = ReminderMapping.text(fromNotes: value) }
        if pull, p.notes != r.fields.notes, p.notes != b.notes, r.fields.notes != b.notes {
            let baseText = ReminderMapping.text(fromNotes: b.notes)
            let theirs = ReminderMapping.text(fromNotes: r.fields.notes)
            let merged = ReminderMapping.notes(fromText: Todos.mergeTicks(
                base: baseText, winner: ReminderMapping.text(fromNotes: p.notes), loser: theirs
            ))
            if merged != p.notes {
                change.ticks = .init(base: baseText, theirs: theirs)
                notes = (merged, nil, merged)
            }
        }

        let done = resolve(p.isDone, r.fields.isDone, b.isDone, pull: pull, porridgeWins: input.porridgeWins)
        if let value = done.porridge { change.isDone = value }
        let due = resolve(p.dueDay, r.fields.dueDay, b.dueDay, pull: pull, porridgeWins: input.porridgeWins)
        if let value = due.porridge {
            change.dueChanged = true
            change.dueDay = value
        }

        // The list: a reminder in a list that takes no part counts as unchanged there.
        var moveTo: String?
        var baseListKey = base.listKey
        if let theirs = r.listKey {
            let list = resolve(listKey, theirs, base.listKey, pull: pull, porridgeWins: input.porridgeWins)
            if let value = list.porridge { change.listKey = value }
            if list.reminder != theirs, input.targetReady { moveTo = list.reminder }
            baseListKey = moveTo == nil && list.reminder != theirs ? base.listKey : list.base
        } else if listKey != base.listKey, input.targetReady {
            moveTo = listKey
            baseListKey = listKey
        }

        let fields = ReminderFields(title: title.reminder, notes: notes.reminder, isDone: done.reminder, dueDay: due.reminder)
        let newBase = ReminderFields(title: title.base, notes: notes.base, isDone: done.base, dueDay: due.base)
        let update = Update(
            toReminder: fields == r.fields ? nil : fields,
            moveTo: moveTo,
            toPorridge: change == PorridgeChange() ? nil : change,
            base: newBase,
            baseListKey: baseListKey
        )
        if update.toReminder == nil, update.moveTo == nil, update.toPorridge == nil, newBase == b, baseListKey == base.listKey {
            return .nothing
        }
        return .update(update)
    }

    /// One field: what the reminder gets, what the to-do gets (nil: nothing), and the new base.
    /// Only Porridge changed, or both: Porridge's. Only Reminders changed: taken over (`pull`), kept as base for later
    /// otherwise (`toReminders`: the reminder keeps its value, the base stays), or overwritten (`porridgeWins`).
    static func resolve<T: Equatable>(_ p: T, _ r: T, _ b: T, pull: Bool, porridgeWins: Bool) -> (reminder: T, porridge: T?, base: T) {
        if p == r { return (p, nil, p) }
        if r == b || p != b || porridgeWins { return (p, nil, p) }
        return pull ? (r, r, r) : (r, nil, b)
    }

    // MARK: Brakes

    /// More than this many at once looks like a fault (a store that did not load, an account that went), not a choice.
    static let massLimit = 5

    /// Stops the run when many open reminders disappeared at once (their to-dos would go to Recently Deleted) or many
    /// linked to-dos are gone from Porridge (their reminders would be deleted). nil: go on.
    static func brake(_ decisions: [Decision], limit: Int = massLimit) -> ReminderPause? {
        let gone = decisions.filter { $0 == .trashTodo }.count
        if gone >= limit { return .remindersGone(gone) }
        let missing = decisions.filter { $0 == .deleteReminder(missingNote: true) }.count
        if missing >= limit { return .todosMissing(missing) }
        return nil
    }

    // MARK: Duplicates

    struct Candidate: Equatable {
        var id: String
        var created: Date?
    }

    /// Several reminders point to the same to-do (two devices each made one at the same time): the one the to-do names
    /// (`@reminder`, settled by the sync of the notes) stays, else the oldest (then the smallest id); the others go.
    static func duplicates(_ candidates: [Candidate], preferred: String?) -> (keep: String, remove: [String])? {
        guard candidates.count > 1 else { return nil }
        let keep = candidates.first { $0.id == preferred }
            ?? candidates.min { ($0.created ?? .distantFuture, $0.id) < ($1.created ?? .distantFuture, $1.id) }!
        return (keep.id, candidates.map(\.id).filter { $0 != keep.id })
    }
}
