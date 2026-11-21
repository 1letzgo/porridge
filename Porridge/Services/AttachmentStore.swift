import Foundation
import UniformTypeIdentifiers

/// The files that belong to notes (shared images, PDFs, documents). They live in the store of the recordings
/// (`AudioStore`): on this device in the same folder, in iCloud in `Attachments`; they move there, are deleted and
/// are downloaded on demand the same way.
enum AttachmentStore {
    /// Copies a file into the store and describes it.
    static func add(_ source: URL, name: String) throws -> Attachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        let fileName = AudioStore.newFileName(extension: ext.isEmpty ? "bin" : ext)
        let target = AudioStore.localURL(for: fileName)
        try FileManager.default.copyItem(at: source, to: target)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Attachment(fileName: fileName, name: name.isEmpty ? source.lastPathComponent : name, kindRaw: kind(ofExtension: ext).rawValue, bytes: bytes)
    }

    static func kind(ofExtension ext: String) -> Attachment.Kind {
        guard let type = UTType(filenameExtension: ext) else { return .file }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return .file
    }

    static func url(for attachment: Attachment) -> URL { AudioStore.url(for: attachment.fileName, kind: .attachment) }

    /// The file can be read right now.
    static func exists(_ attachment: Attachment) -> Bool { AudioStore.exists(attachment.fileName, kind: .attachment) }

    /// The file is in iCloud and not downloaded yet.
    static func isInCloud(_ attachment: Attachment) -> Bool { AudioStore.isInCloud(attachment.fileName, kind: .attachment) }

    /// The file, downloaded from iCloud first when it is only there (see `AudioStore.download`).
    @discardableResult
    static func download(_ attachment: Attachment, timeout: TimeInterval = 300) async throws -> URL {
        try await AudioStore.download(attachment.fileName, kind: .attachment, timeout: timeout)
    }

    /// For a small picture of the file: whether it can be read, downloading a file of usual size (up to 25 MB) from
    /// iCloud first. A bigger one shows its symbol until it is opened.
    static func fetchForThumbnail(_ attachment: Attachment) async -> Bool {
        if exists(attachment) { return true }
        _ = await AudioStore.cloudContainer()
        if exists(attachment) { return true }
        guard isInCloud(attachment), attachment.bytes <= 25_000_000 else { return false }
        return (try? await download(attachment, timeout: 120)) != nil
    }

    /// Like `namedCopy`, downloading the file first when it is only in iCloud.
    static func fetchNamedCopy(of attachment: Attachment) async throws -> URL {
        try await download(attachment)
        guard let url = namedCopy(of: attachment) else { throw StoredFileError.notOnThisDevice }
        return url
    }

    /// A link with the file's own name, for Quick Look and sharing (the store names files by id). Nil while the
    /// file is not on this device.
    static func namedCopy(of attachment: Attachment) -> URL? {
        guard exists(attachment) else { return nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Attachments/\(attachment.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = attachment.name.replacingOccurrences(of: "/", with: "-")
        let ext = (attachment.fileName as NSString).pathExtension
        if (name as NSString).pathExtension.lowercased() != ext, !ext.isEmpty, ext != "bin" { name += "." + ext }
        let target = folder.appendingPathComponent(name.isEmpty ? attachment.fileName : name)
        if !FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.linkItem(at: url(for: attachment), to: target) }
            catch { try? FileManager.default.copyItem(at: url(for: attachment), to: target) }
        }
        return FileManager.default.fileExists(atPath: target.path) ? target : nil
    }
}
