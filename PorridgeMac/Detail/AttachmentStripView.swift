import AppKit
import QuickLookUI

/// Views side by side, wrapping into lines.
final class FlowView: NSView {
    private var items: [NSView] = []
    var spacing: CGFloat = 6
    private var height: CGFloat = 0

    override var isFlipped: Bool { true }

    func setViews(_ views: [NSView]) {
        items.forEach { $0.removeFromSuperview() }
        items = views
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        needsLayout = true
        layoutItems()
    }

    override func layout() {
        super.layout()
        layoutItems()
    }

    private func layoutItems() {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let width = max(bounds.width, 100)
        for view in items {
            let size = view.fittingSize
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let total = items.isEmpty ? 0 : y + rowHeight
        if total != height {
            height = total
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
}

/// The files of a note as small pictures: a click shows one in Quick Look, the context menu opens, shows in
/// the Finder or removes it. A file that is in iCloud is downloaded first (its tile dims meanwhile).
final class AttachmentStripView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let stack = NSStackView()
    private var attachments: [Attachment] = []
    private var previewIndex = 0
    var onRemove: ((Attachment) -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 8
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.pinEdges(to: self)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 84),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.heightAnchor.constraint(equalToConstant: 76),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ attachments: [Attachment], canRemove: Bool) {
        guard attachments != self.attachments else { return }
        self.attachments = attachments
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, attachment) in attachments.enumerated() {
            let tile = AttachmentTile(attachment: attachment)
            tile.tag = index
            tile.target = self
            tile.action = #selector(preview(_:))
            let menu = NSMenu()
            menu.add("Quick Look", symbol: "eye") { [weak self] in self?.showPreview(at: index) }
            menu.add("Open", symbol: "arrow.up.forward.app") { [weak self] in
                self?.withFile(at: index) { NSWorkspace.shared.open($0) }
            }
            menu.add("Show in Finder", symbol: "folder") { [weak self] in
                self?.withFile(at: index) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
            }
            if canRemove {
                menu.addItem(.separator())
                menu.add("Remove", symbol: "trash", isDestructive: true) { [weak self] in self?.onRemove?(attachment) }
            }
            tile.menu = menu
            stack.addArrangedSubview(tile)
        }
    }

    @objc private func preview(_ sender: NSButton) {
        showPreview(at: sender.tag)
    }

    /// Runs `action` with the file, once it is downloaded when it is only in iCloud.
    private func withFile(at index: Int, then action: @escaping (URL) -> Void) {
        guard attachments.indices.contains(index) else { return }
        let attachment = attachments[index]
        if AttachmentStore.exists(attachment) {
            action(AttachmentStore.url(for: attachment))
            return
        }
        let tile = stack.arrangedSubviews.first { ($0 as? NSButton)?.tag == index }
        tile?.alphaValue = 0.4
        Task { @MainActor [weak self] in
            do {
                let url = try await AttachmentStore.download(attachment)
                tile?.alphaValue = 1
                action(url)
            } catch {
                tile?.alphaValue = 1
                Alerts.inform("Could Not Open", message: error.localizedDescription, in: self?.window)
            }
        }
    }

    private func showPreview(at index: Int) {
        withFile(at: index) { [weak self] _ in self?.openPreview(at: index) }
    }

    private func openPreview(at index: Int) {
        previewIndex = index
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { attachments.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        AttachmentStore.url(for: attachments[index]) as NSURL
    }
}

/// One file: its picture (or the symbol of its kind) and its name.
private final class AttachmentTile: NSButton {
    init(attachment: Attachment) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 76).isActive = true
        heightAnchor.constraint(equalToConstant: 76).isActive = true
        image = .symbol(attachment.kind == .pdf ? "doc.richtext" : attachment.kind == .image ? "photo" : "doc", size: 26, weight: .light)
        contentTintColor = .secondaryLabelColor
        toolTip = attachment.name
        setAccessibilityLabel(attachment.name)
        Task { @MainActor [weak self] in
            if let picture = await Thumbnails.load(attachment, maxPixels: 220) {
                self?.image = NSImage(cgImage: picture, size: .zero)
                self?.imageScaling = .scaleProportionallyUpOrDown
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
