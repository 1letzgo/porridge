import Foundation
import Observation

/// Lets the note screen reach into the editor: cursor position, keyboard, formatting.
@MainActor
@Observable
final class NoteEditorController {
    @ObservationIgnored private weak var coordinator: NoteTextCoordinator?
    /// The body is being edited (the format bar is showing above the keyboard).
    var isEditing = false
    /// Nothing typed: follows every key press, while the note hears of the text only shortly after.
    var isEmpty = true

    /// A table to edit (one just inserted, or one tapped): the screen shows `TableEditorView` for it.
    var tableRequest: TableEditRequest?
    /// iOS: where to pick an image from; the screen shows the photo picker or the file importer.
    var imagePicker: ImagePickerSource?
    /// A selection to rewrite with AI: the screen shows `AIRewriteView` for it.
    var rewriteRequest: RewriteRequest?

    /// Set by the note's screen: puts an image file on the note as an attachment and returns it. Without it (a
    /// summary, a note that cannot take files) images cannot be inserted.
    @ObservationIgnored var attachImage: ((URL) -> Attachment?)? {
        didSet { canInsertImages = attachImage != nil }
    }
    private(set) var canInsertImages = false
    /// Set with `attachImage`: whether a file (by its stored name) is one of this note's attachments already.
    @ObservationIgnored var hasAttachment: ((String) -> Bool)?

    /// Markdown pasted from another note shows that note's files: each image not on this note yet is copied onto it
    /// (a file of its own), and the text points to the copy. Images whose file is not here stay as they are.
    func adoptingImages(in markdown: String) -> String {
        guard let attachImage, let hasAttachment else { return markdown }
        var text = markdown
        for name in Set(NoteImageRef.fileNames(in: markdown)) where !hasAttachment(name) {
            let source = AudioStore.url(for: name, kind: .attachment)
            guard FileManager.default.fileExists(atPath: source.path),
                  let data = try? Data(contentsOf: source),
                  let copy = try? InlineImages.temporaryFile(data, name: "Image", extension: source.pathExtension) else { continue }
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            guard let attachment = attachImage(copy) else { continue }
            text = text.replacingOccurrences(of: "(attachment:\(name))", with: "(attachment:\(attachment.fileName))")
        }
        return text
    }

    /// The note's title, for `{{title}}` in a template inserted into it.
    @ObservationIgnored var noteTitle: (() -> String)?

    /// A note template's text put in at the cursor, its placeholders filled; the cursor goes where `{{cursor}}` was.
    func insertTemplate(_ template: NoteTemplate, now: Date = Date()) {
        let values = NoteTemplates.Values(now: now, title: noteTitle?() ?? "")
        let (text, cursor) = NoteTemplates.insertion(of: template, values: values)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        coordinator?.insertMarkdown(text, cursor: cursor)
    }

    /// Cursor as a character offset in the note's Markdown; the end of the text when nothing is being edited.
    var cursorOffset: Int { coordinator?.cursorOffset() ?? 0 }

    func blur() { coordinator?.blur() }

    func perform(_ command: NoteEditorCommand) { coordinator?.perform(command) }

    func bind(_ coordinator: NoteTextCoordinator) { self.coordinator = coordinator }

    // MARK: Rewrite with AI

    /// Whether there is a selection that can be rewritten (something selected, the note can be written to).
    var canRewrite: Bool { coordinator?.rewriteTarget() != nil }

    /// Opens the rewrite sheet for the selection; nothing happens without one.
    func beginRewrite() {
        guard let target = coordinator?.rewriteTarget() else { return }
        rewriteRequest = RewriteRequest(target: target)
    }

    /// The rewrite goes into the note (one step of Undo). False when the selection is not there anymore.
    @discardableResult
    func finishRewrite(_ request: RewriteRequest, text: String, insertBelow: Bool) -> Bool {
        coordinator?.applyRewrite(request.target, text: text, insertBelow: insertBelow) ?? false
    }

    // MARK: Insert menu

    /// One of the choices of the insert menu (the "+" in the format bar).
    func insert(_ item: NoteInsertItem) {
        switch item {
        case .heading: perform(.setKind(.heading(2)))
        case .checklist: perform(.setKind(.checklist(checked: false)))
        case .quote: perform(.setKind(.quote))
        case .divider: perform(.insertBlock(.divider))
        case .code: perform(.insertCodeBlock)
        case .table: insertTable()
        case .photo: imagePicker = .photos
        case .imageFile: imagePicker = .files
        }
    }

    /// A new table after the cursor's paragraph, opened in the table editor right away.
    func insertTable() {
        let table = MarkdownTable.empty()
        guard let location = coordinator?.insertBlock(.table(table)) else { return }
        tableRequest = TableEditRequest(table: table, location: location, source: table.markdown, isNew: true)
    }

    /// The table editor closed: `table` is the new table; nil with `delete` takes it away; nil otherwise changes
    /// nothing (a new table that was cancelled goes away again).
    func finishTable(_ request: TableEditRequest, table: MarkdownTable?, delete: Bool = false) {
        tableRequest = nil
        if let table {
            guard table != request.table || request.isNew else { return }
            coordinator?.replaceBlock(at: request.location, source: request.source, with: .table(table))
        } else if delete || request.isNew {
            coordinator?.replaceBlock(at: request.location, source: request.source, with: nil)
        }
    }

    /// An image file put on the note and shown at the cursor. Returns false when it could not be added.
    @discardableResult
    func insertImage(fileAt url: URL) -> Bool {
        guard let attachImage, let attachment = attachImage(url) else { return false }
        let alt = (attachment.name as NSString).deletingPathExtension
        coordinator?.insertBlock(.image(NoteImageRef(fileName: attachment.fileName, alt: alt.isEmpty ? "Image" : alt)))
        return true
    }

    /// Image data (pasted, from the photo library) put on the note and shown at the cursor.
    @discardableResult
    func insertImage(data: Data, fileExtension ext: String, name: String = "Image") -> Bool {
        guard canInsertImages, let file = try? InlineImages.temporaryFile(data, name: name, extension: ext) else { return false }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        return insertImage(fileAt: file)
    }
}

/// The choices of the insert menu.
enum NoteInsertItem: CaseIterable, Identifiable {
    case heading, checklist, table, photo, imageFile, divider, quote, code

    var id: Self { self }

    var title: String {
        switch self {
        case .heading: String(localized: "Heading")
        case .checklist: String(localized: "Checklist")
        case .table: String(localized: "Table")
        case .photo: String(localized: "Photo")
        case .imageFile: String(localized: "Image from Files")
        case .divider: String(localized: "Divider")
        case .quote: String(localized: "Quote")
        case .code: String(localized: "Code Block")
        }
    }

    var systemImage: String {
        switch self {
        case .heading: "textformat.size"
        case .checklist: "checklist"
        case .table: "tablecells"
        case .photo: "photo"
        case .imageFile: "folder"
        case .divider: "minus"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }

    var isImage: Bool { self == .photo || self == .imageFile }
}

enum ImagePickerSource: Identifiable {
    case photos, files
    var id: Self { self }
}

/// A table being edited: where its character is and the Markdown it had, to find it again.
struct TableEditRequest: Identifiable, Equatable {
    let id = UUID()
    var table: MarkdownTable
    var location: Int
    var source: String
    var isNew: Bool
}
