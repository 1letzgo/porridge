import Foundation
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Serial queue that turns recordings into transcripts and notes into summaries. It outlives every screen.
@MainActor
@Observable
final class ProcessingService {
    enum Job: Hashable {
        /// A recording that gets a transcript with speakers (`Note.audioFileName`).
        case transcript(UUID)
        /// Dictation audio that is appended to the text of the note (`Note.pendingAudioFileName`).
        case note(UUID)
        /// A saved web link: load the page, then (optionally) summarize it.
        case link(UUID, summarize: Bool)
        /// The summary somebody asked for, in the note or with its template.
        /// `model` is nil for the default.
        case summary(UUID, SummaryTemplate, SummaryModel?)
        /// A plain note whose own text is rewritten by AI (`SummaryService.enhance`).
        case enhance(UUID, SummaryModel?)
        /// A note with attachments: read the text in its images and PDFs, then summarize it.
        case attachment(UUID)
        /// The summary of an incoming entry nobody asked for (`AutoSummary`).
        case autoSummary(UUID)

        var id: UUID {
            switch self {
            case .transcript(let id), .note(let id), .link(let id, _), .summary(let id, _, _), .enhance(let id, _), .attachment(let id), .autoSummary(let id): id
            }
        }

        /// What is done, without the options: two of a kind for one note are the same work.
        var kind: Int {
            switch self {
            case .transcript: 0
            case .note: 1
            case .link: 2
            case .summary: 3
            case .enhance: 4
            case .attachment: 5
            case .autoSummary: 6
            }
        }
    }

    /// Human readable progress per note id.
    private(set) var stages: [UUID: String] = [:]
    /// Notes whose requested summary is waiting or being written.
    private(set) var summarizing: Set<UUID> = []
    /// The model chosen for a summary that is waiting or being written, when it is not the default.
    private(set) var summaryModels: [UUID: SummaryModel] = [:]
    /// Why a summary failed, until the note has shown it (its screen may have been closed by then).
    private(set) var summaryErrors: [UUID: String] = [:]
    /// Notes whose text is waiting to be enhanced or being enhanced.
    private(set) var enhancing: Set<UUID> = []
    /// Why enhancing failed, until the note has shown it.
    private(set) var enhanceErrors: [UUID: String] = [:]
    /// The text before the last enhance, while this app runs: undo applies only while the enhanced text is unchanged.
    private(set) var enhanceUndo: [UUID: EnhanceUndo] = [:]

    struct EnhanceUndo: Equatable {
        let original: String
        let enhanced: String
    }

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var running: Job?
    @ObservationIgnored private var autoAttempts = AutoSummary.Attempts()
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    /// The documents read before this version got their first guess in this launch (`Documents.backfill`).
    @ObservationIgnored private var didBackfillDocuments = false

    init(container: ModelContainer) {
        self.container = container
    }

    private var context: ModelContext { container.mainContext }

    func enqueue(_ job: Job) {
        // The same kind of work for the same note is asked for once; another kind waits its turn.
        guard !queue.contains(where: { $0.id == job.id && $0.kind == job.kind }), running.map({ $0.id == job.id && $0.kind == job.kind }) != true else { return }
        queue.append(job)
        if stages[job.id] == nil { stages[job.id] = "Waiting…" }
        if case .summary(_, _, let model) = job {
            summarizing.insert(job.id)
            summaryModels[job.id] = model
        }
        if case .enhance = job { enhancing.insert(job.id) }
        runIfNeeded()
    }

    func clearSummaryError(_ id: UUID) {
        summaryErrors[id] = nil
    }

    func clearEnhanceError(_ id: UUID) {
        enhanceErrors[id] = nil
    }

    /// Whether the note still shows the text of its last enhance, so undo can bring back the original.
    func canUndoEnhance(_ note: Note) -> Bool {
        enhanceUndo[note.id]?.enhanced == note.text
    }

    /// Puts back the text from before the last enhance.
    func undoEnhance(_ note: Note) {
        guard let undo = enhanceUndo[note.id], undo.enhanced == note.text else { return }
        note.text = undo.original
        note.updatedAt = Date()
        enhanceUndo[note.id] = nil
        save()
    }

    /// Picks up recordings that were interrupted (app killed while transcribing).
    func resumePending() {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        // Only a recording in the folder on this device was made here and is this device's work. One in iCloud
        // belongs to a note that was done before; another device may be the one working on it now.
        for note in notes where [.recorded, .transcribing].contains(note.status) && AudioStore.isLocal(note.audioFileName) && note.pendingAudioFileName == nil {
            enqueue(.transcript(note.id))
        }
        // Nothing left to work on (the file is gone): such a note would wait forever and never sync.
        var released = false
        for note in notes where !note.isLink && note.attachmentsData == nil {
            let pendingLost = note.pendingAudioFileName != nil && !AudioStore.exists(note.pendingAudioFileName)
            let stuck = [.recorded, .transcribing].contains(note.status) && !AudioStore.isLocal(note.audioFileName) && !AudioStore.exists(note.pendingAudioFileName)
            guard pendingLost || stuck else { continue }
            if pendingLost { note.pendingAudioFileName = nil }
            if note.segments.isEmpty, note.text.isEmpty, note.audioFileName == nil {
                note.status = .failed
                note.errorMessage = ASRPipelineError.missingAudio.localizedDescription
            } else {
                note.status = .ready
            }
            released = true
        }
        if released { save() }
        for note in notes where AudioStore.exists(note.pendingAudioFileName) {
            enqueue(.note(note.id))
        }
        // Once: files an earlier version could not read (Word, OpenDocument, rich text) are read again, so the search
        // and the chat find what is in them.
        if !UserDefaults.standard.bool(forKey: "documentsReadAgain") {
            UserDefaults.standard.set(true, forKey: "documentsReadAgain")
            var forgotten = false
            for note in notes where note.attachmentsData != nil && !note.isDeleted && !note.isRecording && note.pageText == "" {
                note.pageText = nil
                forgotten = true
            }
            if forgotten { save() }
        }
        // Attachments whose text was not read yet (the app was closed before it got to them).
        for note in notes where note.attachmentsData != nil && !note.isDeleted && !note.isRecording
            && (note.pageText == nil || note.status == .recorded) {
            enqueue(.attachment(note.id))
        }
        // Links whose page was not loaded yet (the app was closed before it got to them).
        for note in notes where note.isLink && !note.isDeleted && note.status != .failed && (note.pageText == nil || note.status == .recorded) {
            enqueue(.link(note.id, summarize: true))
        }
        AutoSummary.pruneOrigins(keeping: notes)
        summarizeIncoming()
    }

    // MARK: - Summaries of incoming entries

    /// Queues the summary of every incoming entry that is due (`AutoSummary.isDue`). Called at launch, when the app
    /// comes to the front, and when the notes change (new entries, sync): cheap when nothing is due.
    func summarizeIncoming() {
        // Looked at again from time to time: a failed one is retried, another device's entry may be due to catch up,
        // a model may have arrived.
        if sweepTask == nil {
            sweepTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(AutoSummary.retryDelay))
                guard !Task.isCancelled else { return }
                self?.sweepTask = nil
                self?.summarizeIncoming()
            }
        }
        // Files read before documents were looked at (or synced from a device that does not read them) get their
        // first guess, once per launch.
        if !didBackfillDocuments {
            didBackfillDocuments = true
            Documents.backfill(in: context)
        }
        guard AppSettings.summarizeIncoming, SummaryService.canRunWithoutAsking else { return }
        let notes = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.summary == nil && $0.summarizedAt == nil && $0.deletedAt == nil }))) ?? []
        let origins = AutoSummary.origins()
        for note in notes where autoAttempts.mayTry(note.id) && AutoSummary.isDue(note, isOrigin: origins.contains(note.id.uuidString)) {
            enqueue(.autoSummary(note.id))
        }
    }

    /// Right after an entry's content arrived (page loaded, text read, transcript done).
    private func summarizeIfIncoming(_ note: Note) {
        guard AppSettings.summarizeIncoming, SummaryService.canRunWithoutAsking, autoAttempts.mayTry(note.id),
              AutoSummary.isDue(note, isOrigin: AutoSummary.isOrigin(note.id)) else { return }
        enqueue(.autoSummary(note.id))
    }

    private func processAutoSummary(_ id: UUID) async {
        // Checked again: it may have been summarized, edited or deleted while it waited.
        guard let note = fetchNote(id), SummaryService.canRunWithoutAsking,
              AutoSummary.isDue(note, isOrigin: AutoSummary.isOrigin(id)) else { return }
        stages[id] = "Summarizing…"
        do {
            try await SummaryService.summarize(note, onlyIfEmpty: true) { [weak self] status in self?.stages[id] = status }
            autoAttempts.succeeded(id)
            AutoSummary.clearOrigin(id)
            save()
        } catch is CancellationError {
            // Gone, or summarized or edited meanwhile: nothing to do.
        } catch {
            // No model, no connection, no answer: quietly again later (`AutoSummary.retryDelay`).
            autoAttempts.failed(id)
        }
    }

    private func runIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                running = job
                await withBackgroundTime {
                    switch job {
                    case .transcript(let id): await processTranscript(id)
                    case .note(let id): await processNote(id)
                    case .link(let id, let summarize): await processLink(id, summarize: summarize)
                    case .summary(let id, let template, let model): await processSummary(id, template: template, model: model)
                    case .enhance(let id, let model): await processEnhance(id, model: model)
                    case .attachment(let id): await processAttachments(id)
                    case .autoSummary(let id): await processAutoSummary(id)
                    }
                }
                running = nil
                // Another job for this note may still wait: its marks stay.
                let waiting = queue.filter { $0.id == job.id }
                stages[job.id] = waiting.isEmpty ? nil : "Waiting…"
                if !waiting.contains(where: { $0.kind == 3 }) {
                    summarizing.remove(job.id)
                    summaryModels[job.id] = nil
                }
                if !waiting.contains(where: { $0.kind == 4 }) { enhancing.remove(job.id) }
            }
            isRunning = false
        }
    }

    // MARK: - Recordings with a transcript

    private func processTranscript(_ id: UUID) async {
        guard let meeting = fetchNote(id) else { return }
        guard let fileName = meeting.audioFileName, AudioStore.isObtainable(fileName) else {
            meeting.status = .failed
            meeting.errorMessage = ASRPipelineError.missingAudio.localizedDescription
            save()
            return
        }
        if !AudioStore.exists(fileName) {
            // In iCloud only ("Detect Speakers Again" on another device than the one it was recorded on).
            stages[id] = "Downloading recording…"
            do {
                try await AudioStore.download(fileName)
            } catch {
                guard exists(id) else { return }
                meeting.status = .failed
                meeting.errorMessage = error.localizedDescription
                save()
                return
            }
            guard exists(id) else { return }
        }
        meeting.status = .transcribing
        meeting.errorMessage = nil
        save()

        do {
            try await transcribe(meeting, fileName: fileName, stageID: id)
            // A new transcript is a change: without this an older copy from another device would win over it.
            meeting.updatedAt = Date()
        } catch {
            guard exists(id) else { return }
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
        }
        save()
        // Imported audio is summarized by itself; the user's own recordings when asked.
        summarizeIfIncoming(meeting)
    }

    /// Fills `meeting` with the transcript and speakers of the recording.
    private func transcribe(_ meeting: Note, fileName: String, stageID id: UUID) async throws {
        stages[id] = "Preparing audio…"
        let splitChannels = meeting.speakerMode == .channels
        let source = AudioStore.url(for: fileName)
        let prepared = try await Task.detached(priority: .userInitiated) {
            try AudioPreprocessor.prepare(source: source, measureChannels: splitChannels)
        }.value
        defer { try? FileManager.default.removeItem(at: prepared.monoURL) }

        stages[id] = "Loading speech model…"
        try await ModelManager.shared.ensureASR()
        stages[id] = "Transcribing…"
        let output = try await TranscriptionEngine.shared.transcribe(prepared.monoURL, language: AppSettings.language)
        try stillThere(meeting, id)

        var speakers = meeting.speakers
        var mode = meeting.speakerMode
        var diagnostics: String?
        var speakerIds: [String?] = output.words.map { _ in nil }

        if let energy = prepared.channelEnergy {
            speakerIds = SpeakerAssigner.byChannel(output.words, energy: energy)
            for (index, channelID) in [SpeakerAssigner.leftChannelID, SpeakerAssigner.rightChannelID].enumerated()
            where !speakers.contains(where: { $0.id == channelID }) {
                speakers.append(Speaker(id: channelID, name: "Speaker \(index + 1)", colorIndex: index))
            }
        } else if AppSettings.speakerDetectionEnabled, !output.words.isEmpty {
            stages[id] = "Detecting speakers…"
            do {
                try await ModelManager.shared.ensureDiarizer()
                let segments = try await TranscriptionEngine.shared.diarize(prepared.monoURL)
                let assignment = SpeakerAssigner.byDiarization(output.words, segments: segments)
                // A single voice is kept too, so it can be recognized or named like any other.
                diagnostics = assignment.speakers.isEmpty
                    ? "Speaker detection found no speech (\(segments.count) segments)." : nil
                if !assignment.speakers.isEmpty {
                    speakerIds = assignment.ids
                    speakers = assignment.speakers.enumerated().map { index, sid in
                        speakers.first(where: { $0.id == sid })
                            ?? Speaker(id: sid, name: "Speaker \(index + 1)", colorIndex: index)
                    }
                    mode = .diarized
                } else {
                    speakers = []
                    mode = .none
                }
            } catch {
                // Speaker detection is optional; keep the plain transcript.
                diagnostics = "Speaker detection failed: \(error.localizedDescription)"
                speakers = []
                mode = .none
            }
        }
        try stillThere(meeting, id)
        meeting.speakerMode = mode

        meeting.segments = SpeakerAssigner.group(output.words, speakerIds: speakerIds)
        // Drop speakers that ended up without any text (e.g. brief false detections).
        let used = Set(meeting.segments.compactMap(\.speakerId))
        meeting.speakers = speakers.filter { used.contains($0.id) }
        if meeting.speakerMode == .diarized, meeting.speakers.isEmpty {
            meeting.speakers = []
            meeting.speakerMode = .none
            meeting.segments = meeting.segments.map { var s = $0; s.speakerId = nil; return s }
        }
        meeting.errorMessage = diagnostics
        if meeting.segments.isEmpty, !output.text.isEmpty {
            meeting.segments = [TranscriptSegment(speakerId: nil, start: 0, end: prepared.duration, text: output.text)]
        }
        if AppSettings.voiceRecognitionEnabled, !meeting.speakers.isEmpty {
            stages[id] = "Recognizing voices…"
            let identified = await VoiceProfiles.identify(
                meeting.speakers, segments: meeting.segments, audio: prepared.monoURL, context: context)
            try stillThere(meeting, id)
            meeting.speakers = identified
        }
        meeting.duration = prepared.duration
        meeting.status = .ready
    }

    /// A meeting that was recorded further: the new part gets its own transcript, then joins the meeting. What was
    /// there (names, corrections) stays. The part waits in `pendingAudioFileName`, so a failure or restart loses nothing.
    private func processContinuation(_ meeting: Note, fileName: String) async {
        let id = meeting.id
        meeting.status = .transcribing
        meeting.errorMessage = nil
        save()
        do {
            let part = Note()
            part.createdAt = Date()
            part.audioFileName = fileName
            part.speakerMode = AudioStore.audioInfo(for: fileName)?.channels == 2 ? .channels : .none
            try await transcribe(part, fileName: fileName, stageID: id)
            guard exists(id) else { return }
            stages[id] = "Adding to the meeting…"
            try await NoteMerger.append(part, to: meeting)
            meeting.pendingAudioFileName = nil
            meeting.errorMessage = part.errorMessage
            meeting.updatedAt = Date()
        } catch {
            guard exists(id) else { return }
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
        }
        save()
    }

    // MARK: - Notes

    private func processNote(_ id: UUID) async {
        guard let note = fetchNote(id),
              let fileName = note.pendingAudioFileName,
              AudioStore.exists(fileName) else { return }
        if note.isRecording {
            await processContinuation(note, fileName: fileName)
            return
        }
        note.status = .transcribing
        note.errorMessage = nil
        save()

        do {
            stages[id] = "Preparing audio…"
            let source = AudioStore.url(for: fileName)
            let prepared = try await Task.detached(priority: .userInitiated) {
                try AudioPreprocessor.prepare(source: source, measureChannels: false)
            }.value
            defer { try? FileManager.default.removeItem(at: prepared.monoURL) }

            stages[id] = "Loading speech model…"
            try await ModelManager.shared.ensureASR()
            stages[id] = "Transcribing…"
            let output = try await TranscriptionEngine.shared.transcribe(prepared.monoURL, language: AppSettings.language)
            guard exists(id) else { return }

            let text = Paragraphs.format(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if !text.isEmpty {
                note.text = note.text.isEmpty ? text : note.text + "\n\n" + text
            }
            note.audioFileNames.append(fileName)
            note.pendingAudioFileName = nil
            note.updatedAt = Date()
            note.status = .ready
        } catch {
            guard exists(id) else { return }
            note.status = .failed
            note.errorMessage = error.localizedDescription
        }
        save()
    }

    // MARK: - Links

    private func processLink(_ id: UUID, summarize: Bool) async {
        guard let note = fetchNote(id), let address = note.url else { return }

        // The page is loaded once; "Load Page Again" and a new link (status .recorded) load it.
        if note.pageText == nil || note.status == .recorded {
            stages[id] = "Loading page…"
            do {
                let page = try await LinkFetcher.fetch(address)
                guard exists(id) else { return }
                note.pageText = page.text
                if let title = page.title, note.title.isEmpty || note.title == address || note.title == note.domain {
                    note.title = title
                }
                note.status = .ready
                note.errorMessage = nil
            } catch {
                guard exists(id) else { return }
                note.status = .failed
                note.errorMessage = error.localizedDescription
                save()
                return
            }
            save()
        }

        if summarize { summarizeIfIncoming(note) }
    }

    // MARK: - Attachments

    /// Reads the text of the note's images, PDFs and text files into `pageText` and summarizes it, like a saved page.
    private func processAttachments(_ id: UUID) async {
        guard let note = fetchNote(id) else { return }
        stages[id] = "Reading text…"
        let text = await readAttachments(of: note)
        guard exists(id) else { return }
        // A document: what it is (kind, date, sender, amount) guessed on the device right away, and the bowl its
        // sender's documents went into suggested. The summary's model refines both.
        if note.pageText != nil, Documents.read(note, text: text), note.suggestedProjectIDs.isEmpty,
           let bowl = Documents.suggestedBowl(for: note, in: context) {
            note.suggestedProjectIDs = [bowl]
        }
        note.status = .ready
        note.errorMessage = nil
        note.updatedAt = Date()
        save()

        if !text.isEmpty { summarizeIfIncoming(note) }
    }

    /// Reads the text of the note's files into `pageText` and returns it. Files in iCloud are downloaded first. While
    /// a file is missing (it is only on another device, or iCloud could not deliver it) and nothing was read, the note
    /// counts as not looked at yet (`pageText` stays nil).
    @discardableResult
    private func readAttachments(of note: Note) async -> String {
        let id = note.id
        let attachments = note.attachments
        // One iCloud does not have yet is not waited for: the queue would stand still. It is read another time.
        for attachment in attachments where AttachmentStore.isInCloud(attachment) {
            do {
                try await AttachmentStore.download(attachment, timeout: 180)
            } catch {
                print("[files] \(attachment.fileName) not downloaded: \(error.localizedDescription)")
            }
        }
        guard exists(id) else { return "" }
        let present = attachments.filter(AttachmentStore.exists)
        let text = await AttachmentText.read(present.map { (url: AttachmentStore.url(for: $0), attachment: $0) })
        guard exists(id) else { return text }
        // "" = looked at, nothing to read (a photo without text).
        if !text.isEmpty || present.count == attachments.count { note.pageText = text }
        return text
    }

    // MARK: - Summaries

    private func processSummary(_ id: UUID, template: SummaryTemplate, model: SummaryModel?) async {
        guard let note = fetchNote(id) else { return }
        #if os(iOS)
        var continued: AnyObject?
        if #available(iOS 26, *), case .local(let local) = model ?? .current, local != .apple {
            continued = ContinuedSummaryTask.begin(title: "Summarizing", subtitle: note.title)
        }
        #endif
        var succeeded = false
        do {
            // An image or a file is summarized from what was read out of it: read now when that has not happened yet
            // (the file came from another device, or reading was cut short).
            if note.attachmentsData != nil, !note.isRecording, (note.pageText ?? "").isEmpty {
                stages[id] = "Reading text…"
                await readAttachments(of: note)
                save()
            }
            try await SummaryService.summarize(note, template: template, model: model) { [weak self] status in
                self?.stages[id] = status
                #if os(iOS)
                if #available(iOS 26, *) { (continued as? ContinuedSummaryTask)?.update(status) }
                #endif
            }
            succeeded = true
            save()
        } catch is CancellationError {
            // The note is gone; nobody is left to tell.
        } catch {
            summaryErrors[id] = error.localizedDescription
        }
        #if os(iOS)
        if #available(iOS 26, *) { (continued as? ContinuedSummaryTask)?.end(success: succeeded) }
        #endif
    }

    private func processEnhance(_ id: UUID, model: SummaryModel?) async {
        guard let note = fetchNote(id) else { return }
        do {
            let original = try await SummaryService.enhance(note, model: model) { [weak self] status in
                self?.stages[id] = status
            }
            enhanceUndo[id] = EnhanceUndo(original: original, enhanced: note.text)
            save()
        } catch is CancellationError {
            // The note is gone; nobody is left to tell.
        } catch {
            enhanceErrors[id] = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func fetchNote(_ id: UUID) -> Note? {
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func save() {
        try? context.save()
    }

    /// A note deleted for good meanwhile (trash emptied, removed by sync) must not be written to any more.
    private func exists(_ id: UUID) -> Bool { fetchNote(id) != nil }

    /// `note` may be a scratch note that was never stored (a part recorded later); then `id` is its meeting.
    private func stillThere(_ note: Note, _ id: UUID) throws {
        if note.id == id, !exists(id) { throw CancellationError() }
    }

    #if canImport(UIKit)
    @MainActor
    private final class BackgroundTime {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
    #endif

    private func withBackgroundTime(_ work: () async -> Void) async {
        #if canImport(UIKit)
        let time = BackgroundTime()
        // Out of time: the task has to end or iOS kills the app. A job cut off this way resumes at the next launch.
        time.id = UIApplication.shared.beginBackgroundTask(withName: "transcription") {
            MainActor.assumeIsolated { time.end() }
        }
        await work()
        time.end()
        #else
        await work()
        #endif
    }
}
