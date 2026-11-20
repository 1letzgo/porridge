import AppKit
import SwiftData
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Notes dragged inside the app: their ids, one per line.
    static let porridgeNote = NSPasteboard.PasteboardType("de.letzgo.porridge.note-ids")
}

/// Notes on the pasteboard, for dragging them onto buckets and between windows.
enum NotePasteboard {
    static func write(_ notes: [Note], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.porridgeNote, .string], owner: nil)
        pasteboard.setString(notes.map(\.id.uuidString).joined(separator: "\n"), forType: .porridgeNote)
        pasteboard.setString(notes.map(\.exportText).joined(separator: "\n\n---\n\n"), forType: .string)
    }

    static func item(for note: Note) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(note.id.uuidString, forType: .porridgeNote)
        item.setString(note.exportText, forType: .string)
        return item
    }

    static func noteIDs(from pasteboard: NSPasteboard) -> [UUID]? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        let ids = items.compactMap { $0.string(forType: .porridgeNote) }
            .flatMap { $0.split(separator: "\n") }
            .compactMap { UUID(uuidString: String($0)) }
        return ids.isEmpty ? nil : ids
    }
}

/// Everything that comes into the app from outside: files and pictures (dropped, pasted or picked), web links and
/// text. Each becomes a note in the inbox or the open bucket, and the first one opens. Nothing that comes in this
/// way becomes a to-do.
@MainActor
enum Intake {
    /// What a drop or the clipboard would bring in, read before anything is stored (for the drop's highlight).
    struct Plan {
        /// Files the import takes: pictures, PDFs, recordings and any other document.
        var files: [URL] = []
        /// Folders and packages (apps, bundles): they are not taken, and the user is told so.
        var skipped: [URL] = []
        var link: String?
        var hasImage = false
        var text: String?

        var canImport: Bool { !files.isEmpty || link != nil || hasImage || text != nil }

        /// "3 files", "a picture", "a link", "the text".
        var summary: String {
            if !files.isEmpty {
                let audio = files.allSatisfy(Intake.isRecording)
                if files.count == 1 { return audio ? "a recording" : "a file" }
                return audio ? "\(files.count) recordings" : "\(files.count) files"
            }
            if link != nil { return "a link" }
            if hasImage { return "a picture" }
            return "the text"
        }

        /// Why the skipped ones stay out, for the drop's highlight and the notice after it.
        var skippedNote: String? {
            guard !skipped.isEmpty else { return nil }
            let names = skipped.prefix(3).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ") + (skipped.count > 3 ? " …" : "")
            return "Folders and packages can't be imported: \(names)"
        }
    }

    /// Reads the pasteboard without storing anything; nil when it holds nothing from outside (notes dragged within
    /// the app, or nothing the import knows).
    static func plan(_ pasteboard: NSPasteboard) -> Plan? {
        guard pasteboard.availableType(from: [.porridgeNote]) == nil else { return nil }
        var plan = Plan()
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !files.isEmpty {
            for file in files {
                if isImportable(file) { plan.files.append(file) } else { plan.skipped.append(file) }
            }
            return plan
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let web = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            plan.link = web.absoluteString
            return plan
        }
        if pasteboard.availableType(from: [.png, .tiff]) != nil {
            plan.hasImage = true
            return plan
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let address = LinkImport.webAddress(from: text), !text.contains(" "), !text.contains("\n") {
                plan.link = address
            } else {
                plan.text = text
            }
            return plan
        }
        return nil
    }

    /// What the file import takes (Import File and Import Audio): any document, picture, PDF, recording or video,
    /// but not a folder or a package.
    static func isImportable(_ url: URL) -> Bool {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            return type.conforms(to: .data) || type.conforms(to: .audio) || type.conforms(to: .movie)
        }
        // Not readable before the drop (sandbox): folders and packages still come with a trailing slash.
        return !url.hasDirectoryPath
    }

    static func isRecording(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    /// Where something dropped now would land: the bucket's name, or "Inbox".
    static func destinationName(project: String?) -> String {
        guard let project else { return "Inbox" }
        return Library.shared.project(key: project)?.name ?? "Inbox"
    }

    /// Files, links or text from a drop or the clipboard. False when nothing was taken; folders and files that
    /// can't be read are named in a notice, never dropped silently.
    @discardableResult
    static func accept(_ pasteboard: NSPasteboard, project: String?, state: WindowState?) -> Bool {
        guard let plan = plan(pasteboard) else { return false }
        if !plan.files.isEmpty || !plan.skipped.isEmpty {
            var imported = false
            if !plan.files.isEmpty {
                // Copied right away: in the sandbox a dropped file can only be read during the drop.
                imported = addFiles(plan.files, project: project, state: state)
            }
            if let note = plan.skippedNote {
                inform("Not Imported", message: note + ".", state: state)
            }
            return imported
        }
        if let link = plan.link {
            addLink(link, project: project, state: state)
            return true
        }
        // A picture without a file (a screenshot copied to the clipboard): stored as a file first.
        if plan.hasImage {
            guard let image = NSImage(pasteboard: pasteboard), let data = image.pngData() else { return false }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted Image \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).png".replacingOccurrences(of: ":", with: "."))
            guard (try? data.write(to: url)) != nil else { return false }
            return addFiles([url], project: project, state: state)
        }
        if let text = plan.text {
            let library = Library.shared
            let note = Note()
            note.source = .share
            note.text = text
            if let project { note.projectIDs = [project] }
            library.context.insert(note)
            library.save()
            show(note, in: state)
            return true
        }
        return false
    }

    /// Each file becomes a note (a recording is transcribed); files that can't be copied are named in a notice.
    @discardableResult
    static func addFiles(_ urls: [URL], project: String?, state: WindowState?) -> Bool {
        let library = Library.shared
        var first: Note?
        var failed: [URL] = []
        for url in urls {
            if let note = ShareImport.add(files: [url], project: project, context: library.context, processing: library.processing) {
                first = first ?? note
            } else {
                failed.append(url)
            }
        }
        if !failed.isEmpty {
            let names = failed.prefix(3).map { "“\($0.lastPathComponent)”" }.joined(separator: ", ") + (failed.count > 3 ? " …" : "")
            inform("Not Imported", message: "These files couldn't be read: \(names).", state: state)
        }
        guard let first else { return false }
        library.setNeedsReload()
        show(first, in: state)
        return true
    }

    /// Saves a web page as a note; it is fetched and summarized in the queue. It never becomes a to-do.
    static func addLink(_ address: String, project: String?, state: WindowState?) {
        let library = Library.shared
        let note = LinkImport.add(address, context: library.context, processing: library.processing)
        if let project, !note.projectIDs.contains(project) {
            note.projectIDs = [project]
            library.save()
        }
        library.setNeedsReload()
        show(note, in: state)
    }

    /// An audio file brought in from outside becomes a meeting that is transcribed.
    static func importAudio(_ url: URL, project: String?, state: WindowState?) throws {
        let library = Library.shared
        let note = try NoteStore.importAudio(from: url, context: library.context, processing: library.processing)
        if let project {
            note.projectIDs = [project]
            library.save()
        }
        library.setNeedsReload()
        show(note, in: state)
    }

    /// Opens what came in: on the page it belongs to when that one is open, otherwise where it lives (from the
    /// to-dos, the chat, the archive or the search the window goes to its bucket or the inbox).
    private static func show(_ note: Note, in state: WindowState?) {
        guard let state else { return }
        switch state.page {
        case .inbox where note.projectIDs.isEmpty:
            state.open(note.id)
        case .project(let id) where note.projectIDs.contains(id.uuidString):
            state.open(note.id)
        default:
            state.reveal(note)
        }
    }

    /// A notice on the window, after the drop has finished.
    private static func inform(_ title: String, message: String, state: WindowState?) {
        let window = MainWindowController.all.first { $0.state === state }?.window ?? NSApp.keyWindow
        DispatchQueue.main.async {
            Alerts.inform(title, message: message, in: window)
        }
    }

    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
