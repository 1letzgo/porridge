import Foundation
import SwiftData

/// Projects: creating, renaming and deleting them, assigning notes and tasks, and what belongs to one.
/// A project is a `NoteFolder`; elements name theirs in `projectIDs` (uppercase UUID strings, as on Android).
enum Projects {
    static func key(_ project: NoteFolder) -> String { project.id.uuidString }

    @discardableResult
    static func create(_ name: String, in context: ModelContext) -> NoteFolder? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let project = NoteFolder(name: name)
        context.insert(project)
        try? context.save()
        return project
    }

    static func rename(_ project: NoteFolder, to name: String, in context: ModelContext) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        project.name = name
        project.updatedAt = Date()
        try? context.save()
    }

    /// Deletes the project only: its notes and tasks stay and just leave it.
    static func delete(_ project: NoteFolder, in context: ModelContext) {
        let id = key(project)
        for note in (try? context.fetch(FetchDescriptor<Note>())) ?? [] where note.projectIDs.contains(id) {
            note.projectIDs.removeAll { $0 == id }
            note.updatedAt = Date()
        }
        for item in (try? context.fetch(FetchDescriptor<ActionItem>())) ?? [] where item.projectIDs.contains(id) {
            item.projectIDs.removeAll { $0 == id }
            item.updatedAt = Date()
        }
        context.delete(project)
        try? context.save()
    }

    static func toggle(_ project: NoteFolder, on note: Note, in context: ModelContext) {
        note.projectIDs = toggled(note.projectIDs, key(project))
        note.updatedAt = Date()
        try? context.save()
    }

    static func toggle(_ project: NoteFolder, on item: ActionItem, in context: ModelContext) {
        item.projectIDs = toggled(item.projectIDs, key(project))
        item.updatedAt = Date()
        try? context.save()
    }

    private static func toggled(_ ids: [String], _ id: String) -> [String] {
        ids.contains(id) ? ids.filter { $0 != id } : ids + [id]
    }

    /// A task is in a project of its own or through the note it comes from.
    static func contains(_ item: ActionItem, project id: String, notes: [UUID: Note]) -> Bool {
        item.projectIDs.contains(id) || (item.noteID.flatMap { notes[$0] }?.projectIDs.contains(id) ?? false)
    }

    /// The projects a task is in through its note (shown, but changed on the note).
    static func inherited(_ item: ActionItem, notes: [UUID: Note]) -> [String] {
        item.noteID.flatMap { notes[$0] }?.projectIDs ?? []
    }

    /// Notes from the folder days join the project their folder became.
    static func migrateFolders(in context: ModelContext) {
        let notes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.folderID != nil }))) ?? []
        guard !notes.isEmpty else { return }
        for note in notes {
            if let id = note.folderID?.uuidString, !note.projectIDs.contains(id) { note.projectIDs.append(id) }
            note.folderID = nil
            note.updatedAt = Date()
        }
        try? context.save()
    }
}
