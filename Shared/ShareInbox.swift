import Foundation

/// What other apps share into Porridge waits here until the app picks it up: links, text, images, PDFs, files and
/// audio. The share sheet extension only copies into the app group; the app turns each entry into a note in its
/// inbox (see `ShareImport`).
enum ShareInbox {
    static let groupID = "group.de.letzgo.porridge"

    /// One thing shared: a link, a text, files, or a mix of them.
    struct Entry: Codable, Equatable {
        var id: String = UUID().uuidString
        var url: String?
        var text: String?
        var title: String?
        var files: [File] = []
        /// The bowl chosen in the share sheet (`NoteFolder.id` as uppercase string).
        var projectID: String?
        var date: Date = Date()
        /// Where it came from: `ownWords` for text dictated or typed into a shortcut ("Add to Porridge Inbox"),
        /// which becomes a note of the user's own; nil = shared from another app.
        var source: String?

        static let ownWords = "note"

        var isEmpty: Bool { url == nil && (text ?? "").isEmpty && files.isEmpty }
    }

    struct File: Codable, Equatable {
        enum Kind: String, Codable {
            case image
            case pdf
            case audio
            case file
        }

        /// Name of the copy next to the entry.
        var stored: String
        /// What the file was called where it came from.
        var name: String
        var kind: Kind
    }

    /// A bowl the share sheet can offer; the app writes the list (`writeProjects`).
    struct Project: Codable, Hashable, Identifiable {
        var id: String
        var name: String
    }

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// Overridden by tests.
    nonisolated(unsafe) static var rootOverride: URL?

    private static var root: URL? { rootOverride ?? container }

    private static var directory: URL? { root?.appendingPathComponent("ShareInbox", isDirectory: true) }

    /// Links from versions that only took links.
    private static var legacyDirectory: URL? { root?.appendingPathComponent("LinkInbox", isDirectory: true) }

    private static let entryName = "entry.json"

    /// The folder the files of an entry are copied into before `add`.
    static func folder(for id: String) throws -> URL {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(of file: File, in entry: Entry) -> URL? {
        directory?.appendingPathComponent(entry.id, isDirectory: true).appendingPathComponent(file.stored)
    }

    /// Writes the entry; its files are in `folder(for:)` already. The app only sees an entry once this is written,
    /// so a share that was interrupted never arrives half. Writing it again replaces it (a bowl chosen).
    static func add(_ entry: Entry) throws {
        let data = try JSONEncoder().encode(entry)
        try data.write(to: try folder(for: entry.id).appendingPathComponent(entryName), options: .atomic)
    }

    /// Writes the entry again (a bowl chosen after the share), only while it still waits: once the app has saved
    /// it and taken it out, nothing is written, so the folder never comes back as a second share. False then.
    @discardableResult
    static func update(_ entry: Entry) throws -> Bool {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let file = directory.appendingPathComponent(entry.id, isDirectory: true).appendingPathComponent(entryName)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let data = try JSONEncoder().encode(entry)
        // Atomic and without creating the folder: if the app takes the entry out meanwhile, this fails instead.
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            if !FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) { return false }
            throw error
        }
        return true
    }

    /// Whether the entry still waits for the app (it has not saved it yet).
    static func isPending(_ id: String) -> Bool {
        guard let directory else { return false }
        let file = directory.appendingPathComponent(id, isDirectory: true).appendingPathComponent(entryName)
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// "Undo" in the share sheet, and the app once the note is saved.
    static func remove(_ id: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
    }

    /// Everything in the inbox, oldest first. Entries stay until `remove`: one is only taken out once its note is saved.
    static func pending() -> [Entry] {
        var entries: [Entry] = []
        let files = FileManager.default
        if let directory, let folders = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for folder in folders {
                if let data = try? Data(contentsOf: folder.appendingPathComponent(entryName)),
                   let entry = try? JSONDecoder().decode(Entry.self, from: data), entry.id == folder.lastPathComponent {
                    entries.append(entry)
                } else if let changed = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                          Date().timeIntervalSince(changed) > 3600 {
                    // Files without an entry for an hour: a share that never finished.
                    try? files.removeItem(at: folder)
                }
            }
        }
        return (entries + legacyLinks()).sorted { $0.date < $1.date }
    }

    private struct LegacyLink: Codable {
        var url: String
        var title: String?
        var date: Date
    }

    private static func legacyURL(_ id: String) -> URL? {
        legacyDirectory?.appendingPathComponent(String(id.dropFirst(legacyPrefix.count)) + ".json")
    }

    private static let legacyPrefix = "link-"

    private static func legacyLinks() -> [Entry] {
        guard let legacyDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: legacyDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            guard let link = try? JSONDecoder().decode(LegacyLink.self, from: data) else {
                // Readable but no link: it would never become one.
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            return Entry(id: legacyPrefix + file.deletingPathExtension().lastPathComponent, url: link.url, title: link.title, date: link.date)
        }
    }

    /// Takes a saved entry out of the inbox, whichever version wrote it.
    static func finish(_ entry: Entry) {
        if entry.id.hasPrefix(legacyPrefix), let url = legacyURL(entry.id) {
            try? FileManager.default.removeItem(at: url)
        } else {
            remove(entry.id)
        }
    }

    // MARK: Bowls for the share sheet

    private static var projectsURL: URL? { root?.appendingPathComponent("ShareProjects.json") }

    static func writeProjects(_ projects: [Project]) {
        guard let projectsURL, let data = try? JSONEncoder().encode(projects) else { return }
        if (try? Data(contentsOf: projectsURL)) != data { try? data.write(to: projectsURL, options: .atomic) }
    }

    static func projects() -> [Project] {
        guard let projectsURL, let data = try? Data(contentsOf: projectsURL) else { return [] }
        return (try? JSONDecoder().decode([Project].self, from: data)) ?? []
    }
}
