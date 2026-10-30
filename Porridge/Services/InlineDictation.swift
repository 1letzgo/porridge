import AVFoundation
import Observation

/// Dictation straight into a text: while recording, the live transcript is handed to `onLiveText`
/// (the caller shows it in place). After stopping, the whole recording is transcribed once more
/// and that more accurate text replaces the live text.
@MainActor
@Observable
final class InlineDictation {
    enum Phase: Equatable {
        case idle
        case recording
        /// Recording stopped; the final transcript is being created.
        case polishing
    }

    struct Result {
        let fileName: String?
        /// Final transcript of the whole recording (falls back to the live text).
        let text: String
    }

    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?
    let recorder = AudioRecorder()
    let live = LiveTranscriber()

    /// Called with the complete live text so far, every time it changes.
    @ObservationIgnored var onLiveText: ((String) -> Void)?
    /// Called when the user taps "Stop" in the Live Activity (lock screen).
    @ObservationIgnored var onStopRequested: (() -> Void)?

    @ObservationIgnored private var forwarder: Task<Void, Never>?

    func start(title: String = "Note") async {
        guard phase == .idle else { return }
        errorMessage = nil
        guard await AudioRecorder.requestPermission() else {
            errorMessage = "Please allow microphone access in Settings."
            return
        }
        recorder.onBuffer = live.feed
        do {
            try recorder.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        phase = .recording
        LiveRecording.start(kind: .note, title: title) { [weak self] in self?.onStopRequested?() }

        // The recognizer loads while the user starts speaking; its audio queue keeps the first words.
        Task { await live.start(language: AppSettings.language) }
        forwarder = Task { [weak self] in
            var last = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self else { return }
                let text = self.live.text
                if text != last {
                    last = text
                    print("[live] ui text: '\(text)' (handler: \(self.onLiveText != nil))")
                    self.onLiveText?(text)
                }
            }
        }
    }

    func dismissError() { errorMessage = nil }

    /// Stops recording and returns the final text of the whole recording.
    func stop() async -> Result? {
        guard phase == .recording else { return nil }
        phase = .polishing
        LiveRecording.markFinishing()
        print("[live] stop: recorder")
        let recording = recorder.stop()
        let liveText = await live.finish()
        print("[live] stop: live finished '\(liveText)'")
        forwarder?.cancel()
        forwarder = nil

        var text = liveText
        if let fileName = recording?.fileName, let final = await Self.transcribe(fileName), !final.isEmpty {
            text = final
        }
        print("[live] stop: final '\(text)'")
        LiveRecording.end()
        phase = .idle
        return Result(fileName: recording?.fileName, text: text)
    }

    /// Abandons the recording without a result.
    func cancel() {
        guard phase == .recording else { return }
        forwarder?.cancel()
        forwarder = nil
        recorder.cancel()
        live.cancel()
        LiveRecording.end()
        phase = .idle
    }

    private static func transcribe(_ fileName: String) async -> String? {
        let source = AudioStore.url(for: fileName)
        guard let prepared = try? await Task.detached(priority: .userInitiated, operation: {
            try AudioPreprocessor.prepare(source: source, measureChannels: false)
        }).value else { return nil }
        defer { try? FileManager.default.removeItem(at: prepared.monoURL) }
        do {
            try await ModelManager.shared.ensureASR()
            let output = try await TranscriptionEngine.shared.transcribe(prepared.monoURL, language: AppSettings.language)
            return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
