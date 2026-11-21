import Foundation
import SwiftData

/// `text` is Markdown (headings, **bold**, *italic*, lists, checklists); tags are `#words` inside it.
/// CloudKit-compatible: every property has a default.
@Model
final class Note {
    var id: UUID = UUID()
    var title: String = ""
    var text: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var statusRaw: String = ProcessingStatus.ready.rawValue
    var errorMessage: String?
    /// Recording that still has to be transcribed and appended to `text`.
    var pendingAudioFileName: String?
    var audioFileNames: [String] = []
    /// `NoteFolder.id`; nil = the default "Notes" folder. From the folder days: now `projectIDs`.
    var folderID: UUID?
    /// The projects (`NoteFolder.id` as uppercase strings) the note belongs to.
    var projectIDs: [String] = []
    var isPinned: Bool = false
    /// Set while the note is in "Recently Deleted".
    var deletedAt: Date?
    /// No longer used: only bowls are archived. Kept for the store and sync; `Archive.clearArchivedNotes` clears it at start.
    var archivedAt: Date?
    /// A saved web link: the address, and the text of the page once it was fetched ("" = nothing to read).
    var url: String?
    var pageText: String?
    /// Tags set by hand or suggested with the summary; `#words` in the text count as tags too (see `tags`).
    var labels: [String] = []
    var summary: String?
    var summaryModel: String?
    var summarizedAt: Date?

    // Recorded meetings are notes too: the recording, its transcript and its speakers live here.
    var titleIsCustom: Bool = false
    var duration: Double = 0
    var inputName: String?
    var channelCount: Int = 1
    var speakerModeRaw: String = SpeakerMode.none.rawValue
    /// The recording the transcript is made from (a meeting). Dictation audio is in `audioFileNames`.
    var audioFileName: String?
    var speakersData: Data?
    var segmentsData: Data?

    // Everything that comes into the app is an intake: it has a channel, waits in the inbox and is filed into bowls.
    /// The channel the note came in through (`NoteSource`); "" for notes from before there were channels.
    var sourceRaw: String = ""
    /// Files that belong to the note (shared images, PDFs, documents) as JSON of `[Attachment]`.
    var attachmentsData: Data?
    /// When the note was first put into a bowl. Whether it is in the inbox does not depend on it (`isInInbox`).
    var filedAt: Date?
    /// The bowls (`NoteFolder.id` as uppercase strings) suggested for the note; taken on or dropped by the user.
    var suggestedProjectIDs: [String] = []

    // A to-do is a note like any other with a done state (`Todos`); its subtasks are the checklist lines of `text`.
    /// `TodoState` raw value: "open", "done", or "none" for a to-do turned back into a note; nil = never a to-do.
    var todoStateRaw: String?
    /// When the to-do was ticked; nil while it is open.
    var todoDoneAt: Date?
    /// The note (`id` as uppercase string) whose summary task this to-do was made from.
    var todoSourceID: String?
    /// The day the to-do is due, "yyyy-MM-dd" (a calendar day, no time, no time zone); "none" when it was taken
    /// away; nil = never set. See `Todos.dueKey`.
    var todoDueDay: String?
    /// What happened to the tasks of the summary offered as to-dos: JSON `{"<task key>": "taken" | "dismissed"}`;
    /// nil = no suggestions offered (`TodoSuggestions`).
    var todoSuggestionsRaw: String?

    init() {
        self.id = UUID()
    }

    var status: ProcessingStatus {
        get { ProcessingStatus(rawValue: statusRaw) ?? .ready }
        set { statusRaw = newValue.rawValue }
    }

    var isDeleted: Bool { deletedAt != nil }

    var speakerMode: SpeakerMode {
        get { SpeakerMode(rawValue: speakerModeRaw) ?? .none }
        set { speakerModeRaw = newValue.rawValue }
    }

    var speakers: [Speaker] {
        get { speakersData.map(TranscriptCache.speakers) ?? [] }
        set { speakersData = try? JSONEncoder().encode(newValue) }
    }

    var segments: [TranscriptSegment] {
        get { segmentsData.map(TranscriptCache.segments) ?? [] }
        set { segmentsData = try? JSONEncoder().encode(newValue) }
    }

    var source: NoteSource {
        get { NoteSource(rawValue: sourceRaw) ?? .unknown }
        set { sourceRaw = newValue.rawValue }
    }

    var attachments: [Attachment] {
        get { attachmentsData.flatMap { try? JSONDecoder().decode([Attachment].self, from: $0) } ?? [] }
        set { attachmentsData = newValue.isEmpty ? nil : try? Attachment.encoder.encode(newValue) }
    }

    /// In the inbox: in no bowl. Everything stays there until it is put into one, and comes back when it is
    /// taken out of its last one.
    var isInInbox: Bool { projectIDs.isEmpty && deletedAt == nil }

    /// Every file of the note in the store: its recordings and its attachments.
    var storedFileNames: [String] {
        [audioFileName, pendingAudioFileName].compactMap { $0 } + audioFileNames + attachments.map(\.fileName)
    }

    var isLink: Bool { url != nil }

    /// An image or a file shared into the app or picked in it: listed as that, not as a note. Images and files are
    /// two kinds that are treated alike. A note that got a file attached stays a note.
    var isStored: Bool { attachmentsData != nil && source == .share && url == nil && !isRecording }

    /// An image: a photo or a screenshot.
    var isImage: Bool { isStored && attachments.first?.kind == .image }

    /// A file: a PDF or a document.
    var isFile: Bool { isStored && !isImage }

    /// Came in from outside (a link, a shared file or text): something to keep, not the user's own words. Such
    /// notes never produce tasks. A recording shared from another app is not one: it is treated like imported
    /// audio, its summary has tasks that can become to-dos.
    var isSaved: Bool { url != nil || (source == .share && !isRecording) }

    /// Nothing in it at all: no title, text, recording, link or summary.
    var isEmptyLeftover: Bool {
        title.isEmpty && text.isEmpty && audioFileNames.isEmpty && pendingAudioFileName == nil
            && audioFileName == nil && segmentsData == nil && url == nil && summary == nil && attachmentsData == nil
    }

    var linkURL: URL? { url.flatMap { URL(string: $0) } }

    /// The SF Symbol of the note's kind, the same in its row, its page and every pill that names it:
    /// a to-do `checklist`, a link `link`, an image `photo`, a PDF `doc.richtext`, another file `doc`, a meeting
    /// `waveform`, a note with a file `paperclip`, a note `text.alignleft`.
    var kindSymbol: String {
        if isTodo { return "checklist" }
        if isLink { return "link" }
        if isStored {
            switch attachments.first?.kind {
            case .image: return "photo"
            case .pdf: return "doc.richtext"
            default: return "doc"
            }
        }
        if isRecording { return "waveform" }
        return attachmentsData != nil ? "paperclip" : "text.alignleft"
    }

    /// The name of the note's kind, for VoiceOver and the bar of its page.
    var kindName: String {
        isTodo ? "To-do" : isLink ? "Link" : isImage ? "Image" : isFile ? "File" : isRecording ? "Meeting" : "Note"
    }

    /// The site of a link without "www.", e.g. "github.com".
    var domain: String? {
        guard let host = linkURL?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The note comes from a recording that is (or will be) transcribed with speakers.
    var isRecording: Bool { audioFileName != nil || segmentsData != nil }

    /// The recording can be read here right now (on this device, or in iCloud and downloaded).
    var hasLocalAudio: Bool { AudioStore.exists(audioFileName) }

    /// The recording is in iCloud and not downloaded here yet: `AudioStore.download` brings it.
    var canFetchAudio: Bool { AudioStore.isInCloud(audioFileName) }

    /// The recording can be read here now or after a download.
    var hasAudio: Bool { AudioStore.isObtainable(audioFileName) }

    /// A part recorded later waits here until it is transcribed (`ProcessingService.processContinuation`).
    /// Notes typed during it count from the end of what is there.
    func addRecordedPart(_ fileName: String, written: [RecordingNote]) {
        pendingAudioFileName = fileName
        status = .recorded
        let start = max(duration, segments.last?.end ?? 0)
        let typed = RecordingNote.markdown(written.map { RecordingNote(at: $0.at + start, text: $0.text) })
        if !typed.isEmpty { text = text.isEmpty ? typed : text + "\n\n" + typed }
        updatedAt = Date()
    }

    static func defaultMeetingTitle(for date: Date) -> String {
        "Meeting · " + date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    func transcriptText(speakers: [Speaker]? = nil, timestamps: Bool = true) -> String {
        let speakers = speakers ?? self.speakers
        return segments.map { segment in
            var prefix = timestamps ? "[\(segment.start.clockString)] " : ""
            if let id = segment.speakerId, let speaker = speakers.first(where: { $0.id == id }) {
                prefix += "\(speaker.name): "
            }
            return prefix + segment.text
        }.joined(separator: "\n")
    }

    /// Everything of the note as text, for sharing.
    var exportText: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append("# \(title)") }
        parts.append(createdAt.formatted(date: .long, time: .shortened))
        if let url { parts.append(url) }
        if isTodo { parts.append((isDone ? "[x] To-do, done" : "[ ] To-do") + (todoDue.map { ", due " + Todos.dueText($0) } ?? "")) }
        if !text.isEmpty { parts.append(text) }
        if let summary, !summary.isEmpty { parts.append("## Summary\n\n\(summary)") }
        if !segments.isEmpty { parts.append("## Transcript\n\n\(transcriptText())") }
        return parts.joined(separator: "\n\n")
    }

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        let firstLine = NoteText.plainLines(text).first ?? ""
        if firstLine.isEmpty, isRecording { return Note.defaultMeetingTitle(for: createdAt) }
        if firstLine.isEmpty, let domain { return domain }
        if firstLine.isEmpty { return status == .transcribing ? "New Note" : "Empty Note" }
        return String(firstLine.prefix(60))
    }

    /// Text for the list row: the body without Markdown marks (and without the first line when it serves as title).
    var preview: String {
        // An open to-do shows what is still to do.
        if isTodo, !isDone {
            let open = Todos.subtasks(in: text).filter { !$0.done }.map(\.text)
            if !open.isEmpty { return NoteText.plainLines(open.joined(separator: " · ")).joined(separator: " ") }
        }
        let lines = NoteText.plainLines(text)
        let own = (title.trimmingCharacters(in: .whitespaces).isEmpty ? lines.dropFirst() : lines[...]).joined(separator: " ")
        if !own.isEmpty { return own }
        // A recording or link without own text shows its summary, or the start of the transcript or page.
        if let summary, let line = NoteText.plainLines(summary).first(where: { !$0.hasPrefix("#") }) { return line }
        if let first = segments.first?.text { return first }
        return pageText.map { String($0.prefix(160)).replacingOccurrences(of: "\n", with: " ") } ?? (domain ?? "")
    }

    /// All tags of the note: its own tag field and the `#words` in its text, without duplicates.
    var tags: [String] {
        var seen = Set<String>()
        return (labels + NoteText.tags(in: text)).filter { seen.insert($0.lowercased()).inserted }
    }

    /// A tag as it is stored: no `#`, no spaces.
    static func cleanTag(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "#,.;")))
            .replacingOccurrences(of: " ", with: "-")
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return query.split(separator: " ").allSatisfy { word in
            title.localizedCaseInsensitiveContains(word) || text.localizedCaseInsensitiveContains(word)
                || (summary?.localizedCaseInsensitiveContains(word) ?? false)
                || (url?.localizedCaseInsensitiveContains(word) ?? false)
                || (pageText?.localizedCaseInsensitiveContains(word) ?? false)
                || (segmentsData != nil && transcriptText(timestamps: false).localizedCaseInsensitiveContains(word))
        }
    }
}

/// Helpers around the Markdown text of a note that need no UI.
enum NoteText {
    private static let tagRegex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_&#/])#([\p{L}\p{N}_][\p{L}\p{N}_-]*)"#)
    private static let marks = try! NSRegularExpression(pattern: #"^\s*(#{1,6}\s+|>\s?|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+\.\s+)"#)

    /// Where the tags (`#word`) are in a line.
    static func tagRanges(in line: String) -> [NSRange] {
        guard line.contains("#") else { return [] }
        return tagRegex.matches(in: line, range: NSRange(location: 0, length: (line as NSString).length)).map(\.range)
    }

    /// Tags (`#word`) in order of appearance, without duplicates (case-insensitive).
    static func tags(in text: String) -> [String] {
        guard text.contains("#") else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, line.contains("#") else { continue }
            let lineNS = line as NSString
            for match in tagRegex.matches(in: line, range: NSRange(location: 0, length: lineNS.length)) {
                let tag = lineNS.substring(with: match.range(at: 1))
                if seen.insert(tag.lowercased()).inserted { result.append(tag) }
            }
        }
        return result
    }

    /// Non-empty lines with block marks (`# `, `- [ ] `, `1. `, `> `) and inline marks (`**`, `*`, `~~`, `` ` ``) removed.
    static func plainLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            var line = String(raw)
            if line.hasPrefix("```") { return nil }
            let range = NSRange(location: 0, length: (line as NSString).length)
            if let match = marks.firstMatch(in: line, range: range) {
                line = (line as NSString).replacingCharacters(in: match.range, with: "")
            }
            for mark in ["**", "~~", "`", "*"] { line = line.replacingOccurrences(of: mark, with: "") }
            line = line.trimmingCharacters(in: .whitespaces)
            return line.isEmpty ? nil : line
        }
    }
}

/// The transcript of a note is stored as JSON and asked for all the time: by the list, and by the open note five
/// times a second while its recording plays. Decoding an hour of meeting each time made the screen stutter; the last
/// few decoded transcripts are kept, found by their bytes.
enum TranscriptCache {
    private final class Box<Value>: NSObject {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let segmentCache: NSCache<NSData, Box<[TranscriptSegment]>> = {
        let cache = NSCache<NSData, Box<[TranscriptSegment]>>()
        cache.countLimit = 6
        return cache
    }()

    private static let speakerCache: NSCache<NSData, Box<[Speaker]>> = {
        let cache = NSCache<NSData, Box<[Speaker]>>()
        cache.countLimit = 64
        return cache
    }()

    static func segments(_ data: Data) -> [TranscriptSegment] {
        let key = data as NSData
        if let cached = segmentCache.object(forKey: key) { return cached.value }
        let value = (try? JSONDecoder().decode([TranscriptSegment].self, from: data)) ?? []
        segmentCache.setObject(Box(value), forKey: key)
        return value
    }

    static func speakers(_ data: Data) -> [Speaker] {
        let key = data as NSData
        if let cached = speakerCache.object(forKey: key) { return cached.value }
        let value = (try? JSONDecoder().decode([Speaker].self, from: data)) ?? []
        speakerCache.setObject(Box(value), forKey: key)
        return value
    }
}
