import AppKit
import QuickLookUI

/// The row under a note's head: suggested bowls (a click files the note), its bowls, what a document is, its tags,
/// and the buttons to add a bowl or a tag. It wraps into lines when the column is narrow.
final class NoteChipsView: NSView {
    private let flow = FlowView()
    private let dueChip = DueDateChip()
    private var note: Note?
    weak var hostWindow: NSWindow? { didSet { dueChip.hostWindow = hostWindow } }
    var onAddTag: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(flow)
        flow.pinEdges(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func show(_ note: Note, library: Library) {
        self.note = note
        var views: [NSView] = []
        // A to-do's due day comes first.
        if note.isTodo {
            dueChip.show(note)
            views.append(dueChip)
        }
        // The bowl suggested for a note in the inbox: a click files it there, the cross drops the suggestion.
        if note.isInInbox {
            for id in note.suggestedProjectIDs {
                guard let project = library.project(key: id), !project.isArchived else { continue }
                let pill = PillButton(title: project.name, symbol: "sparkles", tint: .brandProject, target: self, action: #selector(fileSuggested(_:)))
                pill.isFilled = true
                pill.identifier = .init(id)
                pill.setAccessibilityLabel("File into \(project.name)")
                pill.toolTip = "Suggested bowl"
                views.append(pill)
            }
            if !note.suggestedProjectIDs.isEmpty {
                let drop = NSButton(image: .symbol("xmark", size: 10, weight: .bold, label: "Drop Suggestion"), target: self, action: #selector(dropSuggestions))
                drop.isBordered = false
                drop.contentTintColor = .secondaryLabelColor
                drop.toolTip = "Drop Suggestion"
                views.append(drop)
            }
        }
        // The bowl (one at most; an entry from before may show several): a click changes it, the cross takes the
        // note out. "+ Bowl" only while it is in none.
        var shownBowls = 0
        for key in note.projectIDs {
            guard let project = library.project(key: key) else { continue }
            shownBowls += 1
            let pill = PillButton(title: project.name, symbol: "folder.fill", tint: .brandProject, target: self, action: #selector(showBuckets(_:)))
            pill.isEnabled = !note.isDeleted
            pill.setAccessibilityLabel("Bowl \(project.name)")
            pill.toolTip = "Change Bowl"
            views.append(pill)
            if !note.isDeleted {
                let remove = NSButton(image: .symbol("xmark", size: 10, weight: .bold, label: "Remove from \(project.name)"), target: self, action: #selector(removeBucket(_:)))
                remove.isBordered = false
                remove.contentTintColor = .brandProject
                remove.identifier = .init(key)
                remove.toolTip = "Remove from Bowl"
                views.append(remove)
            }
        }
        if !note.isDeleted, shownBowls == 0 {
            let add = PillButton(title: "Bowl", symbol: "plus", tint: .brandProject, target: self, action: #selector(showBuckets(_:)))
            add.setAccessibilityLabel("Add to Bowl")
            views.append(add)
        }
        // A stored file: what it is as a document, after its bowls ("Invoice · Telekom" in orange, or an
        // outlined "+ Document" to mark it as one); a click sets it.
        if note.isStored, !note.isDeleted {
            let info = note.documentInfo ?? DocumentInfo()
            let label = info.shortLabel
            let title = info.isEmpty ? String(localized: "Document") : (label.count > 40 ? String(label.prefix(39)) + "…" : label)
            let kind = info.kind ?? .other
            let pill = PillButton(
                title: title, symbol: info.isEmpty ? "plus" : kind.symbol,
                tint: info.isEmpty ? .systemGray : .brandLink, target: self, action: #selector(editDocument)
            )
            // Nothing known yet: neutral and outlined; known: the app's orange as a wash, the text plain.
            pill.isOutlined = info.isEmpty
            pill.labelColor = .labelColor
            pill.setAccessibilityLabel(info.isEmpty ? String(localized: "Add Document Details") : info.sentence)
            pill.toolTip = info.isEmpty ? String(localized: "Add the kind, date, sender and amount") : info.line
            views.append(pill)
            // Known: a cross beside it takes it away, as with the bowl.
            if !info.isEmpty {
                let remove = NSButton(image: .symbol("xmark", size: 10, weight: .bold, label: "Remove Document Details"), target: self, action: #selector(clearDocument))
                remove.isBordered = false
                remove.contentTintColor = .secondaryLabelColor
                remove.toolTip = "Remove Document Details"
                views.append(remove)
            }
        }
        for tag in note.tags {
            let removable = note.labels.contains { $0.lowercased() == tag.lowercased() } && !note.isDeleted
            let pill = PillButton(title: "#\(tag)", symbol: removable ? "xmark" : nil, tint: .brandSky, target: self, action: removable ? #selector(removeTag(_:)) : nil)
            pill.identifier = .init(tag)
            pill.setAccessibilityLabel(removable ? "Remove Tag \(tag)" : "Tag \(tag)")
            views.append(pill)
        }
        if !note.isDeleted {
            let add = PillButton(title: "Tag", symbol: "plus", tint: .systemGray, target: self, action: #selector(addTag))
            add.setAccessibilityLabel("Add Tag")
            views.append(add)
        }
        flow.setViews(views)
    }

    @objc private func fileSuggested(_ sender: NSButton) {
        guard let note, let key = sender.identifier?.rawValue else { return }
        Inbox.file(note, into: key, in: Library.shared.context)
    }

    @objc private func dropSuggestions() {
        guard let note else { return }
        Inbox.dismissSuggestions(note, in: Library.shared.context)
    }

    @objc private func removeBucket(_ sender: NSButton) {
        guard let note, let key = sender.identifier?.rawValue, let project = Library.shared.project(key: key) else { return }
        Projects.toggle(project, on: note, in: Library.shared.context)
    }

    @objc private func showBuckets(_ sender: NSButton) {
        guard let note else { return }
        let menu = NoteOperations.bucketMenu(for: [note], window: hostWindow)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func removeTag(_ sender: NSButton) {
        guard let note, let tag = sender.identifier?.rawValue else { return }
        note.labels.removeAll { $0.lowercased() == tag.lowercased() }
        Library.shared.save()
    }

    @objc private func addTag() { onAddTag?() }

    @objc private func clearDocument() {
        guard let note else { return }
        Documents.clear(note, in: Library.shared.context)
    }

    @objc private func editDocument() {
        guard let note else { return }
        DocumentInfoSheet.edit(note, in: hostWindow)
    }
}

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
