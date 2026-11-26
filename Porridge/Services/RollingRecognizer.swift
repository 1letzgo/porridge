import AVFoundation
import FluidAudio

/// Live transcript from the batch Parakeet model: about once a second the audio since the last
/// committed point is transcribed again (so words appear and refine while speaking); once that
/// piece gets long, or the speaker pauses, it is closed and kept as confirmed text.
///
/// Every update is a piece with its place in the audio (seconds since the first sample): a final piece is
/// confirmed text, a non-final one the open piece that is still refined (empty: nothing open).
actor RollingRecognizer {
    typealias OnPiece = @Sendable (_ text: String, _ start: Double, _ end: Double, _ isFinal: Bool) -> Void

    private let asr: AsrManager
    private let language: Language?
    private let onPiece: OnPiece

    private let sampleRate = 16_000
    private var segment: [Float] = []
    /// The position of `segment[0]` in all samples appended so far.
    private var segmentOffset = 0
    private var confirmed = ""
    private var volatile = ""
    private var newSamples = 0
    private var runTask: Task<Void, Never>?
    private var stopped = false
    private var failedDecodes = 0

    /// Re-decode after this much new audio.
    private let decodeInterval = 14_000          // 0.9 s
    /// A piece is closed once it is this long.
    private let commitLength = 10 * 16_000
    private let minimumDecode = 16_000
    /// A piece is closed at a pause once it is this long (a turn in a conversation).
    private let pauseCommitLength = 3 * 16_000

    init(asr: AsrManager, language: Language?, onPiece: @escaping OnPiece) {
        self.asr = asr
        self.language = language
        self.onPiece = onPiece
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

    /// Adds 16 kHz mono samples.
    func append(_ samples: [Float]) {
        guard !stopped else { return }
        segment.append(contentsOf: samples)
        newSamples += samples.count
    }

    /// Stops and returns the full text, including the last bit of audio.
    func finish() async -> String {
        stopped = true
        runTask?.cancel()
        runTask = nil
        if segment.count >= minimumDecode / 2, Self.hasSpeech(segment), let text = await decode(segment), !text.isEmpty {
            confirmed = [confirmed, text].filter { !$0.isEmpty }.joined(separator: " ")
            emit(text, from: 0, to: segment.count, isFinal: true)
        }
        volatile = ""
        emit("", from: segment.count, to: segment.count, isFinal: false)
        return confirmed
    }

    func cancel() {
        stopped = true
        runTask?.cancel()
        runTask = nil
    }

    private func tick() async {
        guard !stopped, newSamples >= decodeInterval, segment.count >= minimumDecode / 2 else { return }
        newSamples = 0
        let snapshot = segment
        // Silence (the other side of a call while nobody there talks, a muted microphone) is not decoded: it costs
        // time and the model makes up words in it. A long silent stretch is dropped.
        guard Self.hasSpeech(snapshot) else {
            if snapshot.count >= commitLength { drop(snapshot.count) }
            return
        }
        let decoded = await decode(snapshot)
        guard !stopped else { return }
        guard let text = decoded else {
            markGapAfterRepeatedFailures()
            return
        }
        failedDecodes = 0
        volatile = text

        if snapshot.count >= pauseCommitLength, let pause = Self.trailingPause(in: snapshot, sampleRate: sampleRate) {
            // The speaker paused: the whole piece is said, kept as it was just decoded.
            commit(text, length: pause)
        } else if snapshot.count >= commitLength {
            await commit(snapshot)
        } else {
            emit(volatile, from: 0, to: snapshot.count, isFinal: false)
        }
    }

    /// The system may refuse the model while the phone is locked. The sound of this stretch is given up,
    /// with a mark in the text so the gap shows; the final transcript comes from the recording and has it.
    private func markGapAfterRepeatedFailures() {
        failedDecodes += 1
        guard failedDecodes >= 3 else { return }
        failedDecodes = 0
        let length = segment.count
        let open = volatile
        volatile = ""
        if !open.isEmpty || !confirmed.hasSuffix(Self.gapMarker) {
            let text = [open, Self.gapMarker].filter { !$0.isEmpty }.joined(separator: " ")
            confirmed = [confirmed, text].filter { !$0.isEmpty }.joined(separator: " ")
            emit(text, from: 0, to: length, isFinal: true)
        }
        drop(length)
    }

    private static let gapMarker = "[… not transcribed live …]"

    /// Closes the piece at its quietest spot; what was spoken after that spot stays open.
    private func commit(_ snapshot: [Float]) async {
        let cut = quietestCut(in: snapshot)
        guard cut > sampleRate, let text = await decode(Array(snapshot[..<cut])) else {
            emit(volatile, from: 0, to: snapshot.count, isFinal: false)
            return
        }
        commit(text, length: cut)
        newSamples = decodeInterval
    }

    /// Keeps `text` as the confirmed piece of the first `length` samples of the segment.
    private func commit(_ text: String, length: Int) {
        if !text.isEmpty {
            confirmed = [confirmed, text].filter { !$0.isEmpty }.joined(separator: " ")
            emit(text, from: 0, to: length, isFinal: true)
        }
        // Audio that arrived while decoding is part of the new open piece.
        drop(length)
        volatile = ""
        emit("", from: 0, to: 0, isFinal: false)
    }

    /// Removes the first `count` samples of the segment, keeping the clock.
    private func drop(_ count: Int) {
        let count = min(count, segment.count)
        segment.removeFirst(count)
        segmentOffset += count
    }

    private func emit(_ text: String, from: Int, to: Int, isFinal: Bool) {
        let rate = Double(sampleRate)
        onPiece(text, Double(segmentOffset + from) / rate, Double(segmentOffset + to) / rate, isFinal)
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

    // MARK: Pauses and silence (pure, see tests)

    /// Loudness (RMS) under which a 100 ms frame counts as silence: about -54 dBFS.
    static let silenceLevel: Float = 0.002
    /// A pause this long ends a piece.
    static let pauseSeconds = 0.6

    /// RMS of 100 ms frames.
    static func frameLevels(_ samples: [Float], sampleRate: Int = 16_000) -> [Float] {
        let frame = sampleRate / 10
        guard frame > 0 else { return [] }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frame)
        var start = 0
        while start + frame <= samples.count {
            var sum: Float = 0
            for i in start..<start + frame { sum += samples[i] * samples[i] }
            levels.append((sum / Float(frame)).squareRoot())
            start += frame
        }
        return levels
    }

    /// Whether any frame is louder than silence.
    static func hasSpeech(_ samples: [Float], sampleRate: Int = 16_000) -> Bool {
        frameLevels(samples, sampleRate: sampleRate).contains { $0 >= silenceLevel }
    }

    /// When the samples end in a pause after speech: the length up to the middle of the pause. A frame is part of
    /// the pause when it is below an eighth of the loudest frame (and below silence for quiet speakers).
    static func trailingPause(in samples: [Float], sampleRate: Int = 16_000) -> Int? {
        let levels = frameLevels(samples, sampleRate: sampleRate)
        let needed = Int((pauseSeconds * 10).rounded())
        guard levels.count > needed, let peak = levels.max(), peak >= silenceLevel else { return nil }
        let quiet = max(peak / 8, silenceLevel)
        guard levels.suffix(needed).allSatisfy({ $0 < quiet }),
              levels.dropLast(needed).contains(where: { $0 >= quiet }) else { return nil }
        let frame = sampleRate / 10
        return samples.count - needed * frame / 2
    }

    private func decode(_ samples: [Float]) async -> String? {
        var audio = samples
        if audio.count < minimumDecode {
            audio += [Float](repeating: 0, count: minimumDecode - audio.count)
        }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        do {
            let result = try await asr.transcribe(audio, decoderState: &state, language: language)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("[live] decode failed: \(error)")
            return nil
        }
    }
}
