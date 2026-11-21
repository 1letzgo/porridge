import Foundation

/// What a stored file is: it decides the folder in the iCloud container. On the device both kinds share one folder
/// (`AudioStore.directory`), as they always did.
enum StoredFileKind: String, CaseIterable, Sendable {
    case recording
    case attachment

    /// The folder in the iCloud container.
    var folder: String {
        switch self {
        case .recording: "Recordings"
        case .attachment: "Attachments"
        }
    }
}

/// Where a stored file is right now.
enum StoredFileState: Equatable, Sendable {
    /// In the folder on this device: recorded or added here and not (yet) moved to iCloud, or sync is off.
    case local(URL)
    /// In the iCloud container and downloaded: it can be read.
    case downloaded(URL)
    /// In the iCloud container, not downloaded: `FileManager.startDownloadingUbiquitousItem` fetches it.
    case inCloud(URL)
    /// Nowhere this device knows of: on another device, or not arrived in the container yet.
    case missing

    var isReadable: Bool {
        switch self {
        case .local, .downloaded: true
        case .inCloud, .missing: false
        }
    }

    var url: URL? {
        switch self {
        case .local(let url), .downloaded(let url), .inCloud(let url): url
        case .missing: nil
        }
    }
}

/// Where stored files are looked for: the folder on this device and, with iCloud, the app's iCloud container (its
/// `Recordings` and `Attachments` folders, outside `Documents`, so they never show in the user's iCloud Drive).
/// Pure: no global state, so the tests run it on folders of their own.
struct FileLocations: Sendable {
    /// The folder on this device (Application Support/Recordings).
    let local: URL
    /// The root of the iCloud container; nil without iCloud.
    let cloud: URL?

    /// Names come from other devices (through the synced notes): only file names, never paths.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.hasPrefix(".")
    }

    func localURL(for name: String) -> URL {
        local.appendingPathComponent(Self.isPlainName(name) ? name : ".invalid-name")
    }

    func cloudURL(for name: String, kind: StoredFileKind) -> URL? {
        guard let cloud, Self.isPlainName(name) else { return nil }
        return cloud.appendingPathComponent(kind.folder, isDirectory: true).appendingPathComponent(name)
    }

    /// The file to read or write: the one on this device while there is one; else the one in iCloud when it is
    /// there (downloaded or not); else the place on this device, where a new file is written. A recording is never
    /// written into iCloud directly: it moves there once it is finished (`upload`).
    func url(for name: String, kind: StoredFileKind) -> URL {
        switch state(of: name, kind: kind) {
        case .local(let url), .downloaded(let url), .inCloud(let url): url
        case .missing: localURL(for: name)
        }
    }

    func state(of name: String, kind: StoredFileKind) -> StoredFileState {
        guard Self.isPlainName(name) else { return .missing }
        let fileManager = FileManager.default
        let here = localURL(for: name)
        if fileManager.fileExists(atPath: here.path) { return .local(here) }
        guard cloud != nil else { return .missing }
        // Its own folder first; the other one too, so a file in the wrong folder is still found.
        for folder in [kind] + StoredFileKind.allCases.filter({ $0 != kind }) {
            guard let url = cloudURL(for: name, kind: folder) else { continue }
            if fileManager.fileExists(atPath: url.path) {
                // A file that is not downloaded is there with its name (dataless): only iCloud knows the difference.
                let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                    return .inCloud(url)
                }
                return .downloaded(url)
            }
            // Older systems leave a hidden stand-in (".name.icloud") instead.
            if fileManager.fileExists(atPath: Self.placeholderURL(for: url).path) { return .inCloud(url) }
        }
        return .missing
    }

    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    struct UploadReport: Equatable {
        var moved: [String] = []
        /// Already in iCloud under the same name: left alone on both sides.
        var skipped: [String] = []
        var failed: [String] = []
    }

    /// Moves the files of `wanted` that are on this device into the iCloud container, each into the folder of its
    /// kind. Safe to run again: a file already moved is no longer here, one whose name is already in iCloud is
    /// skipped, and a file stays where it is until `move` succeeded. `move` gets the file here and its target and
    /// must either move it or throw (`FileManager.setUbiquitous` in the app; a coordinated move in the tests).
    /// Not on the main thread: moving into iCloud waits for the file coordination.
    func upload(_ wanted: [String: StoredFileKind], move: (URL, URL) throws -> Void) -> UploadReport {
        var report = UploadReport()
        guard cloud != nil else { return report }
        let fileManager = FileManager.default
        for (name, kind) in wanted.sorted(by: { $0.key < $1.key }) {
            let source = localURL(for: name)
            guard Self.isPlainName(name), fileManager.fileExists(atPath: source.path),
                  let target = cloudURL(for: name, kind: kind) else { continue }
            let elsewhere = StoredFileKind.allCases.compactMap { cloudURL(for: name, kind: $0) }
            if elsewhere.contains(where: { fileManager.fileExists(atPath: $0.path) || fileManager.fileExists(atPath: Self.placeholderURL(for: $0).path) }) {
                report.skipped.append(name)
                continue
            }
            do {
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try move(source, target)
                report.moved.append(name)
            } catch {
                print("[files] \(name) not moved to iCloud: \(error.localizedDescription)")
                report.failed.append(name)
            }
        }
        return report
    }

    /// Every place the file can be in iCloud (both folders, and the stand-ins of older systems).
    func cloudCopies(of name: String) -> [URL] {
        StoredFileKind.allCases.compactMap { cloudURL(for: name, kind: $0) }.flatMap { [$0, Self.placeholderURL(for: $0)] }
    }

    /// Deletes the file in iCloud (coordinated, so iCloud deletes it on every device). Not on the main thread.
    func deleteCloudCopies(of name: String) {
        let fileManager = FileManager.default
        for url in cloudCopies(of: name) where fileManager.fileExists(atPath: url.path) {
            Self.coordinatedDelete(url)
        }
    }

    static func coordinatedDelete(_ url: URL) {
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do { try FileManager().removeItem(at: url) } catch { print("[files] could not delete \(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if let coordinationError { print("[files] could not delete \(url.lastPathComponent): \(coordinationError.localizedDescription)") }
    }

    /// Moves a file with file coordination on both ends (the tests' stand-in for `FileManager.setUbiquitous`).
    static func coordinatedMove(from source: URL, to target: URL) throws {
        var coordinationError: NSError?
        var moveError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: source, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordinationError
        ) { from, to in
            do { try FileManager().moveItem(at: from, to: to) } catch { moveError = error }
        }
        if let error = coordinationError ?? moveError { throw error }
    }
}
