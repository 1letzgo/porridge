import AppKit
import PDFKit

/// The pages of a document's PDF, as a sheet: turn, move (drag or buttons), delete, add pages (a PDF or picture from a
/// file, or scanned with the iPhone through Continuity Camera), and split pages off into documents of their own.
/// Works on a copy; "Save" writes it back (`DocumentFiles.save`), and its text is read again.
@MainActor
final class PDFPageEditorController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSServicesMenuRequestor {
    private let note: Note
    private var pages: [PDFPage] = []
    private var changed = false { didSet { updateButtons() } }
    private let table = NSTableView()
    private let status = NSTextField.label(color: .secondaryLabelColor)
    private let rotateLeft = NSButton()
    private let rotateRight = NSButton()
    private let moveUp = NSButton()
    private let moveDown = NSButton()
    private let delete = NSButton()
    private let add = NSPopUpButton(frame: .zero, pullsDown: true)
    private let split = NSPopUpButton(frame: .zero, pullsDown: true)
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private static let pageType = NSPasteboard.PasteboardType("de.letzgo.porridge.page-row")

    private var library: Library { .shared }

    /// Opens the editor as a sheet on the window.
    static func open(_ note: Note, in window: NSWindow?) {
        guard DocumentFiles.pdf(of: note) != nil, let window else { return }
        let controller = PDFPageEditorController(note: note)
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = "Pages"
        window.beginSheet(sheet)
    }

    init(note: Note) {
        self.note = note
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 112
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.pageType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.style = .inset
        table.setAccessibilityLabel("Pages")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        func symbolButton(_ button: NSButton, _ symbol: String, _ label: String, _ action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .push
            button.target = self
            button.action = action
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        symbolButton(rotateLeft, "rotate.left", "Rotate Left", #selector(turnLeft))
        symbolButton(rotateRight, "rotate.right", "Rotate Right", #selector(turnRight))
        symbolButton(moveUp, "arrow.up", "Move Up", #selector(up))
        symbolButton(moveDown, "arrow.down", "Move Down", #selector(down))
        symbolButton(delete, "trash", "Delete Pages", #selector(deletePages))

        add.addItem(withTitle: "Add Pages")
        add.menu?.addItem(withTitle: "From a File…", action: #selector(addFromFile), keyEquivalent: "").target = self
        // Continuity Camera: the system puts "Scan Documents" of the iPhone or iPad nearby here.
        let device = NSMenuItem(title: "From iPhone or iPad", action: nil, keyEquivalent: "")
        device.identifier = NSMenuItem.importFromDeviceIdentifier
        add.menu?.addItem(device)
        add.bezelStyle = .push

        split.addItem(withTitle: "Split")
        split.menu?.addItem(withTitle: "Split Off Selected Pages", action: #selector(splitSelected), keyEquivalent: "").target = self
        split.menu?.addItem(withTitle: "Split Every Page…", action: #selector(splitEvery), keyEquivalent: "").target = self
        split.bezelStyle = .push

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        save.target = self
        save.action = #selector(saveAndClose)
        save.keyEquivalent = "\r"

        let tools = NSStackView.horizontal([rotateLeft, rotateRight, moveUp, moveDown, delete, add, split], spacing: 6)
        let bottom = NSStackView.horizontal([status, NSView(), cancel, save], spacing: 8)
        let stack = NSStackView.vertical([tools, scroll, bottom], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let root = NSView()
        root.addSubview(stack)
        stack.pinEdges(to: root)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 520),
            root.heightAnchor.constraint(equalToConstant: 620),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            bottom.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        view = root
        updateButtons()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let file = DocumentFiles.pdf(of: note) else { return }
        status.stringValue = "Loading…"
        Task {
            do {
                let document = try await DocumentFiles.load(file)
                pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
                table.reloadData()
                updateButtons()
            } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { pages.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let image = NSImageView(image: pages[row].thumbnail(of: NSSize(width: 150, height: 200), for: .mediaBox))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        // A white page needs an edge to be seen as one.
        image.wantsLayer = true
        image.layer?.borderWidth = 1
        image.layer?.borderColor = NSColor.separatorColor.cgColor
        image.layer?.backgroundColor = NSColor.white.cgColor
        let label = NSTextField.label("Page \(row + 1)")
        let stack = NSStackView.horizontal([image, label], spacing: 14)
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 76),
            image.heightAnchor.constraint(equalToConstant: 100),
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel("Page \(row + 1)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.pageType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        dropOperation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let rows = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.pageType).flatMap(Int.init) }
        guard !rows.isEmpty else { return false }
        move(IndexSet(rows), to: row)
        return true
    }

    // MARK: Actions

    private var selected: IndexSet { table.selectedRowIndexes.filteredIndexSet { $0 < pages.count } }

    private func updateButtons() {
        let some = !selected.isEmpty
        rotateLeft.isEnabled = some
        rotateRight.isEnabled = some
        moveUp.isEnabled = some && (selected.first ?? 0) > 0
        moveDown.isEnabled = some && (selected.last ?? pages.count) < pages.count - 1
        delete.isEnabled = some && selected.count < pages.count
        split.isEnabled = pages.count > 1
        save.isEnabled = changed
        if !pages.isEmpty { status.stringValue = pages.count == 1 ? "1 page" : "\(pages.count) pages" }
    }

    @objc private func turnLeft() { turn(-90) }
    @objc private func turnRight() { turn(90) }

    private func turn(_ degrees: Int) {
        for index in selected { pages[index].rotation = ((pages[index].rotation + degrees) % 360 + 360) % 360 }
        reload(keeping: selected)
        changed = true
    }

    @objc private func up() {
        guard let first = selected.first, first > 0 else { return }
        move(selected, to: first - 1)
    }

    @objc private func down() {
        guard let last = selected.last, last < pages.count - 1 else { return }
        move(selected, to: last + 2)
    }

    /// Moves the rows before `destination`, as a list moves its rows; they stay selected.
    private func move(_ rows: IndexSet, to destination: Int) {
        let moving = rows.map { pages[$0] }
        let before = rows.filter { $0 < destination }.count
        for index in rows.sorted(by: >) { pages.remove(at: index) }
        let at = min(max(0, destination - before), pages.count)
        pages.insert(contentsOf: moving, at: at)
        reload(keeping: IndexSet(at..<at + moving.count))
        changed = true
    }

    @objc private func deletePages() {
        guard selected.count < pages.count else { return }
        for index in selected.sorted(by: >) { pages.remove(at: index) }
        reload(keeping: [])
        changed = true
    }

    private func reload(keeping rows: IndexSet) {
        table.reloadData()
        table.selectRowIndexes(rows, byExtendingSelection: false)
        updateButtons()
    }

    @objc private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            panel.urls.forEach { self.addPages(from: $0) }
        }
    }

    /// The pages of a PDF, or a picture as a page, at the end.
    private func addPages(from url: URL) {
        if let document = PDFDocument(url: url) {
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { pages.append(page) }
            }
        } else if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
            pages.append(page)
        } else {
            return
        }
        reload(keeping: [])
        changed = true
    }

    // Continuity Camera: scanned pages or a photo from the iPhone come in as pages.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, DeviceImport.types.contains(returnType) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    nonisolated func readSelection(from pasteboard: NSPasteboard) -> Bool {
        MainActor.assumeIsolated {
            guard let url = DeviceImport.file(from: pasteboard) else { return false }
            addPages(from: url)
            return true
        }
    }

    private var edited: PDFDocument {
        let document = PDFDocument()
        for page in pages {
            if let copy = page.copy() as? PDFPage { document.insert(copy, at: document.pageCount) }
        }
        return document
    }

    @discardableResult
    private func write() -> Bool {
        guard changed, let file = DocumentFiles.pdf(of: note) else { return true }
        do {
            try DocumentFiles.save(edited, as: file, of: note, context: library.context, processing: library.processing)
            changed = false
            return true
        } catch {
            Alerts.inform("Could Not Save the Pages", message: error.localizedDescription, in: view.window)
            return false
        }
    }

    @objc private func saveAndClose() {
        if write() { close() }
    }

    @objc private func splitSelected() {
        guard !selected.isEmpty, selected.count < pages.count else {
            Alerts.inform("Choose Pages to Split Off", message: "Select the pages that become a document of their own. At least one page stays.", in: view.window)
            return
        }
        runSplit(.pages(Array(selected)))
    }

    @objc private func splitEvery() {
        Alerts.confirm(
            "Split Every Page?",
            message: "This document keeps its first page; every other page becomes a document of its own in the same bowl.",
            action: "Split into \(pages.count) Documents", isDestructive: false, in: view.window
        ) { [weak self] in self?.runSplit(.everyPage) }
    }

    /// Saves what was changed, splits, and closes.
    private func runSplit(_ split: PDFPages.Split) {
        guard write() else { return }
        let note = note
        Task {
            do {
                try await DocumentFiles.split(note, split, context: library.context, processing: library.processing)
                close()
            } catch {
                Alerts.inform("Could Not Split the PDF", message: error.localizedDescription, in: view.window)
            }
        }
    }

    @objc private func close() {
        guard let sheet = view.window else { return }
        sheet.sheetParent?.endSheet(sheet)
    }
}
