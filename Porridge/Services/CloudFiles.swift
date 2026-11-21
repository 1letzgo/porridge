import Foundation
import SwiftData

/// Moves the files of notes into iCloud, so the other devices get them (`AudioStore`). At launch this moves what an
/// earlier version kept on the device only; after that, each time the notes were saved, the files of notes that are
/// done. A file is never moved while it is written or worked on: a running recording has no note yet, and a note
/// that waits for or is in its transcription (or the reading of its files) keeps its files here until it is done.
@MainActor
enum CloudFiles {
    private static var container: ModelContainer?
    private static var observer: NSObjectProtocol?
    private static var pending: Task<Void, Never>?
    private static var isUploading = false
    private static var uploadAgain = false

    /// At launch (both apps): looks for the iCloud container off the main thread and, with iCloud sync, starts moving
    /// files into it. Not on the empty store of a failed launch: it has no notes to tell which files are whose.
    static func start(_ container: ModelContainer) {
        AudioStore.resolveCloudContainer()
        guard self.container == nil, SyncMode.active == .iCloud, AppContainer.storeError == nil else { return }
        self.container = container
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { uploadSoon(after: .seconds(3)) }
        }
        uploadSoon(after: .zero)
    }

    /// Moves files a little later; saves come in bursts.
    static func uploadSoon(after delay: Duration) {
        guard container != nil else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await upload()
        }
    }

    private static func upload() async {
        guard let container else { return }
        guard !isUploading else {
            uploadAgain = true
            return
        }
        isUploading = true
        defer {
            isUploading = false
            if uploadAgain {
                uploadAgain = false
                uploadSoon(after: .seconds(1))
            }
        }
        guard SyncMode.active == .iCloud, let cloud = await AudioStore.cloudContainer() else { return }
        let local = AudioStore.directory
        let present = Set((try? FileManager.default.contentsOfDirectory(atPath: local.path)) ?? [])
        guard !present.isEmpty else { return }
        let notes = (try? container.mainContext.fetch(FetchDescriptor<Note>())) ?? []
        let wanted = filesToUpload(notes, present: present)
        guard !wanted.isEmpty else { return }
        let locations = FileLocations(local: local, cloud: cloud)
        let report = await Task.detached(priority: .utility) {
            locations.upload(wanted) { source, target in
                // Moves the file into iCloud, coordinated; it stays here when that fails.
                try FileManager().setUbiquitous(true, itemAt: source, destinationURL: target)
            }
        }.value
        if !report.moved.isEmpty || !report.failed.isEmpty {
            print("[files] to iCloud: \(report.moved.count) moved, \(report.skipped.count) already there, \(report.failed.count) failed")
        }
    }

    /// The files of `notes` that are in the folder here (`present`) and may move into iCloud, with their kind. Only
    /// notes that are done: one waiting for or in its transcription, or for the text of its files, keeps them here
    /// until it is done (the work reads them). A part recorded later (`pendingAudioFileName`) is still being worked on.
    static func filesToUpload(_ notes: [Note], present: Set<String>) -> [String: StoredFileKind] {
        var wanted: [String: StoredFileKind] = [:]
        for note in notes where note.status == .ready || note.status == .failed {
            for name in [note.audioFileName].compactMap({ $0 }) + note.audioFileNames where present.contains(name) {
                wanted[name] = .recording
            }
            for attachment in note.attachments where present.contains(attachment.fileName) {
                wanted[attachment.fileName] = .attachment
            }
        }
        return wanted
    }
}
