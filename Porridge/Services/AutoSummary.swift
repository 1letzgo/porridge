import Foundation

/// What comes in from outside gets a summary by itself, as soon as its content is there: a link once its page is
/// loaded, an image or a file once its text is read, text shared from another app, and imported audio (a file, a
/// recording shared from another app, or an older Plaud import) once it is transcribed. The user's own notes, to-dos and recordings
/// are summarized only when asked.
///
/// One device does the work: the one the entry came in on (`markOrigin`, kept on that device only). Another device
/// catches up when an entry still has no summary `catchUpDelay` after its last change, e.g. because the device it
/// came in on had no model. Nothing new is synced: a summary travels in the fields it always did.
///
/// Never twice, never over the user: only an entry with neither a summary nor `summarizedAt` is summarized. A summary
/// the user deleted keeps its `summarizedAt` (`SummaryService.removeSummary`), so it does not come back by itself.
/// The summary of a link, image, file or shared text has no tasks (`SummaryService.notePrompt`, `TodoSuggestions`).
/// DESIGN.md "Summaries of incoming entries".
enum AutoSummary {
    enum Kind: String {
        case link, image, file, sharedText, importedAudio
    }

    /// Less text than this is not worth a summary (a photo with a word on it, a page that could not be read).
    static let minimumCharacters = 280
    /// How long another device leaves an entry to the device it came in on.
    static let catchUpDelay: TimeInterval = 2 * 3600
    /// Another device only catches up on entries of the last 30 days, not on everything ever saved.
    static let catchUpWindow: TimeInterval = 30 * 86400
    /// A failed summary is tried again after this long, at most `attemptsPerLaunch` times while the app runs.
    static let retryDelay: TimeInterval = 15 * 60
    static let attemptsPerLaunch = 3

    /// The kind of an incoming entry; nil for the user's own notes, to-dos and recordings.
    static func kind(of note: Note) -> Kind? {
        if note.isTodo { return nil }
        if note.isLink { return .link }
        if note.isStored { return note.isImage ? .image : .file }
        // Audio shared from another app is imported audio too (its tasks become to-dos, see `Note.isSaved`).
        if note.isRecording { return [.audioImport, .plaud, .share].contains(note.source) ? .importedAudio : nil }
        if note.source == .share, note.attachmentsData == nil { return .sharedText }
        return nil
    }

    /// The text the summary is made from.
    static func material(of note: Note, kind: Kind) -> String {
        let text: String
        switch kind {
        case .link, .image, .file: text = note.pageText ?? ""
        case .sharedText: text = note.text
        case .importedAudio: text = note.transcriptText(timestamps: false)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `note` is to be summarized now. `isOrigin`: it came in on this device.
    static func isDue(_ note: Note, isOrigin: Bool, enabled: Bool = AppSettings.summarizeIncoming, now: Date = Date()) -> Bool {
        guard enabled, !note.isDeleted, note.summary == nil, note.summarizedAt == nil,
              let kind = kind(of: note),
              note.status == .ready, note.pendingAudioFileName == nil,
              material(of: note, kind: kind).count >= minimumCharacters else { return false }
        if isOrigin { return true }
        return now.timeIntervalSince(note.updatedAt) >= catchUpDelay && now.timeIntervalSince(note.createdAt) <= catchUpWindow
    }

    // MARK: - Where an entry came in

    static let originsKey = "autoSummaryOrigins"

    /// Notes the entry came in on this device, still waiting for their summary. Kept on this device only.
    static func origins(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: originsKey) ?? [])
    }

    static func isOrigin(_ id: UUID, _ defaults: UserDefaults = .standard) -> Bool {
        origins(defaults).contains(id.uuidString)
    }

    /// Called where an entry comes in: share sheet, pasted or dropped link, picked or dropped file, imported audio.
    static func markOrigin(_ id: UUID, _ defaults: UserDefaults = .standard) {
        var all = origins(defaults)
        guard all.insert(id.uuidString).inserted else { return }
        defaults.set(Array(all), forKey: originsKey)
    }

    /// Once summarized (or gone), the mark is not needed any more.
    static func clearOrigin(_ id: UUID, _ defaults: UserDefaults = .standard) {
        var all = origins(defaults)
        guard all.remove(id.uuidString) != nil else { return }
        defaults.set(Array(all), forKey: originsKey)
    }

    /// Marks of notes that are gone or summarized are dropped, so the list does not grow forever.
    static func pruneOrigins(keeping notes: [Note], _ defaults: UserDefaults = .standard) {
        let waiting = Set(notes.filter { !$0.isDeleted && $0.summary == nil && $0.summarizedAt == nil }.map(\.id.uuidString))
        let all = origins(defaults)
        let kept = all.intersection(waiting)
        if kept != all { defaults.set(Array(kept), forKey: originsKey) }
    }

    // MARK: - Attempts

    /// Failed attempts while the app runs: when the next one may start.
    struct Attempts {
        private var failures: [UUID: (count: Int, last: Date)] = [:]

        func mayTry(_ id: UUID, now: Date = Date()) -> Bool {
            guard let failure = failures[id] else { return true }
            return failure.count < AutoSummary.attemptsPerLaunch && now.timeIntervalSince(failure.last) >= AutoSummary.retryDelay
        }

        mutating func failed(_ id: UUID, at now: Date = Date()) {
            failures[id] = ((failures[id]?.count ?? 0) + 1, now)
        }

        mutating func succeeded(_ id: UUID) {
            failures[id] = nil
        }
    }
}
