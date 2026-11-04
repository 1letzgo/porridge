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

        var id: UUID {
            switch self {
            case .transcript(let id), .note(let id), .link(let id, _), .summary(let id, _, _): id
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

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var isRunning = false

    init(container: ModelContainer) {
        self.container = container
    }

    private var context: ModelContext { container.mainContext }

    func enqueue(_ job: Job) {
        guard !queue.contains(job), stages[job.id] == nil else { return }
        queue.append(job)
        stages[job.id] = "Waiting…"
        if case .summary(_, _, let model) = job {
            summarizing.insert(job.id)
            summaryModels[job.id] = model
        }
        runIfNeeded()
    }

    func clearSummaryError(_ id: UUID) {
        summaryErrors[id] = nil
    }

    /// Picks up recordings that were interrupted (app killed while transcribing).
    func resumePending() {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        for note in notes where [.recorded, .transcribing].contains(note.status) && note.hasLocalAudio && note.pendingAudioFileName == nil {
            enqueue(.transcript(note.id))
        }
        for note in notes where AudioStore.exists(note.pendingAudioFileName) {
            enqueue(.note(note.id))
        }
        // Links without a summary get one in the background, when a model is ready for it (see `processLink`).
        for note in notes where note.isLink && !note.isDeleted && note.summary == nil && note.status != .failed
            && (note.pageText == nil || !(note.pageText ?? "").isEmpty) {
            enqueue(.link(note.id, summarize: true))
        }
    }

    private func runIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            while !queue.isEmpty {
                let job = queue.removeFirst()
                await withBackgroundTime {
                    switch job {
                    case .transcript(let id): await processTranscript(id)
                    case .note(let id): await processNote(id)
                    case .link(let id, let summarize): await processLink(id, summarize: summarize)
                    case .summary(let id, let template, let model): await processSummary(id, template: template, model: model)
                    }
                }
                stages[job.id] = nil
                summarizing.remove(job.id)
                summaryModels[job.id] = nil
            }
            isRunning = false
        }
    }

    // MARK: - Recordings with a transcript

    private func processTranscript(_ id: UUID) async {
        guard let meeting = fetchNote(id) else { return }
        guard let fileName = meeting.audioFileName, AudioStore.exists(fileName) else {
            meeting.status = .failed
            meeting.errorMessage = ASRPipelineError.missingAudio.localizedDescription
            save()
            return
        }
        meeting.status = .transcribing
        meeting.errorMessage = nil
        save()

        do {
            try await transcribe(meeting, fileName: fileName, stageID: id)
        } catch {
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
        }
        save()
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

        var speakers = meeting.speakers
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
                    meeting.speakerMode = .diarized
                } else {
                    speakers = []
                    meeting.speakerMode = .none
                }
            } catch {
                // Speaker detection is optional; keep the plain transcript.
                diagnostics = "Speaker detection failed: \(error.localizedDescription)"
                speakers = []
                meeting.speakerMode = .none
            }
        }

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
            meeting.speakers = await VoiceProfiles.identify(
                meeting.speakers, segments: meeting.segments, audio: prepared.monoURL, context: context)
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
            stages[id] = "Adding to the meeting…"
            try await NoteMerger.append(part, to: meeting)
            meeting.pendingAudioFileName = nil
            meeting.errorMessage = part.errorMessage
            meeting.updatedAt = Date()
        } catch {
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

            let text = Paragraphs.format(output.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if !text.isEmpty {
                note.text = note.text.isEmpty ? text : note.text + "\n\n" + text
            }
            note.audioFileNames.append(fileName)
            note.pendingAudioFileName = nil
            note.updatedAt = Date()
            note.status = .ready
        } catch {
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
                note.pageText = page.text
                if let title = page.title, note.title.isEmpty || note.title == address || note.title == note.domain {
                    note.title = title
                }
                note.status = .ready
                note.errorMessage = nil
            } catch {
                note.status = .failed
                note.errorMessage = error.localizedDescription
                save()
                return
            }
            save()
        }

        if summarize, note.summary == nil, !note.isDeleted, !(note.pageText ?? "").isEmpty, SummaryService.canRunWithoutAsking {
            stages[id] = "Summarizing…"
            try? await SummaryService.summarize(note) { [weak self] status in self?.stages[id] = status }
            save()
        }
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
            try await SummaryService.summarize(note, template: template, model: model) { [weak self] status in
                self?.stages[id] = status
                #if os(iOS)
                if #available(iOS 26, *) { (continued as? ContinuedSummaryTask)?.update(status) }
                #endif
            }
            succeeded = true
            save()
        } catch {
            summaryErrors[id] = error.localizedDescription
        }
        #if os(iOS)
        if #available(iOS 26, *) { (continued as? ContinuedSummaryTask)?.end(success: succeeded) }
        #endif
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
