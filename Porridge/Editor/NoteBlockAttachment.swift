import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension NSAttributedString.Key {
    /// On the attachment character of a block (table, image, divider): its Markdown source, written back as it is.
    static let noteRawBlock = NSAttributedString.Key("PorridgeNoteRawBlock")
}

extension Notification.Name {
    /// An inline image was loaded (or downloaded from iCloud); `object` is its file name. Editors showing it draw it.
    static let noteInlineImageReady = Notification.Name("PorridgeNoteInlineImageReady")
}

/// A table, an image or a divider in the editor: one attachment character that draws the block across the width
/// of the text. Its size follows the width it is given (TextKit 2 asks for it per line), so a table wraps its
/// cells and an image scales down on a narrow screen.
final class NoteBlockAttachment: NSTextAttachment {
    let block: RichBlock
    let source: String

    init(block: RichBlock, source: String) {
        self.block = block
        self.source = source
        super.init(data: nil, ofType: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The width a block may take: the line's, or the container's when the line has none yet.
    private func available(_ proposed: CGRect, _ container: NSTextContainer?) -> CGFloat {
        var width = proposed.width
        if !(width.isFinite && width > 20 && width < 5000) { width = container?.size.width ?? 0 }
        if !(width.isFinite && width > 20 && width < 5000) { width = 600 }
        return floor(width - 2)
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
        proposedLineFragment: CGRect, position: CGPoint
    ) -> CGRect {
        let width = available(proposedLineFragment, textContainer)
        return CGRect(origin: .zero, size: NoteBlockRenderer.size(of: block, width: width))
    }

    override func image(
        for bounds: CGRect, attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?
    ) -> PlatformImage? {
        NoteBlockRenderer.image(of: block, size: bounds.size)
    }
}

extension NoteMarkdown {
    /// The attachment character of a block, with its source for `markdown(from:)`.
    static func blockString(_ block: RichBlock, source: String) -> NSAttributedString {
        let attachment = NoteBlockAttachment(block: block, source: source)
        let result = NSMutableAttributedString(attachment: attachment)
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        style.paragraphSpacingBefore = 4
        result.addAttributes([
            .noteRawBlock: source,
            .font: baseFont(kind: .paragraph),
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: result.length))
        return result
    }
}

// MARK: - Drawing

/// Sizes and pictures of blocks. Pictures are cached by block and size; iOS gets a light and a dark variant.
enum NoteBlockRenderer {
    private final class Box: NSObject {
        let image: PlatformImage
        init(_ image: PlatformImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 60
        return cache
    }()

    static func size(of block: RichBlock, width: CGFloat) -> CGSize {
        switch block {
        case .divider:
            return CGSize(width: width, height: 18)
        case .table(let table):
            return TableLayout(table, maxWidth: width).size
        case .image(let ref):
            guard let image = InlineImages.image(for: ref.fileName) else { return CGSize(width: min(width, 320), height: 120) }
            let natural = image.size
            guard natural.width > 0, natural.height > 0 else { return CGSize(width: min(width, 320), height: 120) }
            let scale = min(1, width / natural.width, 520 / natural.height)
            return CGSize(width: floor(natural.width * scale), height: floor(natural.height * scale))
        }
    }

    static func image(of block: RichBlock, size: CGSize) -> PlatformImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        if case .image(let ref) = block {
            return InlineImages.image(for: ref.fileName) ?? placeholder(size: size)
        }
        let key = "\(block.markdown.hashValue)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = cache.object(forKey: key) { return resolved(cached.image) }
        let image = render(size: size) { rect in
            switch block {
            case .divider:
                let line = CGRect(x: 0, y: floor(rect.midY), width: rect.width, height: 1)
                fill(line, color: separator)
            case .table(let table):
                TableLayout(table, maxWidth: size.width).draw(in: rect)
            case .image:
                break
            }
        }
        cache.setObject(Box(image), forKey: key)
        return resolved(image)
    }

    private static func placeholder(size: CGSize) -> PlatformImage {
        render(size: size) { rect in
            fill(rect, color: fillColor, radius: 10)
            let text = NSAttributedString(string: String(localized: "Image"), attributes: [
                .font: PlatformFont.preferredFont(forTextStyle: .footnote), .foregroundColor: NoteMarkdown.secondaryColor,
            ])
            let textSize = text.size()
            text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
        }
    }

    // MARK: Platform drawing

    static var separator: PlatformColor {
        #if os(macOS)
        .separatorColor
        #else
        .separator
        #endif
    }

    static var fillColor: PlatformColor {
        #if os(macOS)
        .quaternaryLabelColor
        #else
        .quaternarySystemFill
        #endif
    }

    static var headerFill: PlatformColor {
        #if os(macOS)
        NSColor.labelColor.withAlphaComponent(0.06)
        #else
        .tertiarySystemFill
        #endif
    }

    static func fill(_ rect: CGRect, color: PlatformColor, radius: CGFloat = 0) {
        color.setFill()
        #if os(macOS)
        (radius > 0 ? NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius) : NSBezierPath(rect: rect)).fill()
        #else
        (radius > 0 ? UIBezierPath(roundedRect: rect, cornerRadius: radius) : UIBezierPath(rect: rect)).fill()
        #endif
    }

    static func stroke(_ rect: CGRect, color: PlatformColor, radius: CGFloat, width: CGFloat = 1) {
        color.setStroke()
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        #if os(macOS)
        let path = NSBezierPath(roundedRect: inset, xRadius: radius, yRadius: radius)
        #else
        let path = UIBezierPath(roundedRect: inset, cornerRadius: radius)
        #endif
        path.lineWidth = width
        path.stroke()
    }

    /// A picture drawn top-down. On the Mac it is drawn when shown (so in the window's appearance); on iOS once
    /// for light and once for dark.
    static func render(size: CGSize, _ draw: @escaping (CGRect) -> Void) -> PlatformImage {
        #if os(macOS)
        return NSImage(size: size, flipped: true) { rect in
            draw(rect)
            return true
        }
        #else
        let asset = UIImageAsset()
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let renderer = UIGraphicsImageRenderer(size: size, format: UIGraphicsImageRendererFormat(for: traits))
            let image = renderer.image { _ in traits.performAsCurrent { draw(CGRect(origin: .zero, size: size)) } }
            asset.register(image, with: traits)
        }
        return asset.image(with: .current)
        #endif
    }

    private static func resolved(_ image: PlatformImage) -> PlatformImage {
        #if os(macOS)
        return image
        #else
        return image.imageAsset?.image(with: .current) ?? image
        #endif
    }
}

// MARK: - Table layout

/// Columns as wide as their text, narrowed to fit the width (cells then wrap); a header row with a tint, hairlines
/// between cells, a rounded border.
struct TableLayout {
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 5
    static let minimumColumn: CGFloat = 44

    let header: [NSAttributedString]
    let rows: [[NSAttributedString]]
    let columnWidths: [CGFloat]
    let rowHeights: [CGFloat]

    var size: CGSize {
        CGSize(width: ceil(columnWidths.reduce(0, +)), height: ceil(rowHeights.reduce(0, +)))
    }

    init(_ table: MarkdownTable, maxWidth: CGFloat) {
        let columns = table.columnCount
        let header = table.header.enumerated().map { Self.cell($1, bold: true, alignment: table.alignments[$0]) }
        let rows = table.rows.map { row in row.enumerated().map { Self.cell($1, bold: false, alignment: table.alignments[$0]) } }
        let pad = Self.horizontalPadding * 2
        var natural = (0..<columns).map { column in
            ([header[column]] + rows.map { $0[column] }).map { ceil($0.size().width) + pad }.max() ?? Self.minimumColumn
        }
        natural = natural.map { max(Self.minimumColumn, $0) }
        var widths = natural
        let total = natural.reduce(0, +)
        if total > maxWidth {
            // Narrow columns keep their width; the wide ones share what is left.
            let fair = maxWidth / CGFloat(columns)
            let narrow = natural.filter { $0 <= fair }.reduce(0, +)
            let wide = natural.filter { $0 > fair }.reduce(0, +)
            let room = max(0, maxWidth - narrow)
            widths = natural.map { $0 <= fair ? $0 : max(Self.minimumColumn, floor($0 / max(1, wide) * room)) }
        }
        func height(_ cells: [NSAttributedString]) -> CGFloat {
            cells.enumerated().map { column, cell in
                let bounds = cell.boundingRect(with: CGSize(width: max(1, widths[column] - pad), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                return ceil(bounds.height) + Self.verticalPadding * 2
            }.max() ?? 24
        }
        self.header = header
        self.rows = rows
        self.columnWidths = widths
        self.rowHeights = [height(header)] + rows.map(height)
    }

    private static func cell(_ text: String, bold: Bool, alignment: MarkdownTable.Alignment) -> NSAttributedString {
        let base = PlatformFont.preferredFont(forTextStyle: .callout)
        let result = NSMutableAttributedString(attributedString: NoteMarkdown.inline(EntryLinks.shownText(MarkdownTable.displayText(text)), kind: .paragraph))
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.font, in: whole, options: []) { value, range, _ in
            let font = value as? PlatformFont
            let isBold = bold || (font.map(NoteMarkdown.isBold) ?? false)
            let isItalic = font.map(NoteMarkdown.isItalic) ?? false
            result.addAttribute(.font, value: NoteMarkdown.withTraits(base, bold: isBold, italic: isItalic), range: range)
        }
        let style = NSMutableParagraphStyle()
        switch alignment {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        default: style.alignment = .natural
        }
        style.lineBreakMode = .byWordWrapping
        result.addAttributes([.paragraphStyle: style, .foregroundColor: NoteMarkdown.primaryColor], range: whole)
        return result
    }

    func draw(in rect: CGRect) {
        let size = self.size
        let frame = CGRect(x: rect.minX, y: rect.minY, width: size.width, height: size.height)
        let radius: CGFloat = 8
        // Header tint, clipped to the rounded corners.
        NoteBlockRenderer.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: rowHeights[0]).insetBy(dx: 0.5, dy: 0.5), color: NoteBlockRenderer.headerFill, radius: radius)
        if rowHeights.count > 1 {
            // Square off the header's lower corners.
            NoteBlockRenderer.fill(CGRect(x: frame.minX + 0.5, y: frame.minY + rowHeights[0] - radius, width: frame.width - 1, height: radius), color: NoteBlockRenderer.headerFill)
        }
        let line = NoteBlockRenderer.separator
        var y = frame.minY
        for (index, height) in rowHeights.enumerated() {
            if index > 0 { NoteBlockRenderer.fill(CGRect(x: frame.minX, y: y, width: frame.width, height: 1), color: line) }
            let cells = index == 0 ? header : rows[index - 1]
            var x = frame.minX
            for (column, width) in columnWidths.enumerated() {
                if column > 0, index == 0 { NoteBlockRenderer.fill(CGRect(x: x, y: frame.minY, width: 1, height: frame.height), color: line) }
                let box = CGRect(x: x + Self.horizontalPadding, y: y + Self.verticalPadding, width: max(1, width - Self.horizontalPadding * 2), height: height - Self.verticalPadding * 2)
                if column < cells.count { cells[column].draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil) }
                x += width
            }
            y += height
        }
        NoteBlockRenderer.stroke(frame, color: line, radius: radius)
    }
}

// MARK: - Inline images

/// The pictures of inline images, read from the note's attachments (`AudioStore`, kind attachment) at screen
/// size. A file only in iCloud is downloaded; once it is here `noteInlineImageReady` lets the editors draw it.
enum InlineImages {
    private final class Box: NSObject {
        let image: PlatformImage
        init(_ image: PlatformImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 40
        return cache
    }()

    nonisolated(unsafe) private static var downloading = Set<String>()
    private static let lock = NSLock()

    /// Longest side in pixels.
    static let maxPixels = 1600

    /// The picture if it can be had now; otherwise nil, and a download from iCloud is started.
    static func image(for fileName: String) -> PlatformImage? {
        if let cached = cache.object(forKey: fileName as NSString) { return cached.image }
        if AudioStore.exists(fileName, kind: .attachment), let image = load(AudioStore.url(for: fileName, kind: .attachment)) {
            cache.setObject(Box(image), forKey: fileName as NSString)
            return image
        }
        fetch(fileName)
        return nil
    }

    private static func load(_ url: URL) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        #if os(macOS)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
        #else
        return UIImage(cgImage: cgImage, scale: 3, orientation: .up)
        #endif
    }

    private static func fetch(_ fileName: String) {
        lock.lock()
        let isNew = downloading.insert(fileName).inserted
        lock.unlock()
        guard isNew else { return }
        Task.detached(priority: .utility) {
            defer {
                lock.lock()
                downloading.remove(fileName)
                lock.unlock()
            }
            _ = await AudioStore.cloudContainer()
            if !AudioStore.exists(fileName, kind: .attachment) {
                guard AudioStore.isInCloud(fileName, kind: .attachment) else { return }
                _ = try? await AudioStore.download(fileName, kind: .attachment, timeout: 120)
            }
            guard AudioStore.exists(fileName, kind: .attachment) else { return }
            await MainActor.run { NotificationCenter.default.post(name: .noteInlineImageReady, object: fileName) }
        }
    }

    /// Writes image data as a file to put on a note (`AttachmentStore.add` copies it into the store), in a folder
    /// of its own that the caller removes.
    /// "jpg", "heic", "png"…: what the bytes are, read from them.
    static func fileExtension(of data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension else { return "jpg" }
        return ext
    }

    static func temporaryFile(_ data: Data, name: String, extension ext: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InlineImages/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let clean = name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(clean.isEmpty ? "Image" : clean).appendingPathExtension(ext.isEmpty ? "png" : ext)
        try data.write(to: url)
        return url
    }
}
