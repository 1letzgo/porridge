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
    /// `NoteFolder.id`; nil = the default "Notes" folder.
    var folderID: UUID?
    var isPinned: Bool = false
    /// Set while the note is in "Recently Deleted".
    var deletedAt: Date?
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
        get { speakersData.flatMap { try? JSONDecoder().decode([Speaker].self, from: $0) } ?? [] }
        set { speakersData = try? JSONEncoder().encode(newValue) }
    }

    var segments: [TranscriptSegment] {
        get { segmentsData.flatMap { try? JSONDecoder().decode([TranscriptSegment].self, from: $0) } ?? [] }
        set { segmentsData = try? JSONEncoder().encode(newValue) }
    }

    var isLink: Bool { url != nil }

    var linkURL: URL? { url.flatMap { URL(string: $0) } }

    /// The site of a link without "www.", e.g. "github.com".
    var domain: String? {
        guard let host = linkURL?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The note comes from a recording that is (or will be) transcribed with speakers.
    var isRecording: Bool { audioFileName != nil || segmentsData != nil }

    var hasLocalAudio: Bool { AudioStore.exists(audioFileName) }

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
        if let url { parts.append(url) }
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
