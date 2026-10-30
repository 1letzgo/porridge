import SwiftData
import SwiftUI

/// What the folder menu asks the user for: a name for a new or renamed folder, or the confirmation to delete one.
@MainActor
@Observable
final class FolderPromptState {
    enum Prompt: Identifiable {
        case newFolder(parent: UUID?)
        case rename(NoteFolder)

        var id: String {
            switch self {
            case .newFolder(let parent): "new-\(parent?.uuidString ?? "root")"
            case .rename(let folder): "rename-\(folder.id)"
            }
        }
    }

    var prompt: Prompt?
    var name = ""
    var folderToDelete: NoteFolder?
}

/// The folders as a drop-down: all notes, the default folder, the folder tree (sub-folders as sub-menus),
/// tags and "Recently Deleted", plus the actions to create, rename and delete folders.
struct FolderMenu: View {
    let notes: [Note]
    let folders: [NoteFolder]
    @Binding var scope: NoteScope
    let state: FolderPromptState

    var body: some View {
        let active = notes.filter { !$0.isDeleted }
        let folderIDs = Set(folders.map(\.id))
        let unfiled = active.filter { $0.folderID.map { !folderIDs.contains($0) } ?? true }.count
        let counts = Dictionary(grouping: active.compactMap { $0.folderID.flatMap { folderIDs.contains($0) ? $0 : nil } }, by: { $0 }).mapValues(\.count)
        let tags = Self.tagCounts(active)

        Menu {
            item("All Notes", "note.text", active.count, .all)
            item("Notes", "folder", unfiled, .unfiled)

            let roots = folders.filter { $0.parentID == nil || !folderIDs.contains($0.parentID!) }
            ForEach(roots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { folder in
                FolderMenuItem(folder: folder, folders: folders, counts: counts, scope: $scope)
            }

            if !tags.isEmpty {
                Divider()
                Menu {
                    ForEach(tags, id: \.key) { tag in
                        item("#" + tag.name, "number", tag.count, .tag(tag.key))
                    }
                } label: {
                    Label("Tags", systemImage: "number")
                }
            }

            Divider()
            item("Recently Deleted", "trash", notes.count - active.count, .trash)

            Divider()
            Button {
                state.name = ""
                state.prompt = .newFolder(parent: nil)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            if case .folder(let id) = scope, let folder = folders.first(where: { $0.id == id }) {
                Button {
                    state.name = ""
                    state.prompt = .newFolder(parent: folder.id)
                } label: {
                    Label("New Subfolder", systemImage: "folder.badge.plus")
                }
                Button {
                    state.name = folder.name
                    state.prompt = .rename(folder)
                } label: {
                    Label("Rename Folder", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    state.folderToDelete = folder
                } label: {
                    Label("Delete Folder", systemImage: "trash")
                }
            }
        } label: {
            Label("Folders", systemImage: "folder")
        }
        .accessibilityLabel("Folders")
    }

    private func item(_ title: String, _ systemImage: String, _ count: Int, _ target: NoteScope) -> some View {
        Button {
            scope = target
        } label: {
            Label("\(title) (\(count))", systemImage: scope == target ? "checkmark" : systemImage)
        }
    }

    static func tagCounts(_ active: [Note]) -> [(key: String, name: String, count: Int)] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for note in active {
            for tag in note.tags {
                let key = tag.lowercased()
                if names[key] == nil { names[key] = tag; order.append(key) }
                counts[key, default: 0] += 1
            }
        }
        return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { (key: $0, name: names[$0]!, count: counts[$0]!) }
    }
}

/// One folder in the menu; a folder with sub-folders opens a sub-menu that starts with the folder itself.
private struct FolderMenuItem: View {
    let folder: NoteFolder
    let folders: [NoteFolder]
    let counts: [UUID: Int]
    @Binding var scope: NoteScope

    var body: some View {
        let children = folders.filter { $0.parentID == folder.id }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if children.isEmpty {
            select
        } else {
            Menu {
                select
                Divider()
                ForEach(children) { child in
                    FolderMenuItem(folder: child, folders: folders, counts: counts, scope: $scope)
                }
            } label: {
                Label(folder.name, systemImage: "folder")
            }
        }
    }

    private var select: some View {
        Button {
            scope = .folder(folder.id)
        } label: {
            Label("\(folder.name) (\(counts[folder.id] ?? 0))", systemImage: scope == .folder(folder.id) ? "checkmark" : "folder")
        }
    }
}

extension View {
    /// The name prompt and the delete confirmation of the folder menu.
    func folderPrompts(_ state: FolderPromptState, folders: [NoteFolder], scope: Binding<NoteScope>) -> some View {
        modifier(FolderPrompts(state: state, folders: folders, scope: scope))
    }
}

private struct FolderPrompts: ViewModifier {
    @Bindable var state: FolderPromptState
    let folders: [NoteFolder]
    @Binding var scope: NoteScope
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: .init(get: { state.prompt != nil }, set: { if !$0 { state.prompt = nil } })) {
                TextField("Name", text: $state.name)
                Button("Save", action: save)
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete \"\(state.folderToDelete?.name ?? "")\"?",
                isPresented: .init(get: { state.folderToDelete != nil }, set: { if !$0 { state.folderToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Folder", role: .destructive) {
                    if let folder = state.folderToDelete { delete(folder) }
                }
            } message: {
                Text("The notes in it move to Recently Deleted.")
            }
    }

    private var title: String {
        if case .rename = state.prompt { return "Rename Folder" }
        return "New Folder"
    }

    private func save() {
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let prompt = state.prompt else { return }
        switch prompt {
        case .newFolder(let parent):
            context.insert(NoteFolder(name: name, parentID: parent))
        case .rename(let folder):
            folder.name = name
        }
        try? context.save()
    }

    private func delete(_ folder: NoteFolder) {
        let ids = folders.subtreeIDs(of: folder.id)
        if case .folder(let current) = scope, ids.contains(current) { scope = .all }
        NoteStore.delete(folder, in: context)
    }
}
