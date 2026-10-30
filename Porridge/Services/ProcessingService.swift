import Foundation
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Serial queue that turns recordings into transcripts.
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

        var id: UUID {
            switch self {
            case .transcript(let id), .note(let id), .link(let id, _): id
            }
        }
    }

    /// Human readable progress per note id.
    private(set) var stages: [UUID: String] = [:]

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
        stages[job.id] = "Waiting …"
        runIfNeeded()
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
                    }
                }
                stages[job.id] = nil
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
            stages[id] = "Preparing audio …"
            let splitChannels = meeting.speakerMode == .channels
            let source = AudioStore.url(for: fileName)
            let prepared = try await Task.detached(priority: .userInitiated) {
                try AudioPreprocessor.prepare(source: source, measureChannels: splitChannels)
            }.value
            defer { try? FileManager.default.removeItem(at: prepared.monoURL) }

            stages[id] = "Loading speech model …"
            try await ModelManager.shared.ensureASR()
            stages[id] = "Transcribing …"
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
                stages[id] = "Detecting speakers …"
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
                stages[id] = "Recognizing voices …"
                meeting.speakers = await VoiceProfiles.identify(
                    meeting.speakers, segments: meeting.segments, audio: prepared.monoURL, context: context)
            }
            meeting.duration = prepared.duration
            meeting.status = .ready
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
        note.status = .transcribing
        note.errorMessage = nil
        save()

        do {
            stages[id] = "Preparing audio …"
            let source = AudioStore.url(for: fileName)
            let prepared = try await Task.detached(priority: .userInitiated) {
                try AudioPreprocessor.prepare(source: source, measureChannels: false)
            }.value
            defer { try? FileManager.default.removeItem(at: prepared.monoURL) }

            stages[id] = "Loading speech model …"
            try await ModelManager.shared.ensureASR()
            stages[id] = "Transcribing …"
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
            stages[id] = "Loading page …"
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
            stages[id] = "Summarizing …"
            try? await SummaryService.summarize(note) { [weak self] status in self?.stages[id] = status }
            save()
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

    private func withBackgroundTime(_ work: () async -> Void) async {
        #if canImport(UIKit)
        let task = UIApplication.shared.beginBackgroundTask(withName: "transcription")
        await work()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        #else
        await work()
        #endif
    }
}
