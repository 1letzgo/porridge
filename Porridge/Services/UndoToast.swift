import Foundation
import Observation
import SwiftData

/// The one undo toast of the app (iOS and Mac): after something was deleted, moved or cleared, a short line with
/// "Undo" stays for a few seconds. Only the latest action can be undone this way; a new one replaces the toast.
/// Where a window has an `UndoManager` (the Mac), the same action is registered there too, so ⌘Z undoes it.
@MainActor
@Observable
final class UndoToast {
    static let shared = UndoToast()

    /// How long a toast stays.
    static let duration: TimeInterval = 8

    struct Offer: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let systemImage: String

        static func == (a: Offer, b: Offer) -> Bool { a.id == b.id }
    }

    private(set) var current: Offer?

    @ObservationIgnored private var undoAction: (() -> Void)?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// The manager the current action was also registered with, and its token there.
    @ObservationIgnored private weak var undoManager: UndoManager?
    @ObservationIgnored private var token: UndoToken?
    /// The Mac gives the undo manager of the window in front; iOS has none (the toast is the way back).
    @ObservationIgnored var undoManagerProvider: (@MainActor () -> UndoManager?)?

    private final class UndoToken: NSObject {}

    init() {}

    /// Shows the toast. `undo` runs once at most: from the toast, or from the undo manager.
    func offer(_ message: String, systemImage: String = "arrow.uturn.backward", undo: @escaping () -> Void) {
        retire()
        let offer = Offer(message: message, systemImage: systemImage)
        current = offer
        undoAction = undo
        if let manager = undoManagerProvider?() {
            let token = UndoToken()
            manager.registerUndo(withTarget: token) { [weak self] _ in
                MainActor.assumeIsolated { self?.runUndo(fromManager: true) }
            }
            manager.setActionName(message)
            self.token = token
            undoManager = manager
        }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duration))
            guard !Task.isCancelled else { return }
            self?.expire(offer.id)
        }
    }

    /// The toast's "Undo".
    func undo() {
        runUndo(fromManager: false)
    }

    /// Closes the toast; the action stays done (⌘Z still undoes it on the Mac).
    func dismiss() {
        expiry?.cancel()
        expiry = nil
        current = nil
    }

    /// Keeps the toast while the pointer rests on it (the Mac), then gives it its time again.
    func hold(_ held: Bool) {
        guard let offer = current else { return }
        expiry?.cancel()
        expiry = nil
        guard !held else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.expire(offer.id)
        }
    }

    private func expire(_ id: UUID) {
        guard current?.id == id else { return }
        current = nil
        expiry = nil
    }

    private func runUndo(fromManager: Bool) {
        let action = undoAction
        undoAction = nil
        if !fromManager, let token { undoManager?.removeAllActions(withTarget: token) }
        token = nil
        undoManager = nil
        dismiss()
        action?()
    }

    /// A new toast replaces the old one: the old action is not offered on the toast any more, but stays in the
    /// undo manager where it was registered.
    private func retire() {
        expiry?.cancel()
        expiry = nil
        undoAction = nil
        token = nil
        undoManager = nil
        current = nil
    }
}

/// What of a note an undoable action may change, taken before and after it. Undo puts back only the fields the
/// action changed, so an edit made in between (on this device or another) is kept.
struct NoteSnapshot: Equatable {
    var projectIDs: [String]
    var filedAt: Date?
    var suggestedProjectIDs: [String]
    var deletedAt: Date?
    var isPinned: Bool
    var labels: [String]
    var attachmentsData: Data?
    var todoStateRaw: String?
    var todoDoneAt: Date?
    var todoDueDay: String?
    /// Holds the repeat rule of a to-do (`Note.todoRepeat`).
    var todoSuggestionsRaw: String?

    init(_ note: Note) {
        projectIDs = note.projectIDs
        filedAt = note.filedAt
        suggestedProjectIDs = note.suggestedProjectIDs
        deletedAt = note.deletedAt
        isPinned = note.isPinned
        labels = note.labels
        attachmentsData = note.attachmentsData
        todoStateRaw = note.todoStateRaw
        todoDoneAt = note.todoDoneAt
        todoDueDay = note.todoDueDay
        todoSuggestionsRaw = note.todoSuggestionsRaw
    }

    /// Writes back the fields that differ between `before` (self) and `after` onto the note. Returns whether
    /// anything changed.
    @discardableResult
    func restore(onto note: Note, changedFrom after: NoteSnapshot) -> Bool {
        var changed = false
        func put<T: Equatable>(_ key: ReferenceWritableKeyPath<Note, T>, _ before: T, _ later: T) {
            guard before != later, note[keyPath: key] != before else { return }
            note[keyPath: key] = before
            changed = true
        }
        put(\.projectIDs, projectIDs, after.projectIDs)
        put(\.filedAt, filedAt, after.filedAt)
        put(\.suggestedProjectIDs, suggestedProjectIDs, after.suggestedProjectIDs)
        put(\.deletedAt, deletedAt, after.deletedAt)
        put(\.isPinned, isPinned, after.isPinned)
        put(\.labels, labels, after.labels)
        put(\.attachmentsData, attachmentsData, after.attachmentsData)
        put(\.todoStateRaw, todoStateRaw, after.todoStateRaw)
        put(\.todoDoneAt, todoDoneAt, after.todoDoneAt)
        put(\.todoDueDay, todoDueDay, after.todoDueDay)
        put(\.todoSuggestionsRaw, todoSuggestionsRaw, after.todoSuggestionsRaw)
        return changed
    }
}

/// Actions on notes that can be taken back from the toast: delete, move to a bowl or the inbox, changes to several
/// at once, clearing what a document is, removing a tag. Each one does what the plain call did before and then
/// offers its undo.
@MainActor
enum Undoable {
    /// Runs `change` on `notes` and offers to undo it when it changed anything.
    static func run(_ message: String, systemImage: String = "arrow.uturn.backward", notes: [Note], in context: ModelContext,
                    toast: UndoToast = .shared, _ change: () -> Void) {
        let before = notes.map { ($0, NoteSnapshot($0)) }
        change()
        let changes = before.compactMap { note, old -> (Note, NoteSnapshot, NoteSnapshot)? in
            let new = NoteSnapshot(note)
            return new == old ? nil : (note, old, new)
        }
        guard !changes.isEmpty else { return }
        toast.offer(message, systemImage: systemImage) {
            let now = Date()
            var any = false
            for (note, old, new) in changes where note.modelContext != nil {
                if old.restore(onto: note, changedFrom: new) {
                    note.updatedAt = now
                    any = true
                }
            }
            if any { try? context.save() }
        }
    }

    /// Moves notes to Recently Deleted.
    static func trash(_ notes: [Note], in context: ModelContext) {
        let saved = notes.filter { $0.modelContext != nil && !$0.isDeleted }
        guard !saved.isEmpty else { return }
        run(deletedMessage(saved), systemImage: "trash", notes: saved, in: context) {
            saved.forEach { NoteStore.trash($0, in: context) }
        }
    }

    /// Into one bowl (in place of the one they are in), or back to the inbox (nil).
    static func move(_ notes: [Note], toBowl bowl: String?, named name: String?, in context: ModelContext) {
        // Not into a bowl shared with me to view only, and not out of one.
        if let bowl, BowlSharing.shared.isReadOnly(UUID(uuidString: bowl)) { return }
        let notes = notes.filter { !BowlSharing.shared.isReadOnly($0) }
        guard !notes.isEmpty else { return }
        run(movedMessage(count: notes.count, to: name), systemImage: bowl == nil ? "tray" : "folder", notes: notes, in: context) {
            if let bowl, notes.count == 1, let note = notes.first {
                Inbox.file(note, into: bowl, in: context)
            } else {
                Documents.apply(.move(toBowl: bowl), to: notes, in: context)
            }
        }
    }

    /// Takes the note out of the bowl; out of its only one, it is back in the inbox.
    static func remove(_ project: NoteFolder, from note: Note, in context: ModelContext) {
        guard !BowlSharing.shared.isReadOnly(project.id), !BowlSharing.shared.isReadOnly(note) else { return }
        run(String(localized: "Removed from “\(project.name)”"), systemImage: "tray", notes: [note], in: context) {
            Projects.remove(project, from: note, in: context)
        }
    }

    /// The bowl menu's toggle: into the bowl, or out of it when it is in it already.
    static func toggle(_ project: NoteFolder, on note: Note, in context: ModelContext) {
        guard !BowlSharing.shared.isReadOnly(project.id), !BowlSharing.shared.isReadOnly(note) else { return }
        if note.projectIDs.contains(Projects.key(project)) {
            remove(project, from: note, in: context)
        } else {
            move([note], toBowl: Projects.key(project), named: project.name, in: context)
        }
    }

    /// A change for several selected entries at once (`Documents.apply`).
    static func apply(_ change: Documents.BulkChange, to notes: [Note], bowlName: String? = nil, in context: ModelContext) {
        let message: String
        switch change {
        case .move(let bowl):
            move(notes, toBowl: bowl, named: bowlName, in: context)
            return
        case .kind(let kind):
            message = kind.map { String(localized: "Kind set to \($0.title)") } ?? String(localized: "Kind removed")
        case .sender(let sender):
            message = (sender?.isEmpty ?? true) ? String(localized: "Sender removed") : String(localized: "Sender set")
        case .paid(let paid):
            message = paid ? String(localized: "Marked as paid") : String(localized: "Marked as unpaid")
        }
        run(message, systemImage: "doc", notes: notes, in: context) {
            Documents.apply(change, to: notes, in: context)
        }
    }

    /// The cross on a document's chip: what it is, taken away.
    static func clearDocument(_ note: Note, in context: ModelContext) {
        run(String(localized: "Document info cleared"), systemImage: "doc", notes: [note], in: context) {
            Documents.clear(note, in: context)
        }
    }

    /// Takes a tag of the tag field off the note.
    static func removeTag(_ tag: String, from note: Note, in context: ModelContext) {
        run(String(localized: "Removed #\(tag)"), systemImage: "number", notes: [note], in: context) {
            note.labels.removeAll { $0.lowercased() == tag.lowercased() }
            note.updatedAt = Date()
            try? context.save()
        }
    }

    // MARK: Messages

    static func deletedMessage(_ notes: [Note]) -> String {
        if notes.count == 1, let note = notes.first {
            return String(localized: "Deleted “\(note.displayTitle)”")
        }
        return String(localized: "Deleted \(notes.count) entries")
    }

    static func movedMessage(count: Int, to name: String?) -> String {
        let place = name ?? String(localized: "Inbox")
        return count == 1 ? String(localized: "Moved to “\(place)”") : String(localized: "Moved \(count) entries to “\(place)”")
    }
}
