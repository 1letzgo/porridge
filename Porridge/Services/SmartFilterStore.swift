import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The smart filters of this person, kept as one JSON file, not in the database (no new fields in the synced store).
///
/// A copy is always on this device (Application Support/Porridge/smart-filters.json). With iCloud sync the same file
/// is also in the app's iCloud container (`Settings/smart-filters.json`, outside `Documents`, so it never shows in
/// iCloud Drive), and iCloud brings it to the other devices. Both copies are merged by filter (`SmartFilterFile.merged`):
/// the newer change wins, a deletion is remembered. Without iCloud only the copy here is used.
@MainActor
@Observable
final class SmartFilterStore {
    static let shared = SmartFilterStore(
        localURL: DataLocation.applicationSupport.appendingPathComponent("Porridge", isDirectory: true).appendingPathComponent(fileName),
        cloudFolder: {
            guard SyncMode.active == .iCloud, let root = await AudioStore.cloudContainer() else { return nil }
            return root.appendingPathComponent("Settings", isDirectory: true)
        },
        watches: DataLocation.testFolder == nil
    )

    static let fileName = "smart-filters.json"

    /// The filters by name.
    private(set) var filters: [SmartFilter] = []

    @ObservationIgnored private var file = SmartFilterFile()
    @ObservationIgnored private let localURL: URL
    @ObservationIgnored private let cloudFolder: () async -> URL?
    @ObservationIgnored private var cloudURL: URL?
    @ObservationIgnored private var cloudResolved = false
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    /// `cloudFolder` finds the folder in iCloud (nil without iCloud); `watches` follows changes made on other devices.
    init(localURL: URL, cloudFolder: @escaping () async -> URL?, watches: Bool = false) {
        self.localURL = localURL
        self.cloudFolder = cloudFolder
        if let local = Self.read(localURL) { adopt(local) }
        reloadTask = Task { await self.reload() }
        if watches { startWatching() }
    }

    func filter(_ id: UUID) -> SmartFilter? {
        filters.first { $0.id == id }
    }

    // MARK: Changing

    @discardableResult
    func add(name: String, criteria: SmartFilterCriteria, now: Date = Date()) -> SmartFilter {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let filter = SmartFilter(name: clean.isEmpty ? SmartFilters.suggestedName(for: criteria) : clean, criteria: criteria, createdAt: now)
        file.filters.append(filter)
        changed()
        return filter
    }

    func rename(_ id: UUID, to name: String, now: Date = Date()) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = file.filters.firstIndex(where: { $0.id == id }), file.filters[index].name != clean else { return }
        file.filters[index].name = clean
        file.filters[index].updatedAt = now
        changed()
    }

    func update(_ id: UUID, name: String? = nil, criteria: SmartFilterCriteria, now: Date = Date()) {
        guard let index = file.filters.firstIndex(where: { $0.id == id }) else { return }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clean, !clean.isEmpty { file.filters[index].name = clean }
        file.filters[index].criteria = criteria
        file.filters[index].updatedAt = now
        changed()
    }

    func delete(_ id: UUID, now: Date = Date()) {
        guard file.filters.contains(where: { $0.id == id }) else { return }
        file.filters.removeAll { $0.id == id }
        file.deleted[id.uuidString] = now
        changed()
    }

    private func changed() {
        filters = SmartFilters.sorted(file.filters)
        save()
    }

    private func adopt(_ next: SmartFilterFile) {
        file = next
        let sorted = SmartFilters.sorted(next.filters)
        if sorted != filters { filters = sorted }
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
        if let copy = found.local { merged = SmartFilterFile.merged(merged, copy) }
        if let copy = found.cloud { merged = SmartFilterFile.merged(merged, copy) }
        let changedHere = merged != file
        adopt(merged)
        // A copy that is behind (or missing) gets the merged file; nothing is written while there is nothing at all.
        let nothing = merged == SmartFilterFile() && found.local == nil && found.cloud == nil
        if !nothing, changedHere || found.local != merged || (cloud != nil && found.cloud != merged) { save() }
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
            let merged = await Task.detached(priority: .utility) { () -> SmartFilterFile in
                Self.write(snapshot, to: local)
                guard let cloud else { return snapshot }
                // What another device wrote in the meantime is kept: read, merge, write.
                let there = Self.readCloud(cloud)
                let merged = there.map { SmartFilterFile.merged(snapshot, $0) } ?? snapshot
                Self.write(merged, to: cloud, coordinated: true)
                if merged != snapshot { Self.write(merged, to: local) }
                return merged
            }.value
            guard let self else { return }
            // Only taken over when nothing changed here while it was written.
            if merged != snapshot, self.file == snapshot { self.adopt(merged) }
        }
    }

    private func resolvedCloudURL() async -> URL? {
        if !cloudResolved {
            cloudURL = await cloudFolder()?.appendingPathComponent(Self.fileName)
            cloudResolved = true
        }
        return cloudURL
    }

    /// ISO 8601 with milliseconds: two changes within one second must still tell which came last. Dates without
    /// fractions read too.
    nonisolated static let dateEncoding = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var container = encoder.singleValueContainer()
        try container.encode(formatter.string(from: date))
    }

    nonisolated static let dateDecoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
    }

    nonisolated private static func decode(_ data: Data) -> SmartFilterFile? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecoding
        return try? decoder.decode(SmartFilterFile.self, from: data)
    }

    nonisolated static func read(_ url: URL) -> SmartFilterFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// The copy in iCloud, read coordinated; versions two devices wrote at the same time are merged into it.
    nonisolated static func readCloud(_ url: URL) -> SmartFilterFile? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        var result: SmartFilterFile?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { url in
            result = read(url)
        }
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !conflicts.isEmpty else { return result }
        for version in conflicts {
            if let other = read(version.url) { result = result.map { SmartFilterFile.merged($0, other) } ?? other }
            version.isResolved = true
        }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        return result
    }

    nonisolated static func write(_ file: SmartFilterFile, to url: URL, coordinated: Bool = false) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = dateEncoding
        guard let data = try? encoder.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard coordinated else {
            try? data.write(to: url, options: .atomic)
            return
        }
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            do { try data.write(to: url, options: .atomic) } catch { print("[smart filters] not written: \(error.localizedDescription)") }
        }
        if let error { print("[smart filters] not written: \(error.localizedDescription)") }
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
            // iCloud tells of a new version of the file through a metadata query.
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
            query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, Self.fileName)
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
                observers.append(center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reloadSoon() }
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
