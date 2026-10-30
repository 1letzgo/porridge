import Foundation
import SwiftData

/// Folder for notes; `parentID` makes folders nest. Notes point at it with `Note.folderID`.
/// CloudKit-compatible: every property has a default.
@Model
final class NoteFolder {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var parentID: UUID?

    init(name: String, parentID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.parentID = parentID
    }
}

/// What a list shows: everything, one tag, or "Recently Deleted". (Folders are no longer shown; `NoteFolder`
/// stays in the store so synced data keeps its shape.)
enum NoteScope: Hashable {
    case all
    case tag(String)
    case trash
}

extension Array where Element == NoteFolder {
    /// Folders depth first (siblings by name) with their nesting level.
    var tree: [(folder: NoteFolder, depth: Int)] {
        let byParent = Dictionary(grouping: self, by: \.parentID)
        let ids = Set(map(\.id))
        var result: [(NoteFolder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for folder in (byParent[parent] ?? []).sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                result.append((folder, depth))
                walk(folder.id, depth + 1)
            }
        }
        walk(nil, 0)
        // Folders whose parent is gone (e.g. deleted on another device) show up at the top level.
        for orphan in self where orphan.parentID != nil && !ids.contains(orphan.parentID!) && !result.contains(where: { $0.0.id == orphan.id }) {
            result.append((orphan, 0))
            walk(orphan.id, 1)
        }
        return result
    }

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

    /// The folder and everything below it.
    func subtreeIDs(of id: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        var added = true
        while added {
            added = false
            for folder in self where !ids.contains(folder.id) {
                if let parent = folder.parentID, ids.contains(parent) { ids.insert(folder.id); added = true }
            }
        }
        return ids
    }
}
