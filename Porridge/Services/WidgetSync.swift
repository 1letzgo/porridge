import Foundation
import SwiftData
#if os(iOS)
import WidgetKit
#endif

/// Keeps the widgets' copy of the notes (`WidgetSnapshot`) and takes in the to-dos ticked in a widget
/// (`WidgetStore.pendingCompletions`).
@MainActor
enum WidgetSync {
    /// What the widgets show, made from every note.
    static func snapshot(
        _ notes: [Note], isReadOnly custom: ((Note) -> Bool)? = nil, now: Date = Date()
    ) -> WidgetSnapshot {
        let isReadOnly = custom ?? { BowlSharing.shared.isReadOnly($0) }
        let live = notes.filter { !$0.isDeleted }
        // Put away for later: not in the inbox now (`Inbox.notes`), but the widgets bring it back on time.
        let waiting = Inbox.notes(live, now: now)
        let later = InboxSnooze.snoozed(live, now: now)
        let open = Todos.byDue(notes.filter { $0.isTodo && !$0.isDone && !$0.isDeleted })
        return WidgetSnapshot(
            generatedAt: now,
            inboxCount: waiting.count,
            inbox: waiting.prefix(WidgetSnapshot.inboxLimit).map(entry),
            later: later.prefix(WidgetSnapshot.laterLimit).compactMap { note in
                note.snoozedUntil.map { WidgetSnapshot.Later(entry: entry(note), until: $0) }
            },
            openTodoCount: open.count,
            todos: open.prefix(WidgetSnapshot.todoLimit).map {
                WidgetSnapshot.Todo(
                    id: $0.id.uuidString, title: $0.displayTitle, due: $0.todoDue,
                    isRepeating: $0.todoRepeat != nil, isReadOnly: isReadOnly($0)
                )
            }
        )
    }

    private static func entry(_ note: Note) -> WidgetSnapshot.Entry {
        WidgetSnapshot.Entry(id: note.id.uuidString, title: note.displayTitle, symbol: note.kindSymbol, createdAt: note.createdAt)
    }

    /// Writes the snapshot and reloads the widgets when it changed.
    static func publish(_ notes: [Note]) {
        guard WidgetStore.write(snapshot(notes)) else { return }
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Applies one tick from a widget. Not applied: the entry is gone, no open to-do, in a bowl I may only view, or a
    /// repeating to-do that has moved on since the widget showed it (its due day differs).
    @discardableResult
    static func apply(
        _ completion: WidgetStore.Completion, in context: ModelContext,
        isReadOnly custom: ((Note) -> Bool)? = nil
    ) -> Bool {
        let isReadOnly = custom ?? { BowlSharing.shared.isReadOnly($0) }
        guard let id = UUID(uuidString: completion.id) else { return false }
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let note = try? context.fetch(descriptor).first,
              !note.isDeleted, note.isTodo, !note.isDone, !isReadOnly(note) else { return false }
        if note.todoRepeat != nil, note.todoDue != completion.due { return false }
        // Changed after the tick (reopened, edited on another device): the tick was for what it was before.
        if note.todoRepeat == nil, note.updatedAt > completion.date { return false }
        Todos.setDone(true, note, in: context)
        return note.isDone || note.todoRepeat != nil
    }

    /// Applies every queued tick and empties the queue (ticks that cannot be applied are dropped, not kept).
    /// Returns how many were applied.
    @discardableResult
    static func applyPending(
        in context: ModelContext, isReadOnly custom: ((Note) -> Bool)? = nil
    ) -> Int {
        let pending = WidgetStore.pendingCompletions()
        guard !pending.isEmpty else { return 0 }
        let applied = pending.filter { apply($0, in: context, isReadOnly: custom) }.count
        WidgetStore.removeCompletions(pending)
        #if os(iOS)
        // A tick that could not be applied comes back into the widget's list.
        if applied < pending.count { WidgetCenter.shared.reloadAllTimelines() }
        #endif
        return applied
    }

    /// Text spoken or typed into a shortcut: it waits in the share inbox like anything shared, and becomes a note
    /// of its own (not a "shared" one) in the inbox when the app takes it in (`ShareImport`).
    static func addToInbox(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var entry = ShareInbox.Entry(text: text)
        entry.source = ShareInbox.Entry.ownWords
        try ShareInbox.add(entry)
    }
}
