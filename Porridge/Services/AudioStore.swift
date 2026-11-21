import AVFoundation
import Foundation

/// Why a stored file could not be read here.
enum StoredFileError: LocalizedError, Equatable {
    /// Sync is off (or there is no iCloud account): the file stays on the device it was added on.
    case notOnThisDevice
    /// iCloud does not have the file (yet): the device it was added on has not moved it there.
    case notInICloudYet
    case timedOut
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notOnThisDevice: "This file is on another device."
        case .notInICloudYet: "This file is not in iCloud yet. Open Porridge on the device it was added on, so it can upload it."
        case .timedOut: "The file could not be downloaded from iCloud in time. Check the connection and try again."
        case .downloadFailed(let reason): "The file could not be downloaded from iCloud. \(reason)"
        }
    }
}

/// Storage for recordings and attached files: the one place that knows where a file of a note is.
///
/// New files are written to a folder on this device (`directory`). With iCloud sync they move into the app's iCloud
/// container once their note is done (`CloudFiles`), recordings to `Recordings`, attachments to `Attachments`, and
/// iCloud brings them to the other devices; there they are downloaded when asked for (`download`). Without iCloud
/// (sync off, no account) everything stays in the folder on this device. Notes store only the file names.
enum AudioStore {
    /// The iCloud container of the app: the CloudKit database of the notes and, in it, the files.
    static let containerIdentifier = "iCloud.de.letzgo.porridge"

    /// The folder on this device.
    static let directory: URL = {
        let base = DataLocation.applicationSupport
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - The iCloud container

    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolvedCloud: URL?
    nonisolated(unsafe) private static var resolution: Task<URL?, Never>?
    /// Set once files went to iCloud: with sync turned off later the container is still looked in, so they stay readable.
    private static let usedCloudKey = "cloudFilesUsed"

    /// The root of the iCloud container, once found (`resolveCloudContainer`); nil without iCloud.
    static var cloudRoot: URL? { lock.withLock { resolvedCloud } }

    /// Whether finished files move into iCloud: sync is iCloud and the container is there.
    static var syncsFiles: Bool { SyncMode.active == .iCloud && cloudRoot != nil }

    static var locations: FileLocations { FileLocations(local: directory, cloud: cloudRoot) }

    /// Finds the iCloud container off the main thread (that call can take a while) and keeps it. Called at launch;
    /// later calls get the same answer. Never on test data, and with sync off only when files went to iCloud before.
    @discardableResult
    static func resolveCloudContainer() -> Task<URL?, Never> {
        lock.withLock {
            if let resolution { return resolution }
            let syncing = SyncMode.active == .iCloud
            let wanted = DataLocation.testFolder == nil && (syncing || UserDefaults.standard.bool(forKey: usedCloudKey))
            let task = Task.detached(priority: .userInitiated) { () -> URL? in
                guard wanted, let root = FileManager.default.url(forUbiquityContainerIdentifier: AudioStore.containerIdentifier) else { return nil }
                for kind in StoredFileKind.allCases {
                    try? FileManager.default.createDirectory(at: root.appendingPathComponent(kind.folder, isDirectory: true), withIntermediateDirectories: true)
                }
                AudioStore.lock.withLock { AudioStore.resolvedCloud = root }
                if syncing { UserDefaults.standard.set(true, forKey: AudioStore.usedCloudKey) }
                return root
            }
            resolution = task
            return task
        }
    }

    /// The iCloud container, waiting for `resolveCloudContainer` if it is still looking.
    static func cloudContainer() async -> URL? {
        await resolveCloudContainer().value
    }

    // MARK: - Names and places

    /// Names also come from other devices (through the synced notes): only file names, never paths.
    static func isPlainName(_ name: String) -> Bool {
        FileLocations.isPlainName(name)
    }

    /// Where the file is read: here while it is here, else in iCloud. Anything but a plain name points at a file
    /// that doesn't exist, never outside the store. For a new name: the place on this device, where it is written.
    static func url(for fileName: String, kind: StoredFileKind = .recording) -> URL {
        locations.url(for: fileName, kind: kind)
    }

    /// Where a new file is written: always on this device. A file never grows inside iCloud.
    static func localURL(for fileName: String) -> URL {
        locations.localURL(for: fileName)
    }

    static func state(of fileName: String?, kind: StoredFileKind = .recording) -> StoredFileState {
        guard let fileName else { return .missing }
        return locations.state(of: fileName, kind: kind)
    }

    static func newFileName(extension ext: String = "m4a") -> String {
        "\(UUID().uuidString).\(ext)"
    }

    /// The file can be read right now (here, or in iCloud and downloaded).
    static func exists(_ fileName: String?, kind: StoredFileKind = .recording) -> Bool {
        state(of: fileName, kind: kind).isReadable
    }

    /// The file is in iCloud and not downloaded yet: `download` brings it.
    static func isInCloud(_ fileName: String?, kind: StoredFileKind = .recording) -> Bool {
        if case .inCloud = state(of: fileName, kind: kind) { return true }
        return false
    }

    /// The file can be read now or after a download.
    static func isObtainable(_ fileName: String?, kind: StoredFileKind = .recording) -> Bool {
        state(of: fileName, kind: kind) != .missing
    }

    /// The file is in the folder on this device: added here and not in iCloud (yet).
    static func isLocal(_ fileName: String?) -> Bool {
        if case .local = state(of: fileName) { return true }
        return false
    }

    /// Deletes the file here and in iCloud, so it is gone on every device. The iCloud part runs in the background
    /// (coordinated), after the container was found.
    static func delete(_ fileName: String?) {
        guard let fileName, isPlainName(fileName) else { return }
        try? FileManager.default.removeItem(at: localURL(for: fileName))
        let local = directory
        Task.detached(priority: .utility) {
            guard let cloud = await AudioStore.cloudContainer() else { return }
            FileLocations(local: local, cloud: cloud).deleteCloudCopies(of: fileName)
        }
    }

    /// What "Delete Recording" does, for its confirmation.
    static var deleteRecordingMessage: String {
        cloudRoot != nil
            ? "The audio file is removed from all your devices. Transcript, speakers and summary stay."
            : "The audio file is removed from this device. Transcript, speakers and summary stay."
    }

    /// Copies an external audio/video file into the store and returns its new file name.
    static func importFile(from source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let name = newFileName(extension: ext)
        try FileManager.default.copyItem(at: source, to: localURL(for: name))
        return name
    }

    static func audioInfo(for fileName: String) -> (duration: Double, channels: Int)? {
        guard let file = try? AVAudioFile(forReading: url(for: fileName)) else { return nil }
        let format = file.processingFormat
        return (Double(file.length) / format.sampleRate, Int(format.channelCount))
    }

    // MARK: - Downloading

    /// Returns the file once it can be read, downloading it from iCloud first when it is only there. Waits a little
    /// for a file iCloud does not know yet (it may be on its way). Throws `StoredFileError` when sync is off and the
    /// file is not here, when iCloud does not have it, or when the download fails or takes longer than `timeout`.
    @discardableResult
    static func download(_ fileName: String, kind: StoredFileKind = .recording, timeout: TimeInterval = 600) async throws -> URL {
        _ = await cloudContainer()
        let start = Date()
        var lastRequest = Date.distantPast
        var lookup: CloudLookup?
        defer { if let lookup { Task { @MainActor in lookup.stop() } } }
        while true {
            let elapsed = Date().timeIntervalSince(start)
            switch locations.state(of: fileName, kind: kind) {
            case .local(let url):
                return url
            case .downloaded(let url):
                await coordinatedRead(url)
                return url
            case .inCloud(let url):
                if let reason = downloadError(at: url) { throw StoredFileError.downloadFailed(reason) }
                if Date().timeIntervalSince(lastRequest) > 15 {
                    lastRequest = Date()
                    do {
                        try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    } catch {
                        throw StoredFileError.downloadFailed(error.localizedDescription)
                    }
                }
            case .missing:
                guard cloudRoot != nil, isPlainName(fileName) else { throw StoredFileError.notOnThisDevice }
                // Asks iCloud about the file: the folder here learns of new files from it.
                if lookup == nil { lookup = await CloudLookup.start(fileName) }
                if elapsed > min(timeout, 45) { throw StoredFileError.notInICloudYet }
                if Date().timeIntervalSince(lastRequest) > 5, let url = locations.cloudURL(for: fileName, kind: kind) {
                    lastRequest = Date()
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }
            }
            if elapsed > timeout { throw StoredFileError.timedOut }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func downloadError(at url: URL) -> String? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey]))?.ubiquitousItemDownloadingError?.localizedDescription
    }

    /// Waits until nobody writes the file any more (iCloud putting the downloaded file in place).
    private static func coordinatedRead(_ url: URL) async {
        await Task.detached(priority: .userInitiated) {
            var error: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { _ in }
        }.value
    }
}

/// A metadata query for one file in the iCloud container, while it is waited for: it makes iCloud look for news
/// of the file instead of at its own pace. The results are not read; `AudioStore.download` looks at the file itself.
@MainActor
final class CloudLookup {
    private let query = NSMetadataQuery()

    static func start(_ fileName: String) -> CloudLookup {
        let lookup = CloudLookup()
        lookup.query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        lookup.query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, fileName)
        lookup.query.start()
        return lookup
    }

    func stop() {
        query.stop()
    }
}
