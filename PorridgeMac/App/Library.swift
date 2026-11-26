import AppKit
import CoreData
import SwiftData
import UserNotifications

/// The notes, bowls and chats of the app for the AppKit windows: one store (`AppContainer`), one processing
/// queue, and the fetched lists, which follow every save of the store (this app's and the sync's). Windows ask to
/// be told of a change with `observe`; each change is told once, a moment after it happened.
@MainActor
final class Library {
    static let shared = Library()

    let container: ModelContainer
    let processing: ProcessingService
    var context: ModelContext { container.mainContext }

    /// Newest change first, as the lists show them.
    private(set) var notes: [Note] = []
    private(set) var projects: [NoteFolder] = []
    private(set) var threads: [ChatThread] = []
    /// Counts the reloads; a view that remembers it knows whether it is behind.
    private(set) var generation = 0

    private var observers: [UUID: @MainActor () -> Void] = [:]
    private var reloadScheduled = false
    private var indexTask: Task<Void, Never>?
    private var lastIndexSignature = 0
    private var lastShareProjects: [ShareInbox.Project] = []

    private init() {
        let container = AppContainer.make()
        self.container = container
        processing = ProcessingService(container: container)
        // Finds the iCloud container off the main thread and moves the files of notes into it.
        CloudFiles.start(container)
        // Shared bowls: follows the zones of the bowls this person shares and of those shared with them.
        BowlSharing.shared.start(container)

        let center = NotificationCenter.default
        center.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload() }
        }
        center.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsReload() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                ShareImport.importInbox(context: self.context, processing: self.processing)
                self.setNeedsReload()
            }
        }
        reload()
    }

    // MARK: Start

    /// What the list did once when it appeared: old data brought up to date, recordings that were cut off
    /// rescued, the share inbox read, the trash emptied of what ran out.
    func start() async {
        processing.resumePending()
        LegacyMigration.run(in: context)
        LegacyMigration.removeDuplicates(in: context)
        await RecordingJournal.recover(context: context, processing: processing)
        removeEmptyNotes()
        NoteStore.purgeExpired(in: context)
        ShareImport.importInbox(context: context, processing: processing)
        Projects.migrateFolders(in: context)
        // Only bowls are archived now: notes archived by earlier versions come back.
        Archive.clearArchivedNotes(in: context)
        // Reminders are gone: what was planned for them is taken back once.
        let center = UNUserNotificationCenter.current()
        let planned = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("remind-") }
        if !planned.isEmpty { center.removePendingNotificationRequests(withIdentifiers: planned) }
        reload()
    }

    /// Notes left empty by earlier versions (no title, text or recording) are not worth keeping.
    private func removeEmptyNotes() {
        let empty = notes.filter { $0.isEmptyLeftover && processing.stages[$0.id] == nil }
        guard !empty.isEmpty else { return }
        empty.forEach { context.delete($0) }
        try? context.save()
    }

    // MARK: Changes

    /// Calls `body` after every reload until the returned token is dropped or `stopObserving` is called.
    @discardableResult
    func observe(_ body: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = body
        return id
    }

    func stopObserving(_ id: UUID?) {
        guard let id else { return }
        observers[id] = nil
    }

    /// Something changed: the lists are fetched again shortly (many saves in a row make one reload).
    func setNeedsReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            reloadScheduled = false
            reload()
        }
    }

    func reload() {
        notes = (try? context.fetch(FetchDescriptor<Note>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        projects = (try? context.fetch(FetchDescriptor<NoteFolder>(sortBy: [SortDescriptor(\.name)]))) ?? []
        threads = (try? context.fetch(FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        generation += 1
        followIndexAndShare()
        notify()
    }

    private func notify() {
        for body in observers.values { body() }
    }

    func save() {
        try? context.save()
    }

    // MARK: Lookups

    func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        if let note = notes.first(where: { $0.id == id }) { return note }
        // Just made, and the lists are not fetched again yet.
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    func project(_ id: UUID?) -> NoteFolder? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func project(key: String?) -> NoteFolder? {
        guard let key else { return nil }
        return projects.first { Projects.key($0) == key }
    }

    var activeProjects: [NoteFolder] { HomeList.activeProjects(projects) }

    // MARK: Index and share sheet

    /// The search index follows the notes (only what changed is cut again); the share sheet reads the bowls
    /// from a file, it cannot open the store.
    private func followIndexAndShare() {
        let share = projects.filter { !$0.isArchived }.map { ShareInbox.Project(id: Projects.key($0), name: $0.name) }
        if share != lastShareProjects {
            lastShareProjects = share
            ShareInbox.writeProjects(share)
        }
        var hasher = Hasher()
        for note in notes {
            hasher.combine(note.id)
            hasher.combine(note.updatedAt)
            hasher.combine(note.summary?.utf8.count ?? 0)
            hasher.combine(note.segmentsData?.count ?? 0)
            hasher.combine(note.pageText?.utf8.count ?? 0)
            hasher.combine(note.isDeleted)
        }
        let signature = hasher.finalize()
        guard signature != lastIndexSignature else { return }
        lastIndexSignature = signature
        indexTask?.cancel()
        let notes = notes
        indexTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await NoteIndex.shared.refresh(notes)
            // New entries and those from other devices: what came in gets its summary (`AutoSummary`).
            self.processing.summarizeIncoming()
        }
    }
}
