import AppKit
import ImageIO
import PDFKit

/// Small pictures of attachments (images and the first page of a PDF), made off the main thread and kept a while.
enum Thumbnails {
    private final class Box: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 120
        return cache
    }()

    static func cached(_ attachment: Attachment, maxPixels: Int) -> CGImage? {
        cache.object(forKey: "\(attachment.fileName)-\(maxPixels)" as NSString)?.image
    }

    static func load(_ attachment: Attachment, maxPixels: Int = 360) async -> CGImage? {
        let key = "\(attachment.fileName)-\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        guard attachment.kind != .file, AttachmentStore.exists(attachment) else { return nil }
        let url = AttachmentStore.url(for: attachment)
        let kind = attachment.kind
        let image = await Task.detached(priority: .utility) { () -> CGImage? in
            switch kind {
            case .image:
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                ]
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            case .pdf:
                guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { return nil }
                let scale = CGFloat(maxPixels) / max(bounds.width, bounds.height)
                let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
                return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            case .file:
                return nil
            }
        }.value
        if let image { cache.setObject(Box(image), forKey: key) }
        return image
    }
}
