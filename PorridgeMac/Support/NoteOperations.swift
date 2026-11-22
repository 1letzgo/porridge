import AppKit
import SwiftData

/// What can be done with notes from a list, a menu or the detail: pin, bowls, share, delete. The same for one note
/// or several selected ones. Notes are never archived, only bowls are.
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
        // To-dos: done or not, and a note that becomes one (or stops being one).
        let todos = notes.filter(\.isTodo)
        if !todos.isEmpty, todos.count == notes.count {
            let done = todos.allSatisfy(\.isDone)
            menu.add(done ? "Mark as Not Done" : "Mark as Done", symbol: done ? "square" : "checkmark.square") {
                todos.forEach { TodoBridge.setDone(!done, $0) }
            }
        }
        if !todos.isEmpty, todos.count == notes.count {
            let due = NSMenuItem(title: "Due Date", action: nil, keyEquivalent: "")
            due.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
            due.submenu = DueDateMenu.make(for: todos, window: window)
            menu.addItem(due)
        }
        // The tasks of a summary as to-dos again (never from a saved page or file).
        if notes.count == 1, let note = notes.first, note.summary != nil, !note.isSaved, !note.isTodo {
            menu.add("Suggest To-dos", symbol: "checklist") {
                TodoSuggestions.suggestAgain(note, in: context)
                state.reveal(note)
            }
        }
        if notes.count == 1, let note = notes.first, note.canBeTodo {
            menu.add(note.isTodo ? "Convert to Note" : "Convert to To-do", symbol: note.isTodo ? "text.alignleft" : "checklist") {
                TodoBridge.setTodo(!note.isTodo, note)
            }
        }
        let pinned = notes.allSatisfy(\.isPinned)
        menu.add(pinned ? "Unpin" : "Pin", symbol: pinned ? "pin.slash" : "pin") { setPinned(!pinned, notes) }
        // Into one bowl (in place of the one they are in) or back to the inbox, all selected at once.
        let buckets = NSMenuItem(title: notes.count == 1 ? "Bowl" : "Bowl of \(notes.count)", action: nil, keyEquivalent: "")
        buckets.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        buckets.submenu = bucketMenu(for: notes, window: window)
        menu.addItem(buckets)
        addDocumentItems(for: notes, to: menu, window: window)
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

    /// The inbox and the bowls, ticked where all the notes are: a click moves them there (in place of their bowl;
    /// an entry is in one bowl at most).
    static func bucketMenu(for notes: [Note], window: NSWindow?) -> NSMenu {
        let menu = NSMenu()
        let inbox = menu.add("Inbox", symbol: "tray") { Documents.apply(.move(toBowl: nil), to: notes, in: context) }
        inbox.state = notes.allSatisfy(\.isInInbox) ? .on : .off
        menu.addSeparator()
        for project in library.activeProjects {
            let key = Projects.key(project)
            let item = menu.add(project.name, symbol: "folder") { Documents.apply(.move(toBowl: key), to: notes, in: context) }
            item.state = notes.allSatisfy { $0.projectIDs == [key] } ? .on : (notes.contains { $0.projectIDs.contains(key) } ? .mixed : .off)
        }
        menu.addSeparator()
        menu.add("New Bowl…") {
            BucketActions.create(in: window) { project in
                notes.forEach { Inbox.file($0, into: Projects.key(project), in: context) }
            }
        }
        return menu
    }

    /// For documents: their kind and sender (all selected at once), their pages, merging several PDFs.
    private static func addDocumentItems(for notes: [Note], to menu: NSMenu, window: NSWindow?) {
        let documents = notes.filter { $0.isStored && !$0.attachments.isEmpty }
        guard !documents.isEmpty else { return }
        let kinds = NSMenuItem(title: "Document Kind", action: nil, keyEquivalent: "")
        kinds.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let kindMenu = NSMenu()
        kindMenu.add("Not Set") { Documents.apply(.kind(nil), to: documents, in: context) }
        kindMenu.addSeparator()
        for kind in DocumentKind.allCases {
            let item = kindMenu.add(kind.title, symbol: kind.symbol) { Documents.apply(.kind(kind), to: documents, in: context) }
            item.state = documents.allSatisfy { $0.documentInfo?.kind == kind } ? .on : .off
        }
        kinds.submenu = kindMenu
        menu.addItem(kinds)
        menu.add(documents.count == 1 ? "Set Sender…" : "Set Sender of \(documents.count)…", symbol: "person.crop.square") {
            let current = Set(documents.map { $0.documentInfo?.correspondent ?? "" })
            Alerts.ask(
                "Sender", message: "Leave it empty to remove the sender.", placeholder: "Company, office or person",
                value: current.count == 1 ? current.first ?? "" : "", action: "Set", validate: { _ in true }, in: window
            ) { sender in
                Documents.apply(.sender(sender), to: documents, in: context)
            }
        }
        if documents.count == 1, let note = documents.first, DocumentFiles.pdf(of: note) != nil {
            menu.add("Edit Pages…", symbol: "doc.on.doc") { PDFPageEditorController.open(note, in: window) }
        }
        let mergeable = DocumentFiles.mergeable(documents)
        if mergeable.count >= 2 {
            menu.add("Merge \(mergeable.count) PDFs…", symbol: "arrow.triangle.merge", enabled: !DocumentFiles.isBusy) { merge(mergeable, in: window) }
        }
    }

    /// Asks which document the others go into, merges, then asks whether the others go to Recently Deleted.
    static func merge(_ notes: [Note], in window: NSWindow?) {
        let ordered = Documents.sorted(notes)
        let alert = NSAlert()
        alert.messageText = "Merge \(ordered.count) PDFs"
        alert.informativeText = "The pages of the others are added at the end of the chosen document, in the order of the list. It keeps what it is."
        let target = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        target.addItems(withTitles: ordered.map(\.displayTitle))
        alert.accessoryView = target
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let run: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let into = ordered[max(0, target.indexOfSelectedItem)]
            let others = ordered.filter { $0.id != into.id }
            Task {
                do {
                    try await DocumentFiles.merge(others, into: into, context: context, processing: library.processing)
                    // Only entries that held nothing but the merged PDF are offered for deletion.
                    let deletable = DocumentFiles.deletableAfterMerge(others)
                    guard !deletable.isEmpty else { return }
                    Alerts.confirm(
                        "Delete the Merged Documents?", message: "Their pages are in “\(into.displayTitle)” now.",
                        action: "Move \(deletable.count) to Recently Deleted", in: window
                    ) {
                        deletable.forEach { NoteStore.trash($0, in: context) }
                    }
                } catch {
                    Alerts.inform("Could Not Merge", message: error.localizedDescription, in: window)
                }
            }
        }
        if let window, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: run) } else { run(alert.runModal()) }
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
        // A change like any other: the sync otherwise lets an older copy of the note win over the pin.
        let now = Date()
        for note in notes where note.isPinned != pinned {
            note.isPinned = pinned
            note.updatedAt = now
        }
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

/// Bowls: create, rename, archive, delete.
@MainActor
enum BucketActions {
    private static var library: Library { .shared }

    static func create(in window: NSWindow?, then: @escaping (NoteFolder) -> Void = { _ in }) {
        Alerts.ask("New Bowl", placeholder: "Name", action: "Create", in: window) { name in
            if let project = Projects.create(name, in: library.context) {
                library.reload()
                then(project)
            }
        }
    }

    static func rename(_ project: NoteFolder, in window: NSWindow?) {
        Alerts.ask("Rename Bowl", placeholder: "Name", value: project.name, action: "Rename", in: window) { name in
            Projects.rename(project, to: name, in: library.context)
        }
    }

    static func confirmDelete(_ project: NoteFolder, state: WindowState, in window: NSWindow) {
        // A bowl someone shared with me is left, not deleted: the owner keeps it.
        if BowlSharing.shared.isSharedWithMe(project.id) {
            BowlShareMac.shared.confirmLeave(project, state: state, in: window)
            return
        }
        let message = BowlSharing.shared.isShared(project.id)
            ? "Its meetings, notes and links stay. The people you shared it with lose access."
            : "Its meetings, notes and links stay."
        Alerts.confirm("Delete “\(project.name)”?", message: message, action: "Delete Bowl", in: window) {
            if state.page == .project(project.id) { state.page = .inbox }
            // A shared bowl stops being shared first, so its entries do not leave it one by one for the others.
            BowlSharing.shared.bowlWillBeDeleted(project.id)
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
        BowlShareMac.shared.addItems(for: project, to: menu, in: window)
        menu.add("Export Bowl…", symbol: "square.and.arrow.up") {
            ExportSheetController.export(.bowl(project.id), title: String(localized: "Export “\(project.name)”"), in: window)
        }
        menu.addSeparator()
        let leaves = BowlSharing.shared.isSharedWithMe(project.id)
        menu.add(leaves ? "Leave Bowl…" : "Delete Bowl…", symbol: leaves ? "rectangle.portrait.and.arrow.right" : "trash", isDestructive: true) {
            guard let window else { return }
            confirmDelete(project, state: state, in: window)
        }
    }
}
