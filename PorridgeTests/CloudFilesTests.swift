import SwiftData
import XCTest
@testable import Porridge

/// Where recordings and attachments are found, and how they move into the iCloud container. Runs on folders of its
/// own: one stands for the folder on the device, one for the iCloud container.
@MainActor
final class CloudFilesTests: XCTestCase {
    private var root: URL!
    private var local: URL!
    private var cloud: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudFilesTests-\(UUID().uuidString)", isDirectory: true)
        local = root.appendingPathComponent("Recordings", isDirectory: true)
        cloud = root.appendingPathComponent("Container", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ url: URL, _ text: String = "x") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func cloudFile(_ name: String, _ kind: StoredFileKind) -> URL {
        cloud.appendingPathComponent(kind.folder, isDirectory: true).appendingPathComponent(name)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Finding files

    func testWithoutContainerEverythingIsOnTheDevice() throws {
        let files = FileLocations(local: local, cloud: nil)
        let name = AudioStore.newFileName()
        XCTAssertEqual(files.state(of: name, kind: .recording), .missing)
        XCTAssertEqual(files.url(for: name, kind: .recording), local.appendingPathComponent(name), "a new file is written here")
        XCTAssertNil(files.cloudURL(for: name, kind: .recording))
        try write(files.localURL(for: name))
        XCTAssertEqual(files.state(of: name, kind: .recording), .local(local.appendingPathComponent(name)))
        XCTAssertTrue(files.state(of: name, kind: .recording).isReadable)
    }

    func testNewFilesAreWrittenOnTheDeviceEvenWithAContainer() {
        let files = FileLocations(local: local, cloud: cloud)
        let name = AudioStore.newFileName()
        XCTAssertEqual(files.url(for: name, kind: .recording), local.appendingPathComponent(name), "never into iCloud directly")
        XCTAssertEqual(files.url(for: name, kind: .attachment), local.appendingPathComponent(name))
    }

    func testFilesInTheContainerAreFoundInTheFolderOfTheirKind() throws {
        let files = FileLocations(local: local, cloud: cloud)
        let recording = AudioStore.newFileName(), attachment = AudioStore.newFileName(extension: "pdf")
        try write(cloudFile(recording, .recording))
        try write(cloudFile(attachment, .attachment))
        XCTAssertEqual(files.state(of: recording, kind: .recording), .downloaded(cloudFile(recording, .recording)))
        XCTAssertEqual(files.url(for: attachment, kind: .attachment), cloudFile(attachment, .attachment))
        // A file in the other folder is still found.
        XCTAssertEqual(files.url(for: attachment, kind: .recording), cloudFile(attachment, .attachment))
    }

    func testTheCopyOnTheDeviceComesFirst() throws {
        let files = FileLocations(local: local, cloud: cloud)
        let name = AudioStore.newFileName()
        try write(cloudFile(name, .recording))
        try write(local.appendingPathComponent(name))
        XCTAssertEqual(files.state(of: name, kind: .recording), .local(local.appendingPathComponent(name)))
    }

    func testAStandInOfOlderSystemsMeansNotDownloaded() throws {
        let files = FileLocations(local: local, cloud: cloud)
        let name = AudioStore.newFileName()
        try write(FileLocations.placeholderURL(for: cloudFile(name, .recording)))
        let state = files.state(of: name, kind: .recording)
        XCTAssertEqual(state, .inCloud(cloudFile(name, .recording)))
        XCTAssertFalse(state.isReadable)
        XCTAssertEqual(files.url(for: name, kind: .recording), cloudFile(name, .recording))
    }

    func testNamesThatAreNoPlainNamesStayInside() {
        let files = FileLocations(local: local, cloud: cloud)
        for name in ["../x.m4a", "..", "sub/a.m4a", ".hidden", ""] {
            XCTAssertEqual(files.state(of: name, kind: .recording), .missing, name)
            XCTAssertNil(files.cloudURL(for: name, kind: .recording), name)
            XCTAssertEqual(files.url(for: name, kind: .recording).deletingLastPathComponent().standardizedFileURL, local.standardizedFileURL, name)
        }
    }

    // MARK: - Moving into iCloud

    func testUploadMovesEachFileIntoTheFolderOfItsKind() throws {
        let files = FileLocations(local: local, cloud: cloud)
        let recording = AudioStore.newFileName(), attachment = AudioStore.newFileName(extension: "jpg")
        try write(local.appendingPathComponent(recording), "audio")
        try write(local.appendingPathComponent(attachment), "picture")
        let report = files.upload([recording: .recording, attachment: .attachment], move: FileLocations.coordinatedMove)
        XCTAssertEqual(Set(report.moved), [recording, attachment])
        XCTAssertFalse(exists(local.appendingPathComponent(recording)))
        XCTAssertEqual(try String(contentsOf: cloudFile(recording, .recording), encoding: .utf8), "audio")
        XCTAssertEqual(try String(contentsOf: cloudFile(attachment, .attachment), encoding: .utf8), "picture")
        XCTAssertEqual(files.state(of: recording, kind: .recording), .downloaded(cloudFile(recording, .recording)))
    }

    func testUploadIsSafeToRunAgain() throws {
        let files = FileLocations(local: local, cloud: cloud)
        let name = AudioStore.newFileName()
        try write(local.appendingPathComponent(name))
        XCTAssertEqual(files.upload([name: .recording], move: FileLocations.coordinatedMove).moved, [name])
        let again = files.upload([name: .recording], move: FileLocations.coordinatedMove)
        XCTAssertEqual(again, FileLocations.UploadReport(), "nothing left to move")
        XCTAssertTrue(exists(cloudFile(name, .recording)))
    }

    func testUploadSkipsANameThatIsAlreadyInICloud() throws {
        let files = FileLocations(local: local, cloud: cloud)
        let name = AudioStore.newFileName()
        try write(local.appendingPathComponent(name), "here")
        try write(cloudFile(name, .recording), "there")
        let report = files.upload([name: .recording], move: FileLocations.coordinatedMove)
        XCTAssertEqual(report.skipped, [name])
        XCTAssertEqual(try String(contentsOf: local.appendingPathComponent(name), encoding: .utf8), "here", "the file here stays")
        XCTAssertEqual(try String(contentsOf: cloudFile(name, .recording), encoding: .utf8), "there", "and is not written over")
    }

    func testAFailedMoveKeepsTheFileHere() throws {
        let files = FileLocations(local: local, cloud: cloud)
        let name = AudioStore.newFileName()
        try write(local.appendingPathComponent(name))
        let report = files.upload([name: .recording]) { _, _ in throw CocoaError(.fileWriteUnknown) }
        XCTAssertEqual(report.failed, [name])
        XCTAssertTrue(exists(local.appendingPathComponent(name)))
        XCTAssertEqual(files.state(of: name, kind: .recording), .local(local.appendingPathComponent(name)))
    }

    func testUploadTouchesOnlyWantedFilesAndNothingWithoutAContainer() throws {
        let other = AudioStore.newFileName(), name = AudioStore.newFileName()
        try write(local.appendingPathComponent(other))
        try write(local.appendingPathComponent(name))
        XCTAssertEqual(FileLocations(local: local, cloud: nil).upload([name: .recording], move: FileLocations.coordinatedMove), FileLocations.UploadReport())
        XCTAssertTrue(exists(local.appendingPathComponent(name)))
        _ = FileLocations(local: local, cloud: cloud).upload([name: .recording, "missing.m4a": .recording], move: FileLocations.coordinatedMove)
        XCTAssertTrue(exists(local.appendingPathComponent(other)), "a running recording or a dictation is not in the list")
    }

    func testDeletingRemovesEveryCopyInICloud() throws {
        let files = FileLocations(local: local, cloud: cloud)
        let name = AudioStore.newFileName()
        try write(cloudFile(name, .recording))
        try write(cloudFile(name, .attachment))
        try write(FileLocations.placeholderURL(for: cloudFile(name, .recording)))
        files.deleteCloudCopies(of: name)
        XCTAssertTrue(files.cloudCopies(of: name).allSatisfy { !exists($0) })
        XCTAssertEqual(files.state(of: name, kind: .recording), .missing)
    }

    // MARK: - Which files move

    func testOnlyFilesOfNotesThatAreDoneMove() throws {
        let context = try TestStore.context()
        let done = Note(), waiting = Note(), continued = Note(), attached = Note()
        [done, waiting, continued, attached].forEach(context.insert)
        done.audioFileName = "a.m4a"
        done.audioFileNames = ["b.m4a"]
        waiting.audioFileName = "c.m4a"
        waiting.status = .transcribing
        continued.audioFileName = "d.m4a"
        continued.pendingAudioFileName = "e.m4a"
        continued.status = .recorded
        attached.attachments = [Attachment(fileName: "f.pdf", name: "Paper.pdf", kindRaw: Attachment.Kind.pdf.rawValue)]
        let present: Set<String> = ["a.m4a", "b.m4a", "c.m4a", "d.m4a", "e.m4a", "f.pdf"]
        let wanted = CloudFiles.filesToUpload([done, waiting, continued, attached], present: present)
        XCTAssertEqual(wanted, ["a.m4a": .recording, "b.m4a": .recording, "f.pdf": .attachment])
        // Files that are not here (already in iCloud, or on another device) are not asked for.
        XCTAssertEqual(CloudFiles.filesToUpload([done], present: ["b.m4a"]), ["b.m4a": .recording])
    }

    func testDownloadingWithoutICloudSaysTheFileIsElsewhere() async throws {
        guard AudioStore.cloudRoot == nil else { throw XCTSkip("this device has an iCloud container") }
        do {
            try await AudioStore.download(AudioStore.newFileName(), timeout: 1)
            XCTFail("a file that is nowhere cannot be downloaded")
        } catch let error as StoredFileError {
            XCTAssertEqual(error, .notOnThisDevice)
            XCTAssertEqual(error.localizedDescription, "This file is on another device.")
        }
    }
}
