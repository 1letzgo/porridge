import Accelerate
import AVFoundation

/// A second sound recorded next to the microphone, on the right channel: on the Mac, the sound of the other
/// side of a call (`SystemAudioTap`). It runs on its own clock and fills `fifo` at the microphone's rate.
protocol SecondChannelSource: AnyObject, Sendable {
    var fifo: SampleFIFO { get }
    /// Starts at the microphone's sample rate. Throws when the sound cannot be captured; the recording then
    /// goes on with the microphone alone.
    func start(sampleRate: Double) throws
    func stop()
}

/// Meetings recorded with the microphone on the left and the Mac's sound on the right: the left channel is the
/// user, the right one the others. No field of its own marks them; the input name says it.
enum SystemAudioMix {
    static let inputName = "Microphone + System Audio"
    /// The right channel's name until the user gives it one; several voices on it are then told apart.
    static let othersName = "Others"
    static let defaultNamePrefix = "Speaker "

    static func isSystemAudio(inputName: String?) -> Bool {
        inputName == Self.inputName
    }

    /// Whether the voices on the right channel may be told apart by speaker detection: not when the user named
    /// it (a call with one person) or it was recognized as a known voice.
    static func splitsOthers(_ speaker: Speaker?) -> Bool {
        guard let speaker else { return true }
        guard speaker.profileID == nil else { return false }
        return speaker.name == othersName || speaker.name.hasPrefix(defaultNamePrefix)
    }

    /// The microphone (all its channels mixed) on the left, `fifo` on the right, as one stereo buffer.
    static func stereo(microphone buffer: AVAudioPCMBuffer, fifo: SampleFIFO) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let src = buffer.floatChannelData,
              let format = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 2),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = buffer.frameLength
        dst[0].update(from: src[0], count: frames)
        if channels > 1 {
            for channel in 1..<channels {
                vDSP_vadd(dst[0], 1, src[channel], 1, dst[0], 1, vDSP_Length(frames))
            }
            var scale = 1 / Float(channels)
            vDSP_vsmul(dst[0], 1, &scale, dst[0], 1, vDSP_Length(frames))
        }
        fifo.pull(into: dst[1], count: frames)
        return out
    }
}

/// The rate at which a stream of audio really arrives, from the frames delivered per second of host time. The Mac's
/// sound comes through an aggregate device that runs at the output device's rate (44.1 kHz on some headphones, 24 or
/// 16 kHz on AirPods during a call), while the tap's format may still say 48 kHz: read at the wrong rate the others'
/// voices come out sped up or slowed down and choppy, and speech recognition hardly finds a word in them.
struct DeliveredRate {
    static let standardRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]

    /// The rate in use; it changes only when a whole window clearly measured another one.
    private(set) var rate: Double
    /// Seconds of host time measured before a rate is judged.
    let window: Double
    private var windowStart: Double?
    private var frames = 0

    init(rate: Double, window: Double = 1) {
        self.rate = rate
        self.window = window
    }

    /// The standard rate within 4 % of `measured`; nil for anything in between (stalls, a burst after a gap).
    static func snap(_ measured: Double) -> Double? {
        guard let nearest = standardRates.min(by: { abs($0 - measured) < abs($1 - measured) }),
              abs(nearest - measured) <= nearest * 0.04 else { return nil }
        return nearest
    }

    /// `frames` arrived at host time `time` (seconds). Returns the new rate when it changed.
    mutating func add(frames count: Int, at time: Double) -> Double? {
        guard let start = windowStart, time >= start else {
            // The first buffer only starts the clock: its frames were captured before `time`.
            windowStart = time
            frames = 0
            return nil
        }
        frames += count
        let elapsed = time - start
        guard elapsed >= window else { return nil }
        let measured = Double(frames) / elapsed
        windowStart = time
        frames = 0
        guard let snapped = Self.snap(measured), snapped != rate else { return nil }
        rate = snapped
        return snapped
    }
}

/// Mono samples handed from one audio clock to another (the Mac's sound to the microphone). The reader takes as
/// many as the microphone delivered; the two clocks drift apart slowly, so the queue is kept near `target`:
/// - until that much is there (at the start and after running dry), the reader gets silence,
/// - beyond `target + slack` (a pause of the recording, a stalled reader), the oldest samples are dropped.
final class SampleFIFO: @unchecked Sendable {
    let target: Int
    let slack: Int
    private var storage: [Float] = []
    private var head = 0
    private var primed = false
    private let lock = NSLock()

    /// `target` and `slack` in samples.
    init(target: Int, slack: Int) {
        self.target = max(0, target)
        self.slack = max(1, slack)
    }

    /// For the microphone's rate: 60 ms latency, up to 250 ms more before dropping.
    convenience init(sampleRate: Double) {
        self.init(target: Int(sampleRate * 0.06), slack: Int(sampleRate * 0.25))
    }

    var count: Int { lock.withLock { storage.count - head } }

    func push(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.withLock {
            storage.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        }
    }

    func push(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { push(base, count: $0.count) } }
    }

    /// Fills `out` with `count` samples, silence where there are none.
    func pull(into out: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var available = storage.count - head
        if available > target + slack + count {
            head += available - (target + count)
            available = target + count
        }
        if !primed {
            guard available >= target + count || (target == 0 && available > 0) else {
                out.update(repeating: 0, count: count)
                compact()
                return
            }
            primed = true
        }
        let taken = min(count, available)
        storage.withUnsafeBufferPointer { buffer in
            if taken > 0, let base = buffer.baseAddress { out.update(from: base + head, count: taken) }
        }
        if taken < count {
            (out + taken).update(repeating: 0, count: count - taken)
            // Ran dry: wait for the cushion again instead of clicking on every buffer.
            primed = false
        }
        head += taken
        compact()
    }

    func pull(count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { if let base = $0.baseAddress { pull(into: base, count: count) } }
        return out
    }

    func reset() {
        lock.withLock {
            storage.removeAll(keepingCapacity: true)
            head = 0
            primed = false
        }
    }

    private func compact() {
        if head > 0, head >= storage.count / 2 || head > 1 << 16 {
            storage.removeFirst(head)
            head = 0
        }
    }
}
