import Foundation
import SwiftData

/// What the home list shows of the buckets, and what is in the archive (archived buckets only).
enum HomeList {
    /// How many projects that are not pinned the list shows before "More".
    static let recentProjects = 5

    static func activeProjects(_ projects: [NoteFolder]) -> [NoteFolder] {
        sorted(projects.filter { !$0.isArchived })
    }

    static func archivedProjects(_ projects: [NoteFolder]) -> [NoteFolder] {
        sorted(projects.filter(\.isArchived))
    }

    private static func sorted(_ projects: [NoteFolder]) -> [NoteFolder] {
        projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The projects the list shows: all pinned ones, then the latest changed others, up to `recentProjects`
    /// unless all are asked for. `hidden` is how many others that leaves out when not all are shown.
    static func shownProjects(
        _ projects: [NoteFolder], showAll: Bool, lastChange: (NoteFolder) -> Date
    ) -> (shown: [NoteFolder], hidden: Int) {
        let latest = projects
            .map { (project: $0, date: lastChange($0)) }
            .sorted { a, b in
                if a.date != b.date { return a.date > b.date }
                return a.project.name.localizedStandardCompare(b.project.name) == .orderedAscending
            }
            .map(\.project)
        let pinned = latest.filter(\.isPinned)
        let others = latest.filter { !$0.isPinned }
        return (pinned + (showAll ? others : Array(others.prefix(recentProjects))), max(0, others.count - recentProjects))
    }
}

/// Archiving keeps a bucket out of the lists without deleting it; its elements stay in it and in the search.
/// Only buckets are archived, never single notes.
enum Archive {
    static func set(_ archived: Bool, _ project: NoteFolder, in context: ModelContext) {
        project.archivedAt = archived ? Date() : nil
        if archived { project.isPinned = false }
        project.updatedAt = Date()
        try? context.save()
    }

    /// Notes archived by earlier versions come back: `Note.archivedAt` is cleared on every note that still has it.
    /// Runs at every start and does nothing once all are clear; `updatedAt` stays, so the notes keep their place and
    /// no device pushes them as changed. Each device cleans its own store. Returns how many notes it cleared.
    @discardableResult
    static func clearArchivedNotes(in context: ModelContext) -> Int {
        let notes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.archivedAt != nil }))) ?? []
        guard !notes.isEmpty else { return 0 }
        notes.forEach { $0.archivedAt = nil }
        try? context.save()
        return notes.count
    }
}
