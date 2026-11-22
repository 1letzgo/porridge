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
        let filter = SmartFilter(
            name: clean.isEmpty ? SmartFilters.suggestedName(for: criteria) : clean, criteria: criteria, createdAt: Self.wholeMillis(now)
        )
        file.filters.append(filter)
        changed()
        return filter
    }

    func rename(_ id: UUID, to name: String, now: Date = Date()) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = file.filters.firstIndex(where: { $0.id == id }), file.filters[index].name != clean else { return }
        file.filters[index].name = clean
        file.filters[index].updatedAt = Self.later(now, than: file.filters[index].updatedAt)
        changed()
    }

    func update(_ id: UUID, name: String? = nil, criteria: SmartFilterCriteria, now: Date = Date()) {
        guard let index = file.filters.firstIndex(where: { $0.id == id }) else { return }
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let clean, !clean.isEmpty { file.filters[index].name = clean }
        file.filters[index].criteria = criteria
        file.filters[index].updatedAt = Self.later(now, than: file.filters[index].updatedAt)
        changed()
    }

    func delete(_ id: UUID, now: Date = Date()) {
        guard let filter = file.filters.first(where: { $0.id == id }) else { return }
        file.filters.removeAll { $0.id == id }
        file.deleted[id.uuidString] = Self.later(now, than: filter.updatedAt)
        changed()
    }

    /// The file keeps dates to the millisecond: a change in the same millisecond as the one before it is moved a
    /// millisecond on, so every copy still sees it as the later one.
    nonisolated static func later(_ now: Date, than before: Date) -> Date {
        let next = millis(before) + 1
        return wholeMillis(Date(timeIntervalSince1970: Double(max(millis(now), next)) / 1000))
    }

    /// Milliseconds since 1970, as the file keeps them.
    nonisolated static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The date as the file keeps it (whole milliseconds): what is in memory then equals what is read back, so a
    /// reload finds nothing changed and writes nothing.
    nonisolated static func wholeMillis(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(millis(date)) / 1000)
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
        // Back once the copies have it, so whoever reads next finds the merged file.
        await writing?.value
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
                // What another device wrote in the meantime is kept: read, merge, write, one writer at a time here.
                return Self.cloudWrites.withLock {
                    let there = Self.readCloud(cloud)
                    let merged = there.map { SmartFilterFile.merged(snapshot, $0) } ?? snapshot
                    Self.write(merged, to: cloud, coordinated: true)
                    if merged != snapshot { Self.write(merged, to: local) }
                    return merged
                }
            }.value
            guard let self else { return }
            // Only taken over when nothing changed here while it was written.
            if merged != snapshot, self.file == snapshot { self.adopt(merged) }
        }
    }

    /// Read, merge and write of the copy in iCloud as one step within this app.
    nonisolated private static let cloudWrites = NSLock()

    private func resolvedCloudURL() async -> URL? {
        if !cloudResolved {
            cloudURL = await cloudFolder()?.appendingPathComponent(Self.fileName)
            cloudResolved = true
        }
        return cloudURL
    }

    /// ISO 8601 with milliseconds: two changes within one second must still tell which came last. Dates without
    /// fractions read too.
    /// Written from whole milliseconds and read back to the same value, so a date survives any number of round trips.
    nonisolated static let dateEncoding = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(dateText(date))
    }

    nonisolated static let dateDecoding = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let date = date(from: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return date
    }

    /// "2026-11-22T14:03:07.123Z".
    nonisolated static func dateText(_ date: Date) -> String {
        let ms = millis(date)
        var seconds = ms / 1000
        var fraction = ms % 1000
        if fraction < 0 { seconds -= 1; fraction += 1000 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let whole = formatter.string(from: Date(timeIntervalSince1970: Double(seconds)))
        return String(whole.dropLast()) + String(format: ".%03dZ", Int(fraction))
    }

    /// ISO 8601 with or without a fraction (only its milliseconds count); always a whole-millisecond date.
    nonisolated static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let dot = text.firstIndex(of: ".") else { return formatter.date(from: text).map(wholeMillis) }
        let rest = text[text.index(after: dot)...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let zone = rest.dropFirst(digits.count)
        guard let base = formatter.date(from: String(text[..<dot]) + zone) else { return nil }
        let ms = Int64(String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
        return Date(timeIntervalSince1970: Double(millis(base) + ms) / 1000)
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
