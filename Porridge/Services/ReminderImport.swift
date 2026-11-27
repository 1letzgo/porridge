import Foundation
import SwiftData

// MARK: - What the first import would bring

/// What a first import from Reminders would bring (shown before it, once per device: "Bring Reminders into Porridge?").
struct ReminderImportPreview: Equatable {
    struct Entry: Equatable, Identifiable {
        enum Kind: Equatable {
            /// The default list: its reminders go to the Inbox.
            case inbox
            /// The list of a bowl that is there.
            case bowl(key: String, name: String)
            /// A list that becomes a bowl.
            case newBowl
        }

        /// The list (`calendarIdentifier`).
        var listID: String
        var title: String
        var kind: Kind
        /// Open reminders in it that no to-do has yet.
        var openCount: Int

        var id: String { listID }
    }

    var entries: [Entry]

    /// "Creates 4 bowls from your lists and adds 37 open reminders as to-dos. 12 of them go to the Inbox." for the
    /// lists chosen.
    func summary(selected: Set<String>) -> String {
        let chosen = entries.filter { selected.contains($0.listID) }
        let bowls = chosen.filter { $0.kind == .newBowl }.count
        let todos = chosen.reduce(0) { $0 + $1.openCount }
        let inbox = chosen.filter { $0.kind == .inbox }.reduce(0) { $0 + $1.openCount }
        guard !chosen.isEmpty else { return String(localized: "Nothing is brought in. Your to-dos still go into Reminders.") }
        let reminderWords = todos == 1 ? String(localized: "1 open reminder") : String(localized: "\(todos) open reminders")
        var line: String
        if bowls > 0 {
            let bowlWords = bowls == 1 ? String(localized: "1 bowl") : String(localized: "\(bowls) bowls")
            line = todos > 0
                ? String(localized: "Creates \(bowlWords) from your lists and adds \(reminderWords) as to-dos.")
                : String(localized: "Creates \(bowlWords) from your lists.")
        } else {
            line = todos > 0 ? String(localized: "Adds \(reminderWords) as to-dos.") : String(localized: "Nothing to add yet.")
        }
        if inbox > 0 {
            line += " " + (inbox == todos
                ? String(localized: "They go to the Inbox.")
                : inbox == 1 ? String(localized: "1 of them goes to the Inbox.") : String(localized: "\(inbox) of them go to the Inbox."))
        }
        return line
    }

    /// The line under a list's switch: "12 open reminders · Inbox", "New bowl · 3 open reminders".
    static func detail(_ entry: Entry) -> String {
        let count = entry.openCount == 1 ? String(localized: "1 open reminder") : String(localized: "\(entry.openCount) open reminders")
        switch entry.kind {
        case .inbox: return String(localized: "To the Inbox") + " · " + count
        case .bowl(_, let name): return String(localized: "Into the bowl “\(name)”") + " · " + count
        case .newBowl: return String(localized: "New bowl") + " · " + count
        }
    }
}

/// A list in Settings › Reminders › Lists: what it is to Porridge, with its switch.
struct ReminderListRow: Equatable, Identifiable {
    enum Target: Equatable {
        /// The default list (the Inbox).
        case inbox
        /// A bowl's list.
        case bowl(String)
        /// A list that is no bowl (by its title).
        case list(String)
    }

    /// The list (`calendarIdentifier`).
    var id: String
    var title: String
    /// "Inbox", "Bowl “Work”", "Becomes a bowl", "Not synced".
    var detail: String
    var isOn: Bool
    var target: Target
}

// MARK: - The mark of an imported to-do

extension Note {
    /// The reminder an imported to-do was made from (its `calendarItemExternalIdentifier`), kept in
    /// `todoSuggestionsRaw` under `@fromReminder` (no field of its own). Two devices that made a to-do of the same
    /// reminder at once find each other's by it (`ReminderPull.duplicates`).
    var fromReminder: String? {
        get {
            guard let raw = todoSuggestionsRaw, raw.contains(ReminderPull.fromKey) else { return nil }
            return TodoSuggestions.states(raw)[ReminderPull.fromKey]
        }
        set {
            guard fromReminder != newValue else { return }
            let wasNil = todoSuggestionsRaw == nil
            var all = TodoSuggestions.states(todoSuggestionsRaw)
            all[ReminderPull.fromKey] = newValue
            // No summary suggestions count as offered (as `reminderLink`).
            if newValue != nil, wasNil { all[InboxSnooze.unofferedKey] = "1" }
            todoSuggestionsRaw = all.isEmpty ? nil : TodoSuggestions.encode(all)
        }
    }
}

// MARK: - Into Porridge

/// The way back: what changed in Reminders taken into a to-do (through the same calls as an edit in the app), and new
/// reminders made into to-dos.
@MainActor
enum ReminderPull {
    nonisolated static let fromKey = "@fromReminder"

    /// Takes what changed in Reminders into the to-do. Order: title, text (or the ticks), due day, done (done ticks
    /// every subtask; a repeating to-do moves on, but only when the reminder ticked is the round it is on now), bowl.
    /// `reminderDue`: the due day the reminder has now.
    static func apply(_ change: ReminderSyncPlan.PorridgeChange, reminderDue: String?, to note: Note, in context: ModelContext, now: Date = Date()) {
        if change.title != nil || change.text != nil || change.ticks != nil { splitTitle(note) }
        var edited = false
        if let title = change.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, note.title != trimmed {
                note.title = trimmed
                note.titleIsCustom = true
                edited = true
            }
        }
        if let text = change.text, note.text != text {
            note.text = text
            edited = true
        } else if let ticks = change.ticks {
            let merged = Todos.mergeTicks(base: ticks.base, winner: note.text, loser: ticks.theirs)
            if merged != note.text {
                note.text = merged
                edited = true
            }
        }
        if edited {
            note.updatedAt = now
            try? context.save()
        }
        if change.dueChanged { Todos.setDue(change.dueDay, note, in: context) }
        if let done = change.isDone {
            if done, note.todoRepeat != nil {
                // Another device moved it on already: the reminder of the round before is not this round.
                if note.todoDue == reminderDue { Todos.setDone(true, note, in: context) }
            } else {
                Todos.setDone(done, note, in: context)
            }
        }
        if let key = change.listKey, key != ReminderMapping.listKey(of: note) {
            if key == ReminderMapping.inboxKey {
                note.projectIDs = []
                note.updatedAt = now
                try? context.save()
            } else {
                Inbox.file(note, into: key, in: context)
            }
        }
    }

    /// A to-do without a title of its own shows its first line as title (`ReminderMapping.fields`): before a change
    /// from Reminders that line becomes the title, so that the text the reminder has is the rest.
    static func splitTitle(_ note: Note) {
        guard note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let fields = ReminderMapping.fields(of: note)
        var lines = note.text.components(separatedBy: "\n")
        // A first line that is a subtask stays a subtask (as in `ReminderMapping.fields`).
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           !ReminderMapping.notes(fromText: lines[first]).hasPrefix("☐"), !ReminderMapping.notes(fromText: lines[first]).hasPrefix("☑") {
            lines.remove(at: first)
            note.text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        }
        note.title = fields.title
        note.titleIsCustom = true
    }

    /// A new to-do of a reminder (not inserted yet): an ordinary entry as the app makes a to-do (channel note, open),
    /// with the reminder's title, notes (checklist lines become subtasks; a web address the reminder had is kept at
    /// the end) and due day, created when the reminder was, in `bowl` or the Inbox. It gets no suggestions.
    static func makeTodo(id: UUID, from item: ReminderItem, bowl: String?, now: Date = Date()) -> Note {
        let note = Note()
        note.id = id
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        note.title = title.isEmpty ? String(localized: "To-do") : title
        note.titleIsCustom = true
        var text = ReminderMapping.text(fromNotes: item.notes).trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = item.url, ReminderMapping.noteID(from: url) == nil {
            text += (text.isEmpty ? "" : "\n\n") + url.absoluteString
        }
        note.text = text
        note.source = .note
        note.todoState = .open
        note.todoDueDay = ReminderMapping.dueDay(from: item.due)
        note.createdAt = min(item.created ?? now, now)
        note.updatedAt = now
        if let bowl {
            note.projectIDs = [bowl]
            note.filedAt = now
        }
        return note
    }

    /// Several to-dos made of one reminder (two devices took it in at the same time): the oldest stays (then the
    /// smallest id), the others go. The same on every device. Groups by `fromReminder`.
    static func duplicates(_ notes: [Note]) -> [(keep: Note, remove: [Note])] {
        var groups: [String: [Note]] = [:]
        for note in notes where !note.isDeleted && note.isTodo {
            guard let from = note.fromReminder, !from.isEmpty else { continue }
            groups[from, default: []].append(note)
        }
        return groups.keys.sorted().compactMap { key in
            let group = groups[key]!
            guard group.count > 1 else { return nil }
            let keep = group.min { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }!
            return (keep, group.filter { $0.id != keep.id })
        }
    }
}
