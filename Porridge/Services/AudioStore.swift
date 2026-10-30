import AVFoundation
import Foundation

/// Local, non-synced storage for recordings.
enum AudioStore {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    static func newFileName(extension ext: String = "m4a") -> String {
        "\(UUID().uuidString).\(ext)"
    }

    static func exists(_ fileName: String?) -> Bool {
        guard let fileName else { return false }
        return FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    static func delete(_ fileName: String?) {
        guard let fileName else { return }
        try? FileManager.default.removeItem(at: url(for: fileName))
    }

    /// Copies an external audio/video file into the store and returns its new file name.
    static func importFile(from source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased()
        let name = newFileName(extension: ext)
        try FileManager.default.copyItem(at: source, to: url(for: name))
        return name
    }

    static func audioInfo(for fileName: String) -> (duration: Double, channels: Int)? {
        guard let file = try? AVAudioFile(forReading: url(for: fileName)) else { return nil }
        let format = file.processingFormat
        return (Double(file.length) / format.sampleRate, Int(format.channelCount))
    }
}
