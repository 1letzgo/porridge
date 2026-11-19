import AppKit
import SwiftData

/// What can be done with notes from a list, a menu or the detail: pin, buckets, archive, share, delete. The same
/// for one note or several selected ones.
@MainActor
enum NoteOperations {
    private static var library: Library { .shared }
    private static var context: ModelContext { library.context }

    /// The items of a row's context menu.
    static func addItems(for notes: [Note], to menu: NSMenu, state: WindowState, window: NSWindow?) {
        let deleted = notes.allSatisfy(\.isDeleted)
        if deleted {
            menu.add("Recover", symbol: "arrow.uturn.backward") { recover(notes, state: state) }
            menu.addSeparator()
            menu.add("Delete Now…", symbol: "trash", isDestructive: true) { deleteNow(notes, state: state, in: window) }
            return
        }
        if notes.count == 1, let note = notes.first {
            menu.add("Open in New Window", symbol: "macwindow") { NoteWindowController.open(note.id) }
            menu.addSeparator()
        }
        if !notes.contains(where: \.isArchived) {
            let pinned = notes.allSatisfy(\.isPinned)
            menu.add(pinned ? "Unpin" : "Pin", symbol: pinned ? "pin.slash" : "pin") { setPinned(!pinned, notes) }
        }
        let buckets = NSMenuItem(title: "Buckets", action: nil, keyEquivalent: "")
        buckets.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        buckets.submenu = bucketMenu(for: notes, window: window)
        menu.addItem(buckets)
        let archived = notes.allSatisfy(\.isArchived)
        menu.add(archived ? "Unarchive" : "Archive", symbol: archived ? "tray.and.arrow.up" : "archivebox") {
            notes.forEach { Archive.set(!archived, $0, in: context) }
        }
        menu.addSeparator()
        menu.add("Copy", symbol: "doc.on.doc") { copy(notes) }
        let share = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        share.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        share.submenu = shareMenu(text: notes.map(\.exportText).joined(separator: "\n\n---\n\n"))
        menu.addItem(share)
        menu.addSeparator()
        menu.add(notes.count == 1 ? "Delete" : "Delete \(notes.count) Notes", symbol: "trash", isDestructive: true) {
            trash(notes, state: state)
        }
    }

    /// A menu of the buckets, ticked where all the notes are in; a click puts them in or takes them out.
    static func bucketMenu(for notes: [Note], window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        for project in library.activeProjects {
            let key = Projects.key(project)
            let inAll = notes.allSatisfy { $0.projectIDs.contains(key) }
            let item = menu.add(project.name) {
                for note in notes {
                    if inAll {
                        note.projectIDs.removeAll { $0 == key }
                        note.updatedAt = Date()
                    } else if !note.projectIDs.contains(key) {
                        Inbox.file(note, into: key, in: context)
                    }
                }
                library.save()
            }
            item.state = inAll ? .on : (notes.contains { $0.projectIDs.contains(key) } ? .mixed : .off)
        }
        menu.addSeparator()
        menu.add("New Bucket…") {
            BucketActions.create(in: window) { project in
                notes.forEach { Inbox.file($0, into: Projects.key(project), in: context) }
            }
        }
        return menu
    }

    /// The sharing services for a text, as a submenu.
    static func shareMenu(text: String) -> NSMenu {
        let menu = NSMenu()
        for service in NSSharingService.sharingServices(forItems: [text]) {
            let item = menu.add(service.menuItemTitle) { service.perform(withItems: [text]) }
            item.image = service.image
        }
        return menu
    }

    static func setPinned(_ pinned: Bool, _ notes: [Note]) {
        notes.forEach { $0.isPinned = pinned }
        library.save()
    }

    static func copy(_ notes: [Note]) {
        NotePasteboard.write(notes, to: .general)
    }

    /// Moves notes to Recently Deleted; they can come back from there for 30 days, so nothing asks first.
    static func trash(_ notes: [Note], state: WindowState) {
        let ids = Set(notes.map(\.id))
        for note in notes {
            if note.modelContext == nil, state.draft?.id == note.id {
                state.draft = nil
            } else {
                NoteStore.trash(note, in: context)
            }
        }
        state.selection.removeAll { ids.contains($0) }
    }

    static func recover(_ notes: [Note], state: WindowState) {
        notes.forEach { NoteStore.restore($0, in: context) }
        let ids = Set(notes.map(\.id))
        state.selection.removeAll { ids.contains($0) }
    }

    /// Deleting for good always asks first.
    static func deleteNow(_ notes: [Note], state: WindowState, in window: NSWindow?) {
        Alerts.confirm(
            notes.count == 1 ? "Delete Note Now?" : "Delete \(notes.count) Notes Now?",
            message: "This cannot be undone.", action: "Delete Now", in: window
        ) {
            let ids = Set(notes.map(\.id))
            state.selection.removeAll { ids.contains($0) }
            notes.forEach { NoteStore.deletePermanently($0, in: context) }
        }
    }

    static func confirmEmptyTrash(in window: NSWindow, state: WindowState) {
        Alerts.confirm("Delete All in Recently Deleted?", message: "This cannot be undone.", action: "Delete All", in: window) {
            let deleted = library.notes.filter(\.isDeleted)
            let ids = Set(deleted.map(\.id))
            state.selection.removeAll { ids.contains($0) }
            deleted.forEach { NoteStore.deletePermanently($0, in: context) }
        }
    }
}

/// Buckets: create, rename, archive, delete.
@MainActor
enum BucketActions {
    private static var library: Library { .shared }

    static func create(in window: NSWindow?, then: @escaping (NoteFolder) -> Void = { _ in }) {
        Alerts.ask("New Bucket", placeholder: "Name", action: "Create", in: window) { name in
            if let project = Projects.create(name, in: library.context) {
                library.reload()
                then(project)
            }
        }
    }

    static func rename(_ project: NoteFolder, in window: NSWindow?) {
        Alerts.ask("Rename Bucket", placeholder: "Name", value: project.name, action: "Rename", in: window) { name in
            Projects.rename(project, to: name, in: library.context)
        }
    }

    static func confirmDelete(_ project: NoteFolder, state: WindowState, in window: NSWindow) {
        Alerts.confirm("Delete “\(project.name)”?", message: "Its meetings, notes and links stay.", action: "Delete Bucket", in: window) {
            if state.page == .project(project.id) { state.page = .inbox }
            Projects.delete(project, in: library.context)
        }
    }

    static func addItems(for project: NoteFolder, to menu: NSMenu, state: WindowState, window: NSWindow?) {
        menu.add("Open", symbol: "folder") { state.page = .project(project.id) }
        if !project.isArchived {
            menu.add(project.isPinned ? "Unpin" : "Pin", symbol: project.isPinned ? "pin.slash" : "pin") {
                project.isPinned.toggle()
                project.updatedAt = Date()
                library.save()
            }
        }
        menu.add("Rename…", symbol: "pencil") { rename(project, in: window) }
        menu.add(project.isArchived ? "Unarchive" : "Archive", symbol: project.isArchived ? "tray.and.arrow.up" : "archivebox") {
            Archive.set(!project.isArchived, project, in: library.context)
        }
        menu.addSeparator()
        menu.add("Delete Bucket…", symbol: "trash", isDestructive: true) {
            guard let window else { return }
            confirmDelete(project, state: state, in: window)
        }
    }
}
