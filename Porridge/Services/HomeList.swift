import Foundation
import SwiftData

/// The bowls as the Bowls place (iPhone) and the Mac's sidebar list them: all of them, the pinned ones first, then
/// the others in the one order of Settings › General › Sort Bowls By (per device). The archive holds archived bowls only.
enum HomeList {
    /// How the bowls are ordered (Settings › General › Sort Bowls By, on this device, read by iPhone and Mac). The
    /// pinned ones come first in the same order.
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

    /// The order chosen on this device; Last Change when none was.
    static var bowlOrder: BowlOrder {
        UserDefaults.standard.string(forKey: bowlOrderKey).flatMap(BowlOrder.init(rawValue:)) ?? .lastChange
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

    /// When each bowl last changed (`Projects.key`): the bowl itself or the newest entry in it, deleted ones left out.
    static func lastChanges(_ projects: [NoteFolder], notes: [Note]) -> [String: Date] {
        var dates = Dictionary(projects.map { (Projects.key($0), $0.updatedAt) }, uniquingKeysWith: { max($0, $1) })
        for note in notes where !note.isDeleted {
            for key in note.projectIDs where dates[key] != nil { dates[key] = max(dates[key] ?? .distantPast, note.updatedAt) }
        }
        return dates
    }

    /// All bowls given, the pinned ones first, then the others, both in `order`. No limit: every bowl is shown.
    static func ordered(_ projects: [NoteFolder], order: BowlOrder = bowlOrder, lastChange: (NoteFolder) -> Date) -> [NoteFolder] {
        func byName(_ a: NoteFolder, _ b: NoteFolder) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let all: [NoteFolder]
        switch order {
        case .lastChange:
            all = projects
                .map { (project: $0, date: lastChange($0)) }
                .sorted { a, b in a.date != b.date ? a.date > b.date : byName(a.project, b.project) }
                .map(\.project)
        case .created:
            all = projects.sorted { a, b in a.createdAt != b.createdAt ? a.createdAt > b.createdAt : byName(a, b) }
        case .name:
            all = projects.sorted(by: byName)
        }
        return all.filter(\.isPinned) + all.filter { !$0.isPinned }
    }

    /// The bowls that are not archived, in the order of the Bowls place and the Mac's sidebar.
    static func bowls(_ projects: [NoteFolder], notes: [Note], order: BowlOrder = bowlOrder) -> [NoteFolder] {
        let active = projects.filter { !$0.isArchived }
        let changes = order == .lastChange ? lastChanges(active, notes: notes) : [:]
        return ordered(active, order: order) { changes[Projects.key($0)] ?? $0.updatedAt }
    }
}

/// The counts on the three places: Today's tab and sidebar row show the to-dos due today or overdue, the Inbox's
/// every entry in no bowl. The same numbers on iPhone and Mac.
enum Places {
    /// The place Bowls as a whole (tab, page head, Go To, onboarding, Mac sidebar and menus): a bowl of the app's own
    /// (template images `BowlPlaceFill`, `BowlPlace` outlined; SF Symbols has no bowl). A single bowl keeps the folder.
    static let bowlsSymbol = "BowlPlaceFill"

    /// The chat (Recent Chats, All Chats, the Search place on its Chat side: head, tab, iPad sidebar row).
    static let chatSymbol = "bubble.left.and.bubble.right.fill"

    static func todayCount(_ notes: [Note], now: Date = Date()) -> Int {
        TodayTodos.open(notes, now: now).count
    }

    /// Every entry in no bowl: nothing is put away, things stay in the Inbox until they are filed (owner revision 9).
    static func inboxCount(_ notes: [Note]) -> Int {
        notes.lazy.filter(\.isInInbox).count
    }

    /// The title of a switch's side, a segment or a filter chip with its count, the count only when there is one:
    /// "Archive", "Deleted 27" (owner revision 9: no "0" in tabs). `gap` is what stands between (two spaces on the
    /// Mac's pills).
    static func countedTitle(_ title: String, _ count: Int, gap: String = " ") -> String {
        count > 0 ? title + gap + "\(count)" : title
    }

    /// Entries that came in during the week of `now` (Weekly Review's row in Today).
    static func newThisWeek(_ notes: [Note], now: Date = Date(), calendar: Calendar = .current) -> Int {
        let week = WeeklyReview.week(containing: now, calendar: calendar)
        return notes.lazy.filter { !$0.isDeleted && week.contains($0.createdAt) }.count
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
