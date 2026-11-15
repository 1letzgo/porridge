import Foundation
import SwiftData

/// A project (stored as the former note folder, so synced data keeps its shape). Notes, meetings and links
/// name the projects they belong to in `projectIDs`; one element can be in several. `parentID` and
/// `Note.folderID` are from the folder days and no longer used.
/// CloudKit-compatible: every property has a default.
@Model
final class NoteFolder {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var parentID: UUID?
    /// Set while the project is in the archive; its elements stay in it.
    var archivedAt: Date?
    /// Pinned projects always show in the list, whatever else changed since.
    var isPinned: Bool = false

    var isArchived: Bool { archivedAt != nil }

    init(name: String, parentID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.parentID = parentID
    }
}

extension Array where Element == NoteFolder {
    /// "Parent › Child" for a folder.
    func path(of folder: NoteFolder) -> String {
        var names = [folder.name]
        var current = folder
        var guardCount = 0
        while let parentID = current.parentID, let parent = first(where: { $0.id == parentID }), guardCount < 20 {
            names.insert(parent.name, at: 0)
            current = parent
            guardCount += 1
        }
        return names.joined(separator: " › ")
    }
}
