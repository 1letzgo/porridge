import ImageIO
import PDFKit
import QuickLook
import SwiftUI

/// The files of a note in a row: images and PDFs with a small picture, other files with their name. A tap opens
/// the file in Quick Look; one that is only on another device cannot be opened here.
struct AttachmentStrip: View {
    let note: Note
    var onRemove: ((Attachment) -> Void)?

    @State private var preview: URL?
    @State private var error: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(note.attachments) { attachment in
                    Button { open(attachment) } label: {
                        AttachmentTile(attachment: attachment)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(attachment.name)
                    .accessibilityHint("Opens the file")
                    .contextMenu {
                        if let url = AttachmentStore.namedCopy(of: attachment) {
                            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                        if let onRemove {
                            Button(role: .destructive) { onRemove(attachment) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }
            .padding(.bottom, 4)
        }
        .quickLookPreview($preview)
        .alert("Could Not Open", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func open(_ attachment: Attachment) {
        if let url = AttachmentStore.namedCopy(of: attachment) {
            preview = url
        } else {
            error = "This file is on another device."
        }
    }
}

private struct AttachmentTile: View {
    let attachment: Attachment

    @State private var picture: CGImage?

    private var symbol: String {
        switch attachment.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .file: "doc"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06))
                if let picture {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(attachment.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120, alignment: .leading)
        }
        .task(id: attachment.fileName) {
            picture = await AttachmentThumbnail.load(attachment)
        }
    }
}

/// Small pictures of attachments, made once and kept while the app runs.
enum AttachmentThumbnail {
    private final class Box: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 80
        return cache
    }()

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
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                guard let context = CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { return nil }
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(origin: .zero, size: size))
                context.scaleBy(x: scale, y: scale)
                page.draw(with: .mediaBox, to: context)
                return context.makeImage()
            case .file:
                return nil
            }
        }.value
        if let image { cache.setObject(Box(image), forKey: key) }
        return image
    }
}
