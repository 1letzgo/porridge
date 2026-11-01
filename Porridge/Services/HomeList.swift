import Foundation
import SwiftData

/// What the one long list shows, and what is in the archive. An element in a project lives in the project and
/// is not listed on its own; an id of a project that no longer exists does not count, so nothing gets lost.
enum HomeList {
    static func activeProjects(_ projects: [NoteFolder]) -> [NoteFolder] {
        sorted(projects.filter { !$0.isArchived })
    }

    static func archivedProjects(_ projects: [NoteFolder]) -> [NoteFolder] {
        sorted(projects.filter(\.isArchived))
    }

    private static func sorted(_ projects: [NoteFolder]) -> [NoteFolder] {
        projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func notes(_ notes: [Note], projects: Set<String>) -> [Note] {
        notes.filter { !$0.isDeleted && !$0.isArchived && !isInProject($0.projectIDs, projects) }
    }

    static func tasks(_ items: [ActionItem], notes: [UUID: Note], projects: Set<String>) -> [ActionItem] {
        items.filter { item in
            guard isShownTask(item, notes: notes), !item.isArchived, !isInProject(item.projectIDs, projects) else { return false }
            return !isInProject(item.noteID.flatMap { notes[$0] }?.projectIDs ?? [], projects)
        }
    }

    static func archivedNotes(_ notes: [Note]) -> [Note] {
        notes.filter { $0.isArchived && !$0.isDeleted }
    }

    static func archivedTasks(_ items: [ActionItem], notes: [UUID: Note]) -> [ActionItem] {
        items.filter { $0.isArchived && isShownTask($0, notes: notes) }
    }

    /// A task that was not dropped and whose note was not deleted (a task whose note is gone stays on its own).
    static func isShownTask(_ item: ActionItem, notes: [UUID: Note]) -> Bool {
        guard item.kind == .task, item.review != .dismissed else { return false }
        guard let id = item.noteID, let note = notes[id] else { return true }
        return !note.isDeleted && !note.isLink
    }

    private static func isInProject(_ ids: [String], _ projects: Set<String>) -> Bool {
        ids.contains { projects.contains($0) }
    }
}

/// Archiving keeps an element out of the lists without deleting it; it stays in the search and the chat.
enum Archive {
    static func set(_ archived: Bool, _ note: Note, in context: ModelContext) {
        guard note.modelContext != nil else { return }
        note.archivedAt = archived ? Date() : nil
        if archived { note.isPinned = false }
        note.updatedAt = Date()
        try? context.save()
    }

    static func set(_ archived: Bool, _ item: ActionItem, in context: ModelContext) {
        item.archivedAt = archived ? Date() : nil
        item.updatedAt = Date()
        try? context.save()
    }

    /// The project's elements stay in it.
    static func set(_ archived: Bool, _ project: NoteFolder, in context: ModelContext) {
        project.archivedAt = archived ? Date() : nil
        project.updatedAt = Date()
        try? context.save()
    }
}
