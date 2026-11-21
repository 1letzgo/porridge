import Foundation
import SwiftData

/// Projects: creating, renaming and deleting them, assigning notes and tasks, and what belongs to one.
/// A project is a `NoteFolder`; elements name theirs in `projectIDs` (uppercase UUID strings).
enum Projects {
    static func key(_ project: NoteFolder) -> String { project.id.uuidString }

    /// The order of a bowl's list (iOS and Mac, every filter): one flat list, pinned notes first, each part by last
    /// change (newest first). `byDue` (the To-dos filter): within each part open to-dos by due day, then done ones
    /// (`Todos.byDue`), ties by last change.
    static func ordered(_ notes: [Note], byDue: Bool = false) -> [Note] {
        let newest = notes.sorted { $0.updatedAt > $1.updatedAt }
        let pinned = newest.filter(\.isPinned)
        let rest = newest.filter { !$0.isPinned }
        return byDue ? Todos.byDue(pinned) + Todos.byDue(rest) : pinned + rest
    }

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

    /// Deletes the project only: its notes stay and just leave it.
    static func delete(_ project: NoteFolder, in context: ModelContext) {
        let id = key(project)
        for note in (try? context.fetch(FetchDescriptor<Note>())) ?? [] where note.projectIDs.contains(id) {
            note.projectIDs.removeAll { $0 == id }
            note.updatedAt = Date()
        }
        context.delete(project)
        try? context.save()
    }

    static func toggle(_ project: NoteFolder, on note: Note, in context: ModelContext) {
        note.projectIDs = toggled(note.projectIDs, key(project))
        // Put into a bowl by hand: it has left the inbox, whatever was suggested.
        if note.projectIDs.contains(key(project)) {
            note.filedAt = note.filedAt ?? Date()
            note.suggestedProjectIDs = []
        }
        note.updatedAt = Date()
        try? context.save()
    }

    private static func toggled(_ ids: [String], _ id: String) -> [String] {
        ids.contains(id) ? ids.filter { $0 != id } : ids + [id]
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
