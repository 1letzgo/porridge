import Foundation
import SwiftData

/// The inbox: everything that is in no bowl, newest first. A note leaves it only by being filed into a bowl
/// (a project), and is back when it is taken out of its last one. Bowls are only ever suggested; the user takes
/// a suggestion on or drops it.
@MainActor
enum Inbox {
    /// What waits in the inbox, newest first.
    static func notes(_ all: [Note]) -> [Note] {
        all.filter(\.isInInbox).sorted { $0.createdAt > $1.createdAt }
    }

    /// Files the note into a bowl; it leaves the inbox and its suggestions are settled.
    static func file(_ note: Note, into project: String, in context: ModelContext) {
        if !note.projectIDs.contains(project) { note.projectIDs.append(project) }
        settle(note, in: context)
    }

    static func dismissSuggestions(_ note: Note, in context: ModelContext) {
        guard !note.suggestedProjectIDs.isEmpty else { return }
        note.suggestedProjectIDs = []
        note.updatedAt = Date()
        try? context.save()
    }

    private static func settle(_ note: Note, in context: ModelContext) {
        note.filedAt = note.filedAt ?? Date()
        note.suggestedProjectIDs = []
        note.updatedAt = Date()
        try? context.save()
    }

    // MARK: Suggestions

    /// The bowls a model may choose from for this note: the active ones, while the note is in none.
    static func candidates(for note: Note) -> [NoteFolder] {
        guard note.projectIDs.isEmpty, let context = note.modelContext else { return [] }
        return ((try? context.fetch(FetchDescriptor<NoteFolder>(sortBy: [SortDescriptor(\.name)]))) ?? []).filter { !$0.isArchived }
    }

    /// The line added to a summary prompt so the model names a bowl. Empty without bowls.
    static func promptLine(_ projects: [NoteFolder]) -> String {
        let names = projects.map { $0.name.replacingOccurrences(of: "|", with: "/") }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return "" }
        return "\nPROJECT: <the one bowl from this list that this clearly belongs to, written exactly as listed, or \"none\" when none clearly fits: \(names.joined(separator: " | "))>"
    }

    /// Takes the "PROJECT: name" line off an answer. The name counts only when it is one of the bowls.
    static func splitProject(_ text: String, projects: [NoteFolder]) -> (text: String, project: NoteFolder?) {
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("PROJECT:") }) else {
            return (text, nil)
        }
        let line = lines.remove(at: index).trimmingCharacters(in: .whitespaces)
        let name = line.dropFirst("PROJECT:".count)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'*<>.`"))
            .trimmingCharacters(in: .whitespaces)
        let match = projects.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), match)
    }
}
