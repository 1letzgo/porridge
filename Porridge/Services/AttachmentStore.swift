import Foundation
import UniformTypeIdentifiers

/// The files that belong to notes (shared images, PDFs, documents). They live in the store of the recordings
/// (`AudioStore`), so the sync carries them, cleans up after them and fetches them on demand the same way.
enum AttachmentStore {
    /// Copies a file into the store and describes it.
    static func add(_ source: URL, name: String) throws -> Attachment {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        let fileName = AudioStore.newFileName(extension: ext.isEmpty ? "bin" : ext)
        try FileManager.default.copyItem(at: source, to: AudioStore.url(for: fileName))
        let bytes = (try? FileManager.default.attributesOfItem(atPath: AudioStore.url(for: fileName).path)[.size] as? NSNumber)?.int64Value ?? 0
        return Attachment(fileName: fileName, name: name.isEmpty ? source.lastPathComponent : name, kindRaw: kind(ofExtension: ext).rawValue, bytes: bytes)
    }

    static func kind(ofExtension ext: String) -> Attachment.Kind {
        guard let type = UTType(filenameExtension: ext) else { return .file }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        return .file
    }

    static func url(for attachment: Attachment) -> URL { AudioStore.url(for: attachment.fileName) }

    static func exists(_ attachment: Attachment) -> Bool { AudioStore.exists(attachment.fileName) }

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
