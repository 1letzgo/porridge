import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The note templates of this person, kept as one JSON file, not in the database (no new fields in the synced
/// store). Built like `SmartFilterStore`, and with its date handling:
///
/// A copy is always on this device (Application Support/Porridge/note-templates.json). With iCloud sync the same
/// file is also in the app's iCloud container (`Settings/note-templates.json`, outside `Documents`, so it never
/// shows in iCloud Drive), and iCloud brings it to the other devices. Both copies are merged by template
/// (`NoteTemplateFile.merged`): the newer change wins, a deletion is remembered. Without iCloud only the copy here
/// is used.
///
/// Someone with no templates at all (none here, none in iCloud, none ever deleted) gets the two examples once
/// (`NoteTemplates.examples`).
@MainActor
@Observable
final class NoteTemplateStore {
    static let shared = NoteTemplateStore(
        localURL: DataLocation.applicationSupport.appendingPathComponent("Porridge", isDirectory: true).appendingPathComponent(fileName),
        cloudFolder: {
            guard SyncMode.active == .iCloud, let root = await AudioStore.cloudContainer() else { return nil }
            return root.appendingPathComponent("Settings", isDirectory: true)
        },
        watches: DataLocation.testFolder == nil,
        examplesKey: DataLocation.testFolder == nil ? "noteTemplatesExamplesAdded" : nil
    )

    static let fileName = "note-templates.json"

    /// The templates by name.
    private(set) var templates: [NoteTemplate] = []

    @ObservationIgnored private var file = NoteTemplateFile()
    @ObservationIgnored private let localURL: URL
    @ObservationIgnored private let cloudFolder: () async -> URL?
    @ObservationIgnored private var cloudURL: URL?
    @ObservationIgnored private var cloudResolved = false
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// The defaults key that remembers the examples were offered on this device; nil = never offer them.
    @ObservationIgnored private let examplesKey: String?
    @ObservationIgnored private let defaults: UserDefaults
    /// What iCloud holds is known: its copy was read, or iCloud said there is none. Until then no examples are
    /// added (a copy not downloaded yet would be overwritten by them).
    @ObservationIgnored private var cloudKnown = false

    /// `cloudFolder` finds the folder in iCloud (nil without iCloud); `watches` follows changes made on other
    /// devices; `examplesKey` turns the examples on.
    init(
        localURL: URL, cloudFolder: @escaping () async -> URL?, watches: Bool = false, examplesKey: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.localURL = localURL
        self.cloudFolder = cloudFolder
        self.examplesKey = examplesKey
        self.defaults = defaults
        if let local = Self.read(localURL) { adopt(local) }
        reloadTask = Task { await self.reload() }
        if watches { startWatching() }
    }

    func template(_ id: UUID) -> NoteTemplate? {
        templates.first { $0.id == id }
    }

    // MARK: Changing

    /// Adds a template (a new one, a copy, one put back by Undo) as it is, with its id.
    @discardableResult
    func add(_ template: NoteTemplate, now: Date = Date()) -> NoteTemplate {
        var template = template
        template.name = Self.cleanName(template.name)
        template.createdAt = SmartFilterStore.wholeMillis(template.createdAt)
        // Put back after a deletion: newer than the deletion, so the merge keeps it.
        let gone = file.deleted[template.id.uuidString]
        template.updatedAt = SmartFilterStore.later(now, than: max(template.updatedAt, gone ?? .distantPast))
        file.deleted[template.id.uuidString] = nil
        file.templates.removeAll { $0.id == template.id }
        file.templates.append(template)
        changed()
        return template
    }

    /// Saves the changed template (found by its id).
    func update(_ template: NoteTemplate, now: Date = Date()) {
        guard let index = file.templates.firstIndex(where: { $0.id == template.id }) else { return }
        var next = template
        next.name = Self.cleanName(template.name)
        next.createdAt = file.templates[index].createdAt
        next.updatedAt = file.templates[index].updatedAt
        guard next != file.templates[index] else { return }
        next.updatedAt = SmartFilterStore.later(now, than: file.templates[index].updatedAt)
        file.templates[index] = next
        changed()
    }

    func rename(_ id: UUID, to name: String, now: Date = Date()) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var template = template(id), template.name != clean else { return }
        template.name = clean
        update(template, now: now)
    }

    @discardableResult
    func duplicate(_ id: UUID, now: Date = Date()) -> NoteTemplate? {
        guard let template = template(id) else { return nil }
        return add(NoteTemplates.duplicate(template, now: now), now: now)
    }

    /// Takes the template away; returns it, for Undo (`add` puts it back).
    @discardableResult
    func delete(_ id: UUID, now: Date = Date()) -> NoteTemplate? {
        guard let template = file.templates.first(where: { $0.id == id }) else { return nil }
        file.templates.removeAll { $0.id == id }
        file.deleted[id.uuidString] = SmartFilterStore.later(now, than: template.updatedAt)
        changed()
        return template
    }

    private static func cleanName(_ name: String) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? String(localized: "Template") : clean
    }

    private func changed() {
        templates = NoteTemplates.sorted(file.templates)
        save()
    }

    private func adopt(_ next: NoteTemplateFile) {
        file = next
        let sorted = NoteTemplates.sorted(next.templates)
        if sorted != templates { templates = sorted }
    }

    /// The examples, once per device, for someone who has never had a template: after the first reload, so what
    /// iCloud has is known. Their fixed ids keep two devices from adding them twice.
    func addExamplesIfNone() {
        guard let examplesKey, !defaults.bool(forKey: examplesKey), cloudResolved, cloudURL == nil || cloudKnown else { return }
        defaults.set(true, forKey: examplesKey)
        guard file.templates.isEmpty, file.deleted.isEmpty else { return }
        file.templates = NoteTemplates.examples
        changed()
    }

    // MARK: Files

    /// Reads both copies again and merges them (at launch, when the app comes to the front, when iCloud brought a
    /// new version). Writes back what the merge changed.
    func reload() async {
        if !cloudResolved {
            cloudURL = await cloudFolder()?.appendingPathComponent(Self.fileName)
            cloudResolved = true
        }
        await writing?.value
        let local = localURL
        let cloud = cloudURL
        let found = await Task.detached(priority: .utility) {
            (local: Self.read(local), cloud: cloud.flatMap { Self.readCloud($0) })
        }.value
        var merged = file
        if let copy = found.local { merged = NoteTemplateFile.merged(merged, copy) }
        if let copy = found.cloud { merged = NoteTemplateFile.merged(merged, copy) }
        let changedHere = merged != file
        adopt(merged)
        let nothing = merged == NoteTemplateFile() && found.local == nil && found.cloud == nil
        if !nothing, changedHere || found.local != merged || (cloud != nil && found.cloud != merged) { save() }
        if found.cloud != nil { cloudKnown = true }
        await writing?.value
        addExamplesIfNone()
    }

    /// Waits until what was changed is written (tests).
    func flush() async {
        await reloadTask?.value
        await writing?.value
    }

    private func save() {
        let snapshot = file
        let local = localURL
        let previous = writing
        writing = Task { [weak self] in
            await previous?.value
            let cloud = await self?.resolvedCloudURL()
            let merged = await Task.detached(priority: .utility) { () -> NoteTemplateFile in
                Self.write(snapshot, to: local)
                guard let cloud else { return snapshot }
                // What another device wrote in the meantime is kept: read, merge, write, one writer at a time here.
                return Self.cloudWrites.withLock {
                    let there = Self.readCloud(cloud)
                    let merged = there.map { NoteTemplateFile.merged(snapshot, $0) } ?? snapshot
                    Self.write(merged, to: cloud, coordinated: true)
                    if merged != snapshot { Self.write(merged, to: local) }
                    return merged
                }
            }.value
            guard let self else { return }
            if merged != snapshot, self.file == snapshot { self.adopt(merged) }
        }
    }

    nonisolated private static let cloudWrites = NSLock()

    private func resolvedCloudURL() async -> URL? {
        if !cloudResolved {
            cloudURL = await cloudFolder()?.appendingPathComponent(Self.fileName)
            cloudResolved = true
        }
        return cloudURL
    }

    nonisolated static func read(_ url: URL) -> NoteTemplateFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SmartFilterStore.dateDecoding
        return try? decoder.decode(NoteTemplateFile.self, from: data)
    }

    /// The copy in iCloud, read coordinated; versions two devices wrote at the same time are merged into it.
    nonisolated static func readCloud(_ url: URL) -> NoteTemplateFile? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        var result: NoteTemplateFile?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = read(url)
        }
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return result }
        for version in conflicts {
            if let other = read(version.url) { result = result.map { NoteTemplateFile.merged($0, other) } ?? other }
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return result
    }

    nonisolated static func write(_ file: NoteTemplateFile, to url: URL, coordinated: Bool = false) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = SmartFilterStore.dateEncoding
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard coordinated else {
            try? data.write(to: url, options: .atomic)
            return
        }
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            do { try data.write(to: url, options: .atomic) } catch { print("[note templates] not written: \(error.localizedDescription)") }
        }
        if let error { print("[note templates] not written: \(error.localizedDescription)") }
    }

    // MARK: Following other devices

    private func startWatching() {
        let center = NotificationCenter.default
        #if os(iOS)
        let active = UIApplication.didBecomeActiveNotification
        #else
        let active = NSApplication.didBecomeActiveNotification
        #endif
        observers.append(center.addObserver(forName: active, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSoon() }
        })
        Task {
            guard await resolvedCloudURL() != nil else { return }
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, Self.fileName)
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
                observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        // iCloud has looked and found no file: nobody has templates yet.
                        if notification.name == .NSMetadataQueryDidFinishGathering, (notification.object as? NSMetadataQuery)?.resultCount == 0 {
                            self?.cloudKnown = true
                        }
                        self?.reloadSoon()
                    }
                })
            }
            query.start()
            self.query = query
        }
    }

    private func reloadSoon() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }
}
