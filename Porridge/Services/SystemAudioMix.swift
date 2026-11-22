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
