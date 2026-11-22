import Foundation
import SwiftData

/// What the home list shows of the bowls, and what is in the archive (archived bowls only).
enum HomeList {
    /// How many bowls that are not pinned the list shows before "More" (Settings › General, on this device);
    /// 0 shows them all.
    static let recentProjectsKey = "homeRecentBowls"
    static let defaultRecentProjects = 5
    static let recentProjectsChoices = [3, 5, 10, 20, 0]

    /// How the home list orders the bowls that are not pinned (Settings › General, on this device). The pinned
    /// ones come first in the same order.
    enum BowlOrder: String, CaseIterable {
        case lastChange, created, name

        var title: String {
            switch self {
            case .lastChange: String(localized: "Last Change")
            case .created: String(localized: "Created")
            case .name: String(localized: "Name")
            }
        }
    }

    static let bowlOrderKey = "homeBowlOrder"

    static var recentProjects: Int {
        UserDefaults.standard.object(forKey: recentProjectsKey) as? Int ?? defaultRecentProjects
    }

    static func activeProjects(_ projects: [NoteFolder]) -> [NoteFolder] {
        sorted(projects.filter { !$0.isArchived })
    }

    static func archivedProjects(_ projects: [NoteFolder]) -> [NoteFolder] {
        sorted(projects.filter(\.isArchived))
    }

    private static func sorted(_ projects: [NoteFolder]) -> [NoteFolder] {
        projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The projects the list shows: all pinned ones, then the others in `order`, up to `recentProjects`
    /// (`limit`, 0 for all) unless all are asked for. `hidden` is how many others that leaves out when not all are shown.
    static func shownProjects(
        _ projects: [NoteFolder], showAll: Bool, limit: Int = recentProjects, order: BowlOrder = .lastChange,
        lastChange: (NoteFolder) -> Date
    ) -> (shown: [NoteFolder], hidden: Int) {
        func byName(_ a: NoteFolder, _ b: NoteFolder) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let latest: [NoteFolder]
        switch order {
        case .lastChange:
            latest = projects
                .map { (project: $0, date: lastChange($0)) }
                .sorted { a, b in a.date != b.date ? a.date > b.date : byName(a.project, b.project) }
                .map(\.project)
        case .created:
            latest = projects.sorted { a, b in a.createdAt != b.createdAt ? a.createdAt > b.createdAt : byName(a, b) }
        case .name:
            latest = projects.sorted(by: byName)
        }
        let pinned = latest.filter(\.isPinned)
        let others = latest.filter { !$0.isPinned }
        if showAll || limit <= 0 { return (pinned + others, limit <= 0 ? 0 : max(0, others.count - limit)) }
        return (pinned + others.prefix(limit), max(0, others.count - limit))
    }
}

/// Archiving keeps a bowl out of the lists without deleting it; its elements stay in it and in the search.
/// Only bowls are archived, never single notes.
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
