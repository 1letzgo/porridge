import AppKit

/// What Continuity Camera brings from the iPhone or iPad: scanned pages as a PDF, a photo or a sketch as an image.
/// Written to a temporary file that comes in like a dropped one (`Intake.addFiles`).
@MainActor
enum DeviceImport {
    /// What the app takes, best first: scans come as PDF, photos as JPEG or TIFF.
    static let types: [NSPasteboard.PasteboardType] = [.pdf, NSPasteboard.PasteboardType("public.jpeg"), .png, .tiff]

    static func file(from pasteboard: NSPasteboard, date: Date = Date()) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceImport/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = date.formatted(date: .abbreviated, time: .shortened).replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        if let pdf = pasteboard.data(forType: .pdf) {
            return write(pdf, to: folder.appendingPathComponent(String(localized: "Scan \(stamp)") + ".pdf"))
        }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")) {
            return write(jpeg, to: folder.appendingPathComponent(String(localized: "Photo \(stamp)") + ".jpg"))
        }
        if let png = pasteboard.data(forType: .png) {
            return write(png, to: folder.appendingPathComponent(String(localized: "Photo \(stamp)") + ".png"))
        }
        // TIFF is large: kept as JPEG.
        if let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff),
           let jpeg = image.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            return write(jpeg, to: folder.appendingPathComponent(String(localized: "Photo \(stamp)") + ".jpg"))
        }
        return nil
    }

    private static func write(_ data: Data, to url: URL) -> URL? {
        do {
            try data.write(to: url)
            return url
        } catch {
            print("[import] not written: \(error.localizedDescription)")
            return nil
        }
    }
}
