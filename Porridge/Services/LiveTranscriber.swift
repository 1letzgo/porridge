import AVFoundation
import FluidAudio
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Shows what is being said while recording. Parakeet v3 re-transcribes the running piece about once
/// a second (see `RollingRecognizer`); the final transcript still comes from the batch pipeline.
@MainActor
@Observable
final class LiveTranscriber {
    enum Phase: Equatable {
        case idle
        case preparing
        case downloading(Double)
        case running
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var confirmed = ""
    private(set) var volatile = ""
    /// Sentences of the confirmed text with the speaker (channel index) that was loudest when they appeared.
    private func setText(confirmed: String, volatile: String) {
        self.confirmed = confirmed
        self.volatile = volatile
    }

    var text: String {
        [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Hand this to the recorder; it receives mono copies of the microphone buffers.
    nonisolated let feed: @Sendable (AVAudioPCMBuffer) -> Void

    @ObservationIgnored private let stream: AsyncStream<AVAudioPCMBuffer>
    @ObservationIgnored private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    @ObservationIgnored private var rolling: RollingRecognizer?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var lifecycleObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var appleLive: AnyObject?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(256))
        self.stream = stream
        self.continuation = continuation
        self.feed = { buffer in continuation.yield(buffer) }
    }

    func start(language: Language?) async {
        guard phase == .idle else { return }
        if AppSettings.speechEngine == .apple {
            await startApple(language: language)
            return
        }
        phase = TranscriptionEngine.asrInstalled ? .preparing : .downloading(0)
        do {
            try await ModelManager.shared.ensureLocalASR()
            let asr = try await TranscriptionEngine.shared.loadASR()
            let rolling = RollingRecognizer(asr: asr, language: language) { [weak self] confirmed, volatile in
                Task { @MainActor in self?.setText(confirmed: confirmed, volatile: volatile) }
            }
            self.rolling = rolling
            await rolling.start()
            pauseInBackground(rolling)
            // Single consumer keeps the buffers in order.
            let stream = self.stream
            feedTask = Task.detached {
                let converter = AudioConverter()
                for await buffer in stream {
                    do {
                        let samples = try converter.resampleBuffer(buffer)
                        await rolling.append(samples)
                    } catch {
                        print("[live] resample failed (\(buffer.format)): \(error)")
                    }
                }
            }
            phase = .running
            print("[live] running")
        } catch {
            print("[live] start failed: \(error)")
            phase = .unavailable(error.localizedDescription)
        }
    }

    private func startApple(language: Language?) async {
        guard #available(iOS 26, macOS 26, *) else { return }
        phase = ModelManager.shared.asr == .ready ? .preparing : .downloading(0)
        do {
            try await ModelManager.shared.ensureLocalASR()
            let live = try await AppleSpeech.Live.make(language: language) { [weak self] confirmed, volatile in
                Task { @MainActor in
                    self?.setText(confirmed: confirmed, volatile: volatile)
                }
            }
            appleLive = live
            let stream = self.stream
            feedTask = Task.detached {
                for await buffer in stream { live.feed(buffer) }
            }
            phase = .running
        } catch {
            phase = .unavailable(error.localizedDescription)
        }
    }

    /// No live decoding while the phone is locked or the app is in the background.
    private func pauseInBackground(_ rolling: RollingRecognizer) {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                Task { await rolling.setPaused(true) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                Task { await rolling.setPaused(false) }
            },
        ]
        #endif
    }

    private func removeLifecycleObservers() {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
    }

    func observeDownload(_ state: ModelManager.State) {
        if case .downloading(let progress) = state, case .downloading = phase {
            phase = .downloading(progress)
        }
    }

    /// Stops listening and returns the final live text.
    func finish() async -> String {
        continuation.finish()
        await feedTask?.value
        if #available(iOS 26, macOS 26, *), let live = appleLive as? AppleSpeech.Live {
            await live.finish()
            appleLive = nil
            return text
        }
        removeLifecycleObservers()
        if let rolling {
            let final = await rolling.finish()
            if !final.isEmpty { setText(confirmed: final, volatile: "") }
            self.rolling = nil
        }
        return text
    }

    func cancel() {
        removeLifecycleObservers()
        continuation.finish()
        feedTask?.cancel()
        if #available(iOS 26, macOS 26, *), let live = appleLive as? AppleSpeech.Live { live.cancel() }
        appleLive = nil
        let rolling = rolling
        self.rolling = nil
        Task { await rolling?.cancel() }
    }
}
