import Foundation
import Observation
import SwiftData

/// Everything in the app (or one bowl) as plain files that need no Porridge to read: a Markdown file per entry with
/// front matter (kind, bowl, tags, dates, document, to-do), its text, summary and transcript; its attachments and
/// recordings in a folder next to it; and `porridge.json` with all of it in a stable schema (`Archive`, version 1).
///
///     Porridge Export 2026-11-22 14.30/
///       porridge.json
///       Inbox/2026-11-20 Shopping.md
///       Bowls/Taxes/2026-03-02 Invoice Telekom.md
///       Bowls/Taxes/2026-03-02 Invoice Telekom/Rechnung.pdf
///
/// Built in two steps: `plan` reads the store on the main actor into plain values; `write` writes the files away
/// from it, fetching files that are only in iCloud, with progress and cancellation.
enum FullExport {
    /// What is exported.
    enum Scope: Equatable, Sendable {
        case everything
        case bowl(UUID)
    }

    // MARK: - The JSON schema (version 1)

    /// The whole export. Field names and meanings stay; new fields may come, with `version` raised only when a
    /// field changes its meaning.
    struct Archive: Codable, Equatable, Sendable {
        var format = "de.letzgo.porridge.export"
        var version = 1
        var exportedAt: Date
        /// "everything" or "bowl".
        var scope: String
        var bowls: [Bowl]
        var entries: [Entry]
    }

    struct Bowl: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var createdAt: Date
        var updatedAt: Date
        var archivedAt: Date?
        var isPinned: Bool
        /// The bowl's folder in the export, relative to its root.
        var folder: String
    }

    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var title: String
        /// "note", "todo", "link", "image", "file" or "meeting".
        var kind: String
        /// The channel it came in through: "note", "meeting", "link", "share", "plaud" (older imports from Plaud), "import", or "" (older).
        var source: String
        /// The bowl (`Bowl.id`); nil in the inbox.
        var bowlID: String?
        var bowl: String?
        var tags: [String]
        var createdAt: Date
        var updatedAt: Date
        var filedAt: Date?
        var isPinned: Bool
        /// Markdown.
        var text: String
        var summary: String?
        var summaryModel: String?
        var summarizedAt: Date?
        var url: String?
        /// The text read out of the page of a link or out of the attached files.
        var pageText: String?
        var todo: Todo?
        var document: Document?
        var meeting: Meeting?
        var attachments: [File]
        var recordings: [File]
        /// The entry's Markdown file, relative to the export's root.
        var markdown: String
    }

    struct Todo: Codable, Equatable, Sendable {
        /// "open" or "done".
        var state: String
        var doneAt: Date?
        /// "yyyy-MM-dd".
        var due: String?
        var subtasks: [Subtask]
        /// How it repeats, as shown ("Every week"); nil when it does not.
        var repeats: String?
        /// The repeat rule as stored ("w:1:…").
        var repeatRule: String?
    }

    struct Subtask: Codable, Equatable, Sendable {
        var text: String
        var done: Bool
        var indent: Int
    }

    struct Document: Codable, Equatable, Sendable {
        /// `DocumentKind` raw value: "invoice", "receipt", "contract", …
        var kind: String?
        /// "yyyy-MM-dd".
        var date: String?
        var sender: String?
        /// "119.00 EUR".
        var amount: String?
        var setByHand: Bool
    }

    struct Meeting: Codable, Equatable, Sendable {
        var duration: Double
        var input: String?
        var speakers: [Speaker]
        var transcript: [Segment]
    }

    struct Speaker: Codable, Equatable, Sendable {
        var id: String
        var name: String
    }

    struct Segment: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
        var speaker: String?
        var text: String
    }

    struct File: Codable, Equatable, Sendable {
        /// What the file is called.
        var name: String
        /// "image", "pdf", "file" (attachments), "recording" or "dictation".
        var kind: String
        var bytes: Int64?
        /// The copy in the export, relative to its root; nil when the file could not be had (only on another
        /// device, not in iCloud yet).
        var path: String?
    }

    // MARK: - The plan

    /// A file of the store to copy into the export.
    struct Copy: Equatable, Sendable {
        var storedName: String
        var kind: StoredFileKind
        /// Relative to the export's root.
        var target: String
        var entry: Int
        var isRecording: Bool
        var index: Int
    }

    /// Everything to write, as plain values.
    struct Plan: Equatable, Sendable {
        var archive: Archive
        /// Markdown files by their path; the file list in each is filled in once the files are copied.
        var markdown: [(path: String, entry: Int)]
        var copies: [Copy]
        /// The name of the export's folder.
        var folderName: String

        static func == (a: Plan, b: Plan) -> Bool {
            a.archive == b.archive && a.copies == b.copies && a.folderName == b.folderName
                && a.markdown.map(\.path) == b.markdown.map(\.path) && a.markdown.map(\.entry) == b.markdown.map(\.entry)
        }

        /// Steps for the progress: each Markdown file and each copied file.
        var steps: Int { markdown.count + copies.count + 1 }
    }

    /// Reads what is exported. Entries in the trash are left out.
    @MainActor
    static func plan(_ scope: Scope, in context: ModelContext, now: Date = Date()) -> Plan {
        let notes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        let bowls = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        return plan(scope, notes: notes, bowls: bowls, now: now)
    }

    @MainActor
    static func plan(_ scope: Scope, notes: [Note], bowls allBowls: [NoteFolder], now: Date = Date()) -> Plan {
        let bowls: [NoteFolder]
        switch scope {
        case .everything: bowls = allBowls.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .bowl(let id): bowls = allBowls.filter { $0.id == id }
        }
        let byKey = Dictionary(allBowls.map { (Projects.key($0), $0) }, uniquingKeysWith: { first, _ in first })

        // A folder for each bowl, named after it; two of the same name get a number.
        var bowlFolders: [String: String] = [:]
        var usedBowlNames = Set<String>()
        for bowl in bowls {
            let name = unique(safeName(bowl.name, fallback: "Bowl"), in: &usedBowlNames)
            bowlFolders[Projects.key(bowl)] = "Bowls/" + name
        }

        let living = notes.filter { !$0.isDeleted }
        let chosen: [(note: Note, bowl: NoteFolder?)] = living.compactMap { note in
            // An entry is in one bowl at most; one in a bowl that is gone counts as in the inbox.
            let bowl = note.projectIDs.lazy.compactMap { byKey[$0] }.first
            switch scope {
            case .everything: return (note, bowl)
            case .bowl(let id): return bowl?.id == id ? (note, bowl) : nil
            }
        }.sorted { $0.note.createdAt != $1.note.createdAt ? $0.note.createdAt < $1.note.createdAt : $0.note.id.uuidString < $1.note.id.uuidString }

        var entries: [Entry] = []
        var markdown: [(path: String, entry: Int)] = []
        var copies: [Copy] = []
        var usedInFolder: [String: Set<String>] = [:]
        for (note, bowl) in chosen {
            let folder = bowl.flatMap { bowlFolders[Projects.key($0)] } ?? "Inbox"
            let day = DocumentInfo.dayKey(note.createdAt)
            let base = unique(day + " " + safeName(note.displayTitle, fallback: "Entry"), in: &usedInFolder[folder, default: []])
            let index = entries.count
            var entry = entry(for: note, bowl: bowl, markdown: folder + "/" + base + ".md")

            // Files go into a folder named like the Markdown file; each name once.
            var usedFiles = Set<String>()
            for (offset, attachment) in note.attachments.enumerated() {
                let name = unique(fileName(attachment.name, stored: attachment.fileName), in: &usedFiles)
                copies.append(Copy(storedName: attachment.fileName, kind: .attachment, target: folder + "/" + base + "/" + name,
                                   entry: index, isRecording: false, index: offset))
            }
            for (offset, recording) in recordings(of: note).enumerated() {
                let ext = (recording.stored as NSString).pathExtension
                let name = unique(recording.label + (ext.isEmpty ? "" : "." + ext), in: &usedFiles)
                copies.append(Copy(storedName: recording.stored, kind: .recording, target: folder + "/" + base + "/" + name,
                                   entry: index, isRecording: true, index: offset))
                entry.recordings.append(File(name: name, kind: recording.kind, bytes: nil, path: nil))
            }
            entries.append(entry)
            markdown.append((entry.markdown, index))
        }

        let archive = Archive(
            exportedAt: now,
            scope: scope == .everything ? "everything" : "bowl",
            bowls: bowls.map { bowl in
                Bowl(id: Projects.key(bowl), name: bowl.name, createdAt: bowl.createdAt, updatedAt: bowl.updatedAt,
                     archivedAt: bowl.archivedAt, isPinned: bowl.isPinned, folder: bowlFolders[Projects.key(bowl)] ?? "")
            },
            entries: entries
        )
        let stamp = folderStamp(now)
        let folderName: String
        switch scope {
        case .everything: folderName = "Porridge Export \(stamp)"
        case .bowl: folderName = "Porridge \(safeName(bowls.first?.name ?? "Bowl", fallback: "Bowl")) \(stamp)"
        }
        return Plan(archive: archive, markdown: markdown, copies: copies, folderName: folderName)
    }

    @MainActor
    private static func entry(for note: Note, bowl: NoteFolder?, markdown: String) -> Entry {
        let info = note.attachmentsData == nil ? nil : note.documentInfo
        let speakers = note.speakers
        return Entry(
            id: note.id.uuidString,
            title: note.displayTitle,
            kind: kind(of: note),
            source: note.sourceRaw,
            bowlID: bowl.map(Projects.key),
            bowl: bowl?.name,
            tags: note.tags,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
            filedAt: bowl == nil ? nil : note.filedAt,
            isPinned: note.isPinned,
            text: note.text,
            summary: note.summary,
            summaryModel: note.summaryModel,
            summarizedAt: note.summarizedAt,
            url: note.url,
            pageText: (note.pageText ?? "").isEmpty ? nil : note.pageText,
            todo: note.isTodo ? Todo(
                state: note.isDone ? "done" : "open",
                doneAt: note.todoDoneAt,
                due: note.todoDue,
                subtasks: Todos.subtasks(in: note.text).map { Subtask(text: $0.text, done: $0.done, indent: $0.indent) },
                repeats: note.todoRepeat?.title,
                repeatRule: note.todoRepeat?.raw
            ) : nil,
            document: info.flatMap { info in
                info.isEmpty ? nil : Document(
                    kind: info.kindRaw, date: info.day, sender: info.correspondent, amount: info.amount, setByHand: info.edited
                )
            },
            meeting: note.isRecording ? Meeting(
                duration: note.duration,
                input: note.inputName,
                speakers: speakers.map { Speaker(id: $0.id, name: $0.name) },
                transcript: note.segments.map { segment in
                    Segment(start: segment.start, end: segment.end,
                            speaker: segment.speakerId.flatMap { id in speakers.first { $0.id == id }?.name }, text: segment.text)
                }
            ) : nil,
            attachments: note.attachments.map { File(name: $0.name, kind: $0.kind.rawValue, bytes: $0.bytes, path: nil) },
            recordings: [],
            markdown: markdown
        )
    }

    /// The entry's kind as the app shows it.
    @MainActor
    static func kind(of note: Note) -> String {
        if note.isTodo { return "todo" }
        if note.isLink { return "link" }
        if note.isImage { return "image" }
        if note.isFile { return "file" }
        if note.isRecording { return "meeting" }
        return "note"
    }

    /// The meeting's recording, a part still being transcribed, and dictated audio.
    @MainActor
    private static func recordings(of note: Note) -> [(stored: String, label: String, kind: String)] {
        var result: [(String, String, String)] = []
        if let audio = note.audioFileName { result.append((audio, "Recording", "recording")) }
        if let pending = note.pendingAudioFileName, pending != note.audioFileName { result.append((pending, "Recording (part)", "recording")) }
        for (index, name) in note.audioFileNames.enumerated() where name != note.audioFileName {
            result.append((name, note.audioFileNames.count > 1 ? "Dictation \(index + 1)" : "Dictation", "dictation"))
        }
        return result
    }

    // MARK: - Names

    /// A name that is fine as a file name everywhere: no slashes, colons or other marks Windows and macOS refuse,
    /// no dot in front, at most 80 characters.
    static func safeName(_ name: String, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var clean = name.components(separatedBy: illegal).joined(separator: " ")
        clean = clean.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = String(clean.prefix(80)).trimmingCharacters(in: .whitespaces)
        while clean.hasSuffix(".") { clean.removeLast() }
        return clean.isEmpty ? fallback : clean
    }

    /// The file's own name, with the extension of the stored file when the name has none.
    static func fileName(_ name: String, stored: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = safeName(ext.isEmpty ? name : (name as NSString).deletingPathExtension, fallback: "File")
        let storedExt = (stored as NSString).pathExtension
        let finalExt = ext.isEmpty ? (storedExt == "bin" ? "" : storedExt) : ext
        return finalExt.isEmpty ? base : base + "." + finalExt
    }

    /// The name, or "name 2", "name 3" … when it is taken (case does not count: macOS would not tell them apart).
    static func unique(_ name: String, in used: inout Set<String>) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = name
        var number = 2
        while used.contains(candidate.lowercased()) {
            candidate = base + " \(number)" + (ext.isEmpty ? "" : "." + ext)
            number += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    static func folderStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }

    // MARK: - Markdown

    /// The entry as a Markdown file: YAML front matter, then title, text, summary and transcript, then links to its files.
    /// - Parameter links: the exported entries by id (`linkTargets`): links between entries in the text point to
    ///   their Markdown files; links to entries not in the export stay `porridge://entry/…` links.
    static func markdown(for entry: Entry, links: [String: LinkTarget] = [:]) -> String {
        var front: [String] = ["---"]
        front.append("id: \(entry.id)")
        front.append("title: \(yaml(entry.title))")
        front.append("kind: \(entry.kind)")
        if !entry.source.isEmpty { front.append("source: \(entry.source)") }
        front.append("bowl: \(entry.bowl.map(yaml) ?? "null")")
        front.append("tags: [" + entry.tags.map(yaml).joined(separator: ", ") + "]")
        front.append("created: \(isoDate(entry.createdAt))")
        front.append("updated: \(isoDate(entry.updatedAt))")
        if let filed = entry.filedAt { front.append("filed: \(isoDate(filed))") }
        if entry.isPinned { front.append("pinned: true") }
        if let url = entry.url { front.append("url: \(yaml(url))") }
        if let todo = entry.todo {
            front.append("todo:")
            front.append("  state: \(todo.state)")
            if let due = todo.due { front.append("  due: \(due)") }
            if let done = todo.doneAt { front.append("  done: \(isoDate(done))") }
            if let repeats = todo.repeats { front.append("  repeats: \(yaml(repeats))") }
        }
        if let document = entry.document {
            front.append("document:")
            if let kind = document.kind { front.append("  kind: \(kind)") }
            if let date = document.date { front.append("  date: \(date)") }
            if let sender = document.sender { front.append("  sender: \(yaml(sender))") }
            if let amount = document.amount { front.append("  amount: \(yaml(amount))") }
            if document.setByHand { front.append("  set_by_hand: true") }
        }
        if let meeting = entry.meeting {
            front.append("duration: \(Int(meeting.duration.rounded()))")
            if !meeting.speakers.isEmpty { front.append("speakers: [" + meeting.speakers.map { yaml($0.name) }.joined(separator: ", ") + "]") }
        }
        if let summarized = entry.summarizedAt { front.append("summarized: \(isoDate(summarized))") }
        let files = entry.attachments.compactMap(\.path) + entry.recordings.compactMap(\.path)
        if !files.isEmpty {
            front.append("files:")
            for path in files { front.append("  - \(yaml(relative(path, from: entry.markdown)))") }
        }
        front.append("---")

        var body: [String] = ["# " + entry.title.replacingOccurrences(of: "\n", with: " ")]
        if let url = entry.url { body.append("<\(url)>") }
        let text = exportingLinks(in: entry.text, from: entry.markdown, targets: links).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { body.append(text) }
        if let summary = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            body.append("## Summary\n\n" + summary)
        }
        if let meeting = entry.meeting, !meeting.transcript.isEmpty {
            let lines = meeting.transcript.map { segment in
                "**[\(segment.start.clockString)]" + (segment.speaker.map { " \($0):" } ?? "") + "** " + segment.text
            }
            body.append("## Transcript\n\n" + lines.joined(separator: "\n\n"))
        }
        if !entry.attachments.isEmpty {
            body.append("## Attachments\n\n" + entry.attachments.map(fileLine(from: entry.markdown)).joined(separator: "\n"))
        }
        if !entry.recordings.isEmpty {
            body.append("## Recordings\n\n" + entry.recordings.map(fileLine(from: entry.markdown)).joined(separator: "\n"))
        }
        return front.joined(separator: "\n") + "\n\n" + body.joined(separator: "\n\n") + "\n"
    }

    /// An exported entry a link can point to: its title now and its Markdown file.
    struct LinkTarget: Equatable, Sendable {
        var title: String
        var markdown: String
    }

    /// The entries of the archive by id (upper case), for `markdown(for:links:)`.
    static func linkTargets(of archive: Archive) -> [String: LinkTarget] {
        Dictionary(archive.entries.map { ($0.id.uppercased(), LinkTarget(title: $0.title, markdown: $0.markdown)) }, uniquingKeysWith: { first, _ in first })
    }

    /// Links between entries (`EntryLinks`) as links to the exported Markdown files, relative to the file at
    /// `markdown`, labelled with the entry's title. Entries not in the export keep their `porridge://` link.
    static func exportingLinks(in text: String, from markdown: String, targets: [String: LinkTarget]) -> String {
        EntryLinks.rewrite(text) { link in
            guard let target = targets[link.id.uuidString.uppercased()] else {
                return EntryLinks.markdown(id: link.id, title: link.label)
            }
            return "[\(EntryLinks.escape(target.title))](<\(relativePath(to: target.markdown, from: markdown))>)"
        }
    }

    /// The path of `target` seen from the folder of the file at `from` (both relative to the export's root).
    static func relativePath(to target: String, from: String) -> String {
        let base = (from as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        let parts = target.split(separator: "/").map(String.init)
        var common = 0
        while common < base.count, common < parts.count - 1, base[common] == parts[common] { common += 1 }
        return (Array(repeating: "..", count: base.count - common) + parts[common...]).joined(separator: "/")
    }

    private static func fileLine(from markdown: String) -> (File) -> String {
        { file in
            guard let path = file.path else { return "- \(file.name) (not on this device)" }
            return "- [\(file.name)](<\(relative(path, from: markdown))>)"
        }
    }

    /// A path relative to the Markdown file's folder (the files sit next to it).
    static func relative(_ path: String, from markdown: String) -> String {
        let folder = (markdown as NSString).deletingLastPathComponent
        guard !folder.isEmpty, path.hasPrefix(folder + "/") else { return path }
        return String(path.dropFirst(folder.count + 1))
    }

    /// A YAML string in double quotes (JSON's escapes are YAML's).
    static func yaml(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 { result += String(format: "\\u%04X", scalar.value) } else { result.unicodeScalars.append(scalar) }
            }
        }
        return result + "\""
    }

    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: - Writing

    /// Where a stored file can be read; nil when it cannot be had now.
    typealias FileSource = @Sendable (_ storedName: String, _ kind: StoredFileKind) async -> URL?

    /// The store's files: here, or downloaded from iCloud first. One that is not in iCloud yet is not waited for.
    static let storeFiles: FileSource = { name, kind in
        if AudioStore.exists(name, kind: kind) { return AudioStore.url(for: name, kind: kind) }
        if AudioStore.isInCloud(name, kind: kind) { return try? await AudioStore.download(name, kind: kind, timeout: 300) }
        return nil
    }

    /// Writes the plan into `root` (created; it must not exist yet). Reports each step done; throws
    /// `CancellationError` when the task is cancelled (what was written stays for the caller to remove).
    /// Returns the archive as written, with the paths of the files that could be copied.
    @discardableResult
    static func write(
        _ plan: Plan, to root: URL, files: FileSource = storeFiles, progress: @escaping @Sendable (Int) async -> Void = { _ in }
    ) async throws -> Archive {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var archive = plan.archive
        var done = 0

        for copy in plan.copies {
            try Task.checkCancellation()
            if let source = await files(copy.storedName, copy.kind) {
                let target = root.appendingPathComponent(copy.target)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A copy, never a link: a file changed in the export must not change the app's own. On APFS the copy
                // is a clone and costs no room until one of them changes.
                try manager.copyItem(at: source, to: target)
                if copy.isRecording {
                    archive.entries[copy.entry].recordings[copy.index].path = copy.target
                    let size = (try? manager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value
                    archive.entries[copy.entry].recordings[copy.index].bytes = size
                } else {
                    archive.entries[copy.entry].attachments[copy.index].path = copy.target
                }
            }
            done += 1
            await progress(done)
        }

        let links = linkTargets(of: archive)
        for item in plan.markdown {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(item.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(markdown(for: archive.entries[item.entry], links: links).utf8).write(to: url, options: .atomic)
            done += 1
            await progress(done)
        }

        try Task.checkCancellation()
        try encoder.encode(archive).write(to: root.appendingPathComponent("porridge.json"), options: .atomic)
        done += 1
        await progress(done)
        return archive
    }

    /// The JSON as it is written: sorted keys and ISO dates, so the same data are the same bytes.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// `url`, or the first of "name 2", "name 3", … that is not taken: an export never replaces what is there.
    static func available(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for number in 2... {
            let name = base + " \(number)" + (ext.isEmpty ? "" : "." + ext)
            let candidate = folder.appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// The folder as one .zip next to it (the system's own archiver, as Files and Mail make them).
    static func zip(_ folder: URL) throws -> URL {
        // Never over a file that is there already: "Porridge Export 2.zip" then.
        let target = available(folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip"))
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordination) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: target) } catch { failure = error }
        }
        if let error = coordination ?? failure { throw error }
        return target
    }
}

// MARK: - A running export

/// One export with its progress, for the sheet that shows it (iOS) or the window (Mac). Cancel stops it and takes
/// away what was written.
@MainActor
@Observable
final class ExportRun {
    enum State: Equatable {
        case running
        /// Making the .zip.
        case packing
        case finished(URL)
        case failed(String)
        case cancelled
    }

    let scope: FullExport.Scope
    let title: String
    private(set) var state: State = .running
    private(set) var done = 0
    private(set) var total = 1
    private(set) var entryCount = 0
    private(set) var missingFiles = 0
    /// Called on every change, for AppKit.
    var onChange: (() -> Void)?

    private var task: Task<Void, Never>?

    var fraction: Double { total == 0 ? 0 : min(1, Double(done) / Double(total)) }

    var isRunning: Bool { state == .running || state == .packing }

    init(scope: FullExport.Scope, title: String) {
        self.scope = scope
        self.title = title
    }

    /// Writes the export into `directory` (a new folder in it), and packs it into a .zip when asked.
    func start(context: ModelContext, into directory: URL, zip: Bool, files: @escaping FullExport.FileSource = FullExport.storeFiles) {
        let plan = FullExport.plan(scope, in: context)
        total = plan.steps
        entryCount = plan.archive.entries.count
        onChange?()
        // A folder of the same name (an export of the same minute) is left alone: this one gets a name of its own.
        let root = FullExport.available(directory.appendingPathComponent(plan.folderName, isDirectory: true))
        task = Task { [weak self] in
            // Only what this run made is ever taken away again.
            var packed: URL?
            do {
                let archive = try await FullExport.write(plan, to: root, files: files) { done in
                    await MainActor.run { self?.advance(to: done) }
                }
                let missing = archive.entries.reduce(0) { count, entry in
                    count + entry.attachments.filter { $0.path == nil }.count + entry.recordings.filter { $0.path == nil }.count
                }
                try Task.checkCancellation()
                var result = root
                if zip {
                    self?.update(.packing)
                    result = try await Task.detached(priority: .userInitiated) { try FullExport.zip(root) }.value
                    packed = result
                    try? FileManager.default.removeItem(at: root)
                    try Task.checkCancellation()
                }
                self?.missingFiles = missing
                self?.update(.finished(result))
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: root)
                if let packed { try? FileManager.default.removeItem(at: packed) }
                self?.update(.cancelled)
            } catch {
                try? FileManager.default.removeItem(at: root)
                if let packed { try? FileManager.default.removeItem(at: packed) }
                self?.update(.failed(error.localizedDescription))
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
    }

    private func advance(to done: Int) {
        self.done = done
        onChange?()
    }

    private func update(_ state: State) {
        self.state = state
        onChange?()
    }

    /// "Exporting 120 entries…", "Done: 120 entries".
    var statusText: String {
        switch state {
        case .running: String(localized: "Exporting \(entryCount) entries…")
        case .packing: String(localized: "Packing the archive…")
        case .finished:
            missingFiles == 0
                ? String(localized: "Exported \(entryCount) entries.")
                : String(localized: "Exported \(entryCount) entries. \(missingFiles) files were not on this device and are only listed.")
        case .failed(let message): String(localized: "The export failed. \(message)")
        case .cancelled: String(localized: "Export cancelled.")
        }
    }
}
