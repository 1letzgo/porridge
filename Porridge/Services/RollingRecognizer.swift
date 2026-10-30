import AVFoundation
import FluidAudio

/// Live transcript from the batch Parakeet model: about once a second the audio since the last
/// committed point is transcribed again (so words appear and refine while speaking); once that
/// piece gets long it is closed at the quietest spot and kept as confirmed text.
actor RollingRecognizer {
    private let asr: AsrManager
    private let language: Language?
    private let onUpdate: @Sendable (_ confirmed: String, _ volatile: String) -> Void

    private let sampleRate = 16_000
    private var segment: [Float] = []
    private var confirmed = ""
    private var volatile = ""
    private var newSamples = 0
    private var runTask: Task<Void, Never>?
    private var stopped = false
    private var paused = false
    private var appended = 0

    /// Re-decode after this much new audio.
    private let decodeInterval = 14_000          // 0.9 s
    /// A piece is closed once it is this long.
    private let commitLength = 10 * 16_000
    private let minimumDecode = 16_000

    init(asr: AsrManager, language: Language?, onUpdate: @escaping @Sendable (String, String) -> Void) {
        self.asr = asr
        self.language = language
        self.onUpdate = onUpdate
    }

    func start() {
        runTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await self.tick()
            }
        }
    }

    /// While the app is in the background (phone locked) nobody sees the live text: don't burn CPU
    /// and don't collect audio. The final transcript is made from the recording afterwards.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            segment.removeAll()
            newSamples = 0
        }
    }

    /// Adds 16 kHz mono samples.
    func append(_ samples: [Float]) {
        guard !stopped, !paused else { return }
        segment.append(contentsOf: samples)
        newSamples += samples.count
        appended += 1
        if appended % 50 == 1 { print("[live] append #\(appended), segment \(segment.count) samples, new \(newSamples)") }
    }

    /// Stops and returns the full text, including the last bit of audio.
    func finish() async -> String {
        stopped = true
        runTask?.cancel()
        runTask = nil
        if segment.count >= minimumDecode / 2, let text = await decode(segment) {
            volatile = text
        }
        publish()
        return [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func cancel() {
        stopped = true
        runTask?.cancel()
        runTask = nil
    }

    private func tick() async {
        guard !stopped, !paused, newSamples >= decodeInterval, segment.count >= minimumDecode / 2 else { return }
        newSamples = 0
        let snapshot = segment
        guard let text = await decode(snapshot), !stopped else { return }
        volatile = text

        if snapshot.count >= commitLength {
            await commit(snapshot)
        }
        publish()
    }

    /// Closes the piece at its quietest spot; what was spoken after that spot stays open.
    private func commit(_ snapshot: [Float]) async {
        let cut = quietestCut(in: snapshot)
        guard cut > sampleRate, let text = await decode(Array(snapshot[..<cut])) else { return }
        if !text.isEmpty {
            confirmed = [confirmed, text].filter { !$0.isEmpty }.joined(separator: " ")
        }
        // Audio that arrived while decoding is part of the new open piece.
        segment.removeFirst(min(cut, segment.count))
        volatile = ""
        newSamples = decodeInterval
    }

    private func quietestCut(in samples: [Float]) -> Int {
        let frame = sampleRate / 5               // 200 ms
        let from = max(frame * 15, samples.count - sampleRate * 5) / frame * frame   // not before 3 s
        let to = samples.count - frame * 2
        guard to > from else { return samples.count }
        var best = from
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = from
        while start + frame <= to {
            var sum: Float = 0
            for i in start..<start + frame { sum += samples[i] * samples[i] }
            if sum < bestEnergy {
                bestEnergy = sum
                best = start + frame / 2
            }
            start += frame / 2
        }
        return best
    }

    private func decode(_ samples: [Float]) async -> String? {
        var audio = samples
        if audio.count < minimumDecode {
            audio += [Float](repeating: 0, count: minimumDecode - audio.count)
        }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        do {
            let result = try await asr.transcribe(audio, decoderState: &state, language: language)
            print("[live] decode \(samples.count) samples -> '\(result.text)'")
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[live] decode failed: \(error)")
            return nil
        }
    }

    private func publish() {
        onUpdate(confirmed, volatile)
    }
}
