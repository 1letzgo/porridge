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
/// text. Each becomes a note in the inbox or the open bucket, and the first one opens.
@MainActor
enum Intake {
    /// Files, links or text from a drop or the clipboard. False when there was nothing to take.
    @discardableResult
    static func accept(_ pasteboard: NSPasteboard, project: String?, state: WindowState?) -> Bool {
        let library = Library.shared
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !files.isEmpty {
            return addFiles(files, project: project, state: state)
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let web = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            addLink(web.absoluteString, project: project, state: state)
            return true
        }
        // A picture without a file (a screenshot copied to the clipboard): stored as a file first.
        if let image = NSImage(pasteboard: pasteboard), let data = image.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted Image \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).png".replacingOccurrences(of: ":", with: "."))
            guard (try? data.write(to: url)) != nil else { return false }
            return addFiles([url], project: project, state: state)
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let address = LinkImport.webAddress(from: text), !text.contains(" "), !text.contains("\n") {
                addLink(address, project: project, state: state)
            } else {
                let note = Note()
                note.source = .share
                note.text = text
                if let project { note.projectIDs = [project] }
                library.context.insert(note)
                library.save()
                state?.open(note.id)
            }
            return true
        }
        return false
    }

    @discardableResult
    static func addFiles(_ urls: [URL], project: String?, state: WindowState?) -> Bool {
        let library = Library.shared
        guard let note = ShareImport.add(files: urls, project: project, context: library.context, processing: library.processing) else { return false }
        library.setNeedsReload()
        state?.open(note.id)
        return true
    }

    /// Saves a web page as a note; it is fetched and summarized in the queue.
    static func addLink(_ address: String, project: String?, state: WindowState?) {
        let library = Library.shared
        let note = LinkImport.add(address, context: library.context, processing: library.processing)
        if let project, !note.projectIDs.contains(project) {
            note.projectIDs = [project]
            library.save()
        }
        library.setNeedsReload()
        state?.open(note.id)
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
        state?.open(note.id)
    }

    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
